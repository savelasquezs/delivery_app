import 'dart:convert';
import 'dart:io';

import 'package:delivery_app/features/tracking/tracking_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final started = DateTime.utc(2026, 10, 8, 15);
TrackingContext context(
        {String auth = 'login-a',
        String owner = 'restaurant:driver-a',
        int session = 1}) =>
    TrackingContext(
        authSessionId: auth,
        ownerKey: owner,
        workSessionId: session,
        startedAt: started,
        autoCloseAt: started.add(const Duration(hours: 10)));
Map<String, dynamic> point(String id,
        {int minute = 0, int session = 1, String? auth}) =>
    {
      'clientPointId': id,
      'workSessionId': session,
      if (auth != null) '_authSessionId': auth,
      'latitude': 6.25,
      'longitude': -75.56,
      'recordedAt': started.add(Duration(minutes: minute)).toIso8601String(),
    };

void main() {
  late Database db;
  late TrackingOutbox store;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    store = TrackingOutbox(open: () async => db);
    await store.activate(context());
  });
  tearDown(() => db.close());

  test('operational actions survive reopen and are isolated by owner', () async {
    final payload = {'operationId': 'intent-a', 'kind': 'deliver', 'orderId': 12};
    await store.enqueueOperation('tenant:driver-a', payload, {'id': 12});
    final reopened = TrackingOutbox(open: () async => db);
    expect(await reopened.operations('tenant:driver-b'), isEmpty);
    expect((await reopened.operations('tenant:driver-a')).single['payload'], jsonEncode(payload));
    await reopened.enqueueOperation('tenant:driver-a', payload, {'id': 12});
    expect(await reopened.operations('tenant:driver-a'), hasLength(1));
  });

  test('only one isolate leases a command and ambiguous results remain recoverable', () async {
    await store.enqueueOperation('owner', {'operationId': 'intent', 'kind': 'address'}, {});
    final leases = await Future.wait([store.claimOperation('owner', 'intent', 1000), store.claimOperation('owner', 'intent', 1000)]);
    expect(leases.where((value) => value), hasLength(1));
    expect(await store.claimOperation('owner', 'intent', 121001), isTrue);
    await store.finishOperation('owner', 'intent', conflict: 'La dirección cambió');
    expect(await store.claimOperation('owner', 'intent', 999999), isFalse);
    expect((await store.operations('owner')).single['reason'], 'La dirección cambió');
  });

  test('context snapshots never go backwards and a conflict needs explicit discard', () async {
    await store.cache('owner', 'route', {'revision': 9, 'routeId': null});
    await store.cache('owner', 'route', {'revision': 8, 'routeId': 7});
    expect((await store.cached('owner', 'route'))!['routeId'], isNull);
    await store.enqueueOperation('owner', {'operationId': 'uncertain'}, {});
    await store.discardOperationConflict('owner', 'uncertain');
    expect(await store.operations('owner'), hasLength(1));
    await store.finishOperation('owner', 'uncertain', conflict: 'Conflicto');
    await store.discardOperationConflict('other-owner', 'uncertain');
    expect(await store.operations('owner'), hasLength(1));
    await store.discardOperationConflict('owner', 'uncertain');
    expect(await store.operations('owner'), isEmpty);
  });

  test('ACK removes one row without overwriting concurrent captured points',
      () async {
    await store.enqueue(context(), 'location', point('a'));
    final sent = (await store.pending(context())).single;
    await Future.wait([
      store.acknowledge(sent, started.add(const Duration(seconds: 5))),
      store.enqueue(context(), 'location', point('b', minute: 1)),
    ]);
    expect((await store.pending(context())).map((x) => x.id), ['b']);
    final status = await store.snapshot(context());
    expect(status.capturedAt, started.add(const Duration(minutes: 1)));
    expect(status.acceptedPointAt, started);
  });

  test('bounded backfill reserves a fresh position and never repeats its ID',
      () async {
    for (var i = 0; i < 100; i++) {
      await store.enqueue(context(), 'location', point('p$i', minute: i));
    }
    final batch = await store.pending(context());
    expect(batch, hasLength(10));
    expect(batch.first.id, 'p99');
    expect(batch[1].id, 'p0');
    expect(batch.map((x) => x.id).toSet(), hasLength(10));
    expect((await store.snapshot(context())).pending, 100);
  });

  test('an old ACK cannot move the confirmed location timestamp backwards',
      () async {
    await store.enqueue(context(), 'location', point('old'));
    await store.enqueue(context(), 'location', point('new', minute: 5));
    final rows = await store.pending(context());
    await store.acknowledge(rows.firstWhere((p) => p.id == 'new'),
        started.add(const Duration(minutes: 5)));
    await store.acknowledge(rows.firstWhere((p) => p.id == 'old'),
        started.add(const Duration(minutes: 6)));
    expect((await store.snapshot(context())).acceptedPointAt,
        started.add(const Duration(minutes: 5)));
  });

  test('new login can recover owned history but another driver cannot',
      () async {
    await store.enqueue(context(), 'location', point('old', auth: 'login-a'));
    final resumed = context(auth: 'login-b', session: 2);
    await store.activate(resumed);
    expect((await store.pending(resumed)).single.workSessionId, 1);
    final other =
        context(auth: 'login-c', owner: 'restaurant:driver-b', session: 3);
    await store.activate(other);
    expect(await store.pending(other), isEmpty);
    expect(await store.deactivate(context()), false);
    expect(await store.updateCutoff(context(), started), false);
    expect((await store.current())!.ownerKey, other.ownerKey);
  });

  test('a delayed initialization cannot replace a newer tracking context',
      () async {
    final newer = context(auth: 'new-login', session: 2);
    await store.activate(newer);
    await store.activate(context(), onlyIfAbsent: true);
    expect((await store.current())!.authSessionId, 'new-login');
  });

  test('legacy migration checkpoints batches without losing pending history',
      () async {
    final raw = jsonEncode(List.generate(8,
        (index) => point('legacy-$index', minute: index)));
    // Keep the preference untouched until all items have a durable receipt.
    expect(await store.importLegacyBatch('previous', raw, 'location',
        context(), batchSize: 3), isFalse);
    expect((await db.query('tracking_import_cursor')).single['next_index'], 3);
    expect((await store.pending(context())), hasLength(3));
    final acknowledged = (await store.pending(context())).first;
    await store.acknowledge(acknowledged, started);
    await store.enqueue(context(), 'location', point('current', minute: 10));

    // A new service isolate/restart continues from the SQL cursor.
    final resumed = TrackingOutbox(open: () async => db);
    expect(await resumed.importLegacyBatch('previous', raw, 'location',
        context(), batchSize: 3), isFalse);
    expect((await db.query('tracking_import_cursor')).single['next_index'], 6);
    expect(await resumed.importLegacyBatch('previous', raw, 'location',
        context(), batchSize: 3), isTrue);
    expect(await resumed.importLegacyBatch('previous', raw, 'location',
        context(), batchSize: 3), isTrue);
    expect(await db.query('tracking_import_cursor'), isEmpty);
    expect(await db.query('tracking_import'), hasLength(1));
    final all = await db.query('tracking_outbox');
    expect(all.map((row) => row['id']).toSet(), hasLength(8));
    expect(all.any((row) => row['id'] == 'current'), isTrue);
    expect(all.any((row) => row['id'] == acknowledged.id), isFalse);
  });

  test('migration receipt survives ACK before old preferences are removed',
      () async {
    final raw = jsonEncode([point('a')]);
    await store.importLegacy('old-locations', raw, 'location', context());
    final record = (await store.pending(context())).single;
    await store.acknowledge(record, started);
    await store.importLegacy('old-locations', raw, 'location', context());
    expect(await store.pending(context()), isEmpty);
    expect((await db.query('tracking_import')).length, 1);
  });

  test(
      'legacy owners and malformed data are retained, not reassigned or dropped',
      () async {
    final raw = jsonEncode([
      point('unknown', session: 999),
      {'workSessionId': 'invalid'}
    ]);
    await store.importLegacy('old', raw, 'location', context());
    await store.importLegacy('broken', '{not-json', 'event', context());
    expect(await store.pending(context()), isEmpty);
    final records = await db.query('tracking_outbox');
    expect(records, hasLength(3));
    expect(records.every((r) => r['state'] == 'rejected'), true);
    expect(records.every((r) => r['owner_key'] == 'unbound'), true);
  });

  test('bad point is quarantined and does not block another pending point',
      () async {
    await store.enqueue(context(), 'location', point('bad'));
    await store.enqueue(context(), 'location', point('good', minute: 1));
    await store.reject(
        (await store.pending(context())).firstWhere((p) => p.id == 'bad'),
        'http_422');
    expect((await store.pending(context())).single.id, 'good');
    expect((await store.snapshot(context())).rejected, 1);
    expect(
        (await db.query('tracking_outbox', where: 'id = ?', whereArgs: ['bad']))
            .single['reason'],
        'http_422');
  });

  test('GPS issue does not prevent reading and acknowledging queued history',
      () async {
    await store.enqueue(context(), 'location', point('a'));
    await store.note(context(),
        setCaptureIssue: true, captureIssue: 'GPS desactivado');
    await store.acknowledge((await store.pending(context())).single, started);
    final status = await store.snapshot(context());
    expect(status.pending, 0);
    expect(status.captureIssue, 'GPS desactivado');
    expect(status.acceptedPointAt, started);
    expect(status.healthyAt(started), false);
  });

  test('restart recovers committed points and preserves idempotency ID',
      () async {
    final directory = await Directory.systemTemp.createTemp('tracking-outbox-');
    final path = '${directory.path}/tracking.db';
    Database? disk;
    try {
      disk = await databaseFactoryFfi.openDatabase(path);
      final first = TrackingOutbox(open: () async => disk!);
      await first.activate(context());
      await first.enqueue(context(), 'location', point('persisted'));
      await disk.close();
      disk = await databaseFactoryFfi.openDatabase(path);
      final reopened = TrackingOutbox(open: () async => disk!);
      final pending = await reopened.pending(context());
      expect(pending.single.payload['clientPointId'], 'persisted');
      expect(pending.single.payload['recordedAt'], started.toIso8601String());
    } finally {
      if (disk != null && disk.isOpen) await disk.close();
      await directory.delete(recursive: true);
    }
  });

  test('a running notification alone does not prove successful tracking', () {
    final now = started.add(const Duration(minutes: 20));
    expect(TrackingSnapshot(heartbeatAt: now).healthyAt(now), false);
    final fresh = TrackingSnapshot(
        heartbeatAt: now,
        acceptedPointAt: now,
        acceptedAt: now,
        intervalSeconds: 30);
    expect(fresh.healthyAt(now), true);
    expect(fresh.healthyAt(now.add(const Duration(minutes: 3))), false);
    expect(context().activeAt(context().autoCloseAt), false);
  });
}
