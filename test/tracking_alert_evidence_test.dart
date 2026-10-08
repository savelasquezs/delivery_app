import 'package:delivery_app/features/tracking/location_tracking_policy.dart';
import 'package:delivery_app/features/tracking/tracking_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final start = DateTime.utc(2026, 10, 8, 15);
  TrackingContext context({String owner = 'driver-a', int session = 1}) =>
      TrackingContext(
          authSessionId: 'auth-a',
          ownerKey: owner,
          workSessionId: session,
          startedAt: start,
          autoCloseAt: start.add(const Duration(hours: 10)));
  Map<String, dynamic> point(String id, int minute) => {
        'clientPointId': id,
        'workSessionId': 1,
        'recordedAt': start.add(Duration(minutes: minute)).toIso8601String(),
      };
  late Database db;
  late TrackingOutbox box;
  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    box = TrackingOutbox(open: () async => db);
    await box.activate(context());
  });
  tearDown(() => db.close());

  test('GPS disabled does not imply permission revoked', () {
    const state = LocationPermissionState(
        serviceEnabled: false,
        permission: LocationPermission.always,
        accuracy: LocationAccuracyStatus.precise);
    expect(state.permissionUsable, isTrue);
    expect(state.canTrackInBackground, isFalse);
    expect(state.issue, LocationTrackingIssue.gpsDisabled);
  });
  test('failed state read never proves a disabled setting', () {
    const state = LocationPermissionState(
        serviceEnabled: true,
        permission: LocationPermission.always,
        accuracy: LocationAccuracyStatus.precise,
        readFailed: true);
    expect(state.canTrackInBackground, isFalse);
    expect(state.issue, LocationTrackingIssue.unavailable);
  });
  test('durable transport recovery preserves first receipt and ACK count',
      () async {
    await box.beginCommunicationGap(context(), start);
    await box.beginCommunicationGap(
        context(), start.add(const Duration(minutes: 1)));
    for (var i = 0; i < 4; i++) {
      await box.enqueue(context(), 'location', point('p$i', i));
    }
    final batch = await box.pending(context());
    final receipt = start.add(const Duration(minutes: 12));
    await box.acknowledge(batch.first, receipt);
    await box.recoverCommunication(context(), receipt);
    expect(
        (await box.events(context()))
            .where((e) => e.payload['eventType'] == 'internet_recovered'),
        isEmpty);
    final restarted = TrackingOutbox(open: () async => db);
    for (final row in batch.skip(1)) {
      await restarted.acknowledge(row, receipt.add(const Duration(minutes: 2)));
      await restarted.acknowledge(row, receipt.add(const Duration(minutes: 2)));
      await restarted.recoverCommunication(
          context(), receipt.add(const Duration(minutes: 2)));
    }
    final events = await restarted.events(context());
    expect(events, hasLength(2));
    final recovery = events
        .singleWhere((e) => e.payload['eventType'] == 'internet_recovered')
        .payload;
    expect(recovery['offlineLocationCount'], 4);
    expect(recovery['offlineStartedAt'], start.toIso8601String());
    expect(recovery['offlineEndedAt'], receipt.toIso8601String());
    expect(recovery['internetAvailable'], isNull);
    expect(recovery['details'], contains('source=api_transport'));
    await restarted.recoverCommunication(
        context(), receipt.add(const Duration(minutes: 3)));
    expect(await restarted.events(context()), hasLength(2));
  });
  test('server recovery can be reported without a new GPS fix', () async {
    await box.beginCommunicationGap(context(), start);
    await box.recoverCommunication(
        context(), start.add(const Duration(minutes: 11)));
    final events = await box.events(context());
    expect(events, hasLength(2));
    expect(events.last.payload['offlineLocationCount'], 0);
    expect(events.last.payload['internetAvailable'], isNull);
  });
  test('another owner or work session cannot recover an episode', () async {
    await box.beginCommunicationGap(context(), start);
    await box.recoverCommunication(
        context(owner: 'driver-b'), start.add(const Duration(minutes: 11)));
    await box.recoverCommunication(
        context(session: 2), start.add(const Duration(minutes: 11)));
    expect(await box.events(context()), hasLength(1));
  });
  test('a new failure never extends through a confirmed recovery', () async {
    await box.beginCommunicationGap(context(), start);
    await box.enqueue(context(), 'location', point('old', 1));
    final firstRecovery = start.add(const Duration(minutes: 5));
    await box.recoverCommunication(context(), firstRecovery);
    await box.beginCommunicationGap(
        context(), start.add(const Duration(minutes: 7)));
    final events = await box.events(context());
    expect(events, hasLength(3));
    expect(
        events
            .singleWhere((e) => e.payload['eventType'] == 'internet_recovered')
            .payload['offlineEndedAt'],
        firstRecovery.toIso8601String());
  });
}
