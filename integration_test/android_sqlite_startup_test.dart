import 'dart:convert';

import 'package:delivery_app/core/auth/session_mutex.dart';
import 'package:delivery_app/core/storage/secure_storage.dart';
import 'package:delivery_app/features/tracking/tracking_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';

// Run only on the disposable CI emulator: exercises the REAL Android sqflite
// plugin and secure storage, not desktop FFI. No restaurant API is contacted.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android reproduces the old execute failure and accepts rawQuery',
      (tester) async {
    final path = '${await getDatabasesPath()}/hotfix_pragma_probe.db';
    final db = await openDatabase(path, singleInstance: false);
    try {
      await expectLater(db.execute('PRAGMA busy_timeout = 1000'),
          throwsA(isA<DatabaseException>()));
      final result = await db.rawQuery('PRAGMA busy_timeout = 1000');
      expect(result.single.values.single, 1000);
    } finally {
      await db.close();
      await deleteDatabase(path);
    }
  });

  testWidgets(
      'session initialization and encrypted credential restore work on Android',
      (tester) async {
    final path = '${await getDatabasesPath()}/hotfix_auth_probe.db';
    Database db = await openDatabase(path, singleInstance: false);
    var storage = SecureStorage(mutex: SessionMutex(open: () async => db));
    try {
      await storage.clearAll();
      expect(await storage.readSession(), isNull);
      await storage.saveTokens(
          authToken: 'test-only-access', refreshToken: 'test-only-refresh');
      final original = (await storage.readSession())!;
      expect(original.accessToken, 'test-only-access');
      await db.close();
      db = await openDatabase(path, singleInstance: false);
      storage = SecureStorage(mutex: SessionMutex(open: () async => db));
      final restored = (await storage.readSession())!;
      expect(restored.id, original.id);
      expect(restored.refreshToken, 'test-only-refresh');
      final timeout = await db.rawQuery('PRAGMA busy_timeout');
      expect(timeout.single.values.single, 1000);
    } finally {
      if (db.isOpen) {
        await storage.clearAll();
        await db.close();
      }
      await deleteDatabase(path);
    }
  });

  testWidgets(
      'outbox upgrade preserves committed points and migration receipts on Android',
      (tester) async {
    final path = '${await getDatabasesPath()}/hotfix_outbox_probe.db';
    Database db = await openDatabase(path, singleInstance: false);
    final at = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch, isUtc: true);
    final context = TrackingContext(
      authSessionId: 'test-only-session',
      ownerKey: 'test-only-owner',
      workSessionId: 1,
      startedAt: at.subtract(const Duration(hours: 1)),
      autoCloseAt: at.add(const Duration(hours: 1)),
    );
    final payload = <String, dynamic>{
      'clientPointId': 'retained-point',
      'workSessionId': 1,
      'latitude': 6.25,
      'longitude': -75.56,
      'recordedAt': at.toIso8601String(),
    };
    final legacy = jsonEncode([payload]);
    try {
      var outbox = TrackingOutbox(open: () async => db);
      await outbox.activate(context);
      await outbox.importLegacy('hotfix-legacy', legacy, 'location', context);
      expect((await outbox.pending(context)).single.id, 'retained-point');
      await db.close();
      db = await openDatabase(path, singleInstance: false);
      outbox = TrackingOutbox(open: () async => db);
      final restored = (await outbox.current())!;
      expect(restored.matches(context), isTrue);
      final point = (await outbox.pending(context)).single;
      expect(point.payload['recordedAt'], at.toIso8601String());
      await outbox.acknowledge(point, at);
      await outbox.importLegacy('hotfix-legacy', legacy, 'location', context);
      expect(await outbox.pending(context), isEmpty);
      expect((await outbox.snapshot(context)).acceptedPointAt, at);
    } finally {
      if (db.isOpen) await db.close();
      await deleteDatabase(path);
    }
  });
  testWidgets('Android resumes a bounded 120-point migration without loss',
      (tester) async {
    final path = '${await getDatabasesPath()}/tracking_batch_migration_probe.db';
    Database db = await openDatabase(path, singleInstance: false);
    final at = DateTime.now().toUtc();
    final context = TrackingContext(
      authSessionId: 'batch-session',
      ownerKey: 'batch-owner',
      workSessionId: 42,
      startedAt: at.subtract(const Duration(minutes: 10)),
      autoCloseAt: at.add(const Duration(hours: 2)),
    );
    final original = List.generate(
        120,
        (i) => {
              'clientPointId': 'historic-$i',
              'workSessionId': 42,
              'latitude': 6.25,
              'longitude': -75.56,
              'recordedAt': at.add(Duration(seconds: i)).toIso8601String(),
            });
    final legacy = jsonEncode(original);
    try {
      var store = TrackingOutbox(open: () async => db);
      await store.activate(context);
      expect(await store.importLegacyBatch(
          'old-history', legacy, 'location', context, batchSize: 25), false);
      expect((await db.query('tracking_import_cursor')).single['next_index'],
          25);
      await db.close();
      db = await openDatabase(path, singleInstance: false);
      store = TrackingOutbox(open: () async => db);
      var finished = false;
      for (var i = 0; i < 10 && !finished; i++) {
        finished = await store.importLegacyBatch(
            'old-history', legacy, 'location', context, batchSize: 25);
      }
      expect(finished, isTrue);
      expect((await db.query('tracking_outbox')).length, 120);
      expect((await db.query('tracking_import_cursor')), isEmpty);
      expect((await db.query('tracking_import')), hasLength(1));
      expect(await store.importLegacyBatch(
          'old-history', legacy, 'location', context, batchSize: 25), true);
      expect((await db.query('tracking_outbox')).length, 120);
    } finally {
      if (db.isOpen) await db.close();
      await deleteDatabase(path);
    }
  });

}
