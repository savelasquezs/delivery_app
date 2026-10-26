import 'dart:async';

import 'package:delivery_app/core/auth/session_mutex.dart';
import 'package:delivery_app/features/tracking/tracking_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'independent Android connections finish capture, ACK and UI reads',
      (tester) async {
    final path = '${await getDatabasesPath()}/outbox_concurrency_probe.db';
    final first = await openDatabase(path, singleInstance: false);
    final second = await openDatabase(path, singleInstance: false);
    final auth = await openDatabase(
        '${await getDatabasesPath()}/auth_concurrency_probe.db',
        singleInstance: false);
    Database? reopeningDb;
    final ui = TrackingOutbox(open: () async => first);
    final gps = TrackingOutbox(open: () async => second);
    final mutex = SessionMutex(open: () async => auth);
    final now = DateTime.now().toUtc();
    final context = TrackingContext(
      authSessionId: 'concurrency-test',
      ownerKey: 'probe-owner',
      workSessionId: 42,
      startedAt: now.subtract(const Duration(minutes: 1)),
      autoCloseAt: now.add(const Duration(hours: 1)),
    );
    try {
      await ui.activate(context);
      await gps.current();
      await mutex.protect((lease) => lease.ensureOwned());
      await auth
          .rawUpdate('UPDATE session_mutex SET owner = ?, expires_at = ?', [
        '-1:terminated-process',
        DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch
      ]);
      await SessionMutex(open: () async => auth)
          .protect((lease) => lease.ensureOwned())
          .timeout(const Duration(seconds: 2));
      final reopening = TrackingOutbox(
          open: () async =>
              reopeningDb ??= await openDatabase(path, singleInstance: false));
      late Future<List<Object?>> readers;
      await SessionMutex(databasePath: 'sa_tracking_write_mutex.db')
          .protect((lease) async {
        await lease.ensureOwned();
        await first.transaction((tx) async {
          await tx.rawQuery('SELECT count(*) FROM tracking_context');
          readers = Future.wait<Object?>([
            gps.current(),
            gps.cached('probe-owner', 'route'),
            gps.operations('probe-owner'),
            gps.events(context),
            gps.hasPendingLocationHistory(context),
            reopening.current(),
          ]);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tx.rawQuery('SELECT count(*) FROM tracking_context');
        });
      }).timeout(const Duration(seconds: 3));
      await readers.timeout(const Duration(seconds: 3));
      final watch = Stopwatch()..start();
      await Future.wait([
        () async {
          for (var i = 0; i < 30; i++) {
            await gps.enqueue(context, 'location', {
              'clientPointId': 'concurrent-$i',
              'workSessionId': context.workSessionId,
              'recordedAt': now.add(Duration(seconds: i)).toIso8601String(),
            });
            await gps.note(context, heartbeat: true);
          }
        }(),
        () async {
          for (var i = 0; i < 30; i++) {
            await ui.snapshot(context);
            await ui.pending(context);
            await ui.current();
            await ui.cached('probe-owner', 'route');
            await ui.operations('probe-owner');
          }
        }(),
        () async {
          for (var i = 0; i < 30; i++) {
            await mutex.protect((lease) => lease.ensureOwned());
          }
        }(),
      ]).timeout(const Duration(seconds: 15));
      expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
      expect((await ui.snapshot(context)).pending, 30);
      final records = await gps.pending(context, limit: 31);
      expect(records.map((record) => record.id).toSet(), hasLength(30));
      await Future.wait(records.map((record) => gps.acknowledge(record, now)));
      expect((await ui.snapshot(context)).pending, 0);
      expect((await ui.current())!.matches(context), isTrue);
    } finally {
      await first.close();
      await second.close();
      await auth.close();
      await reopeningDb?.close();
      await deleteDatabase(path);
      await deleteDatabase(
          '${await getDatabasesPath()}/auth_concurrency_probe.db');
    }
  });
}
