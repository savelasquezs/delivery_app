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

  testWidgets('Android reproduces the old execute failure and accepts rawQuery', (tester) async {
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

  testWidgets('session initialization and encrypted credential restore work on Android', (tester) async {
    final path = '${await getDatabasesPath()}/hotfix_auth_probe.db';
    Database db = await openDatabase(path, singleInstance: false);
    var storage = SecureStorage(mutex: SessionMutex(open: () async => db));
    try {
      await storage.clearAll();
      expect(await storage.readSession(), isNull);
      await storage.saveTokens(authToken: 'test-only-access', refreshToken: 'test-only-refresh');
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

  testWidgets('outbox upgrade preserves committed points and migration receipts on Android', (tester) async {
    final path = '${await getDatabasesPath()}/hotfix_outbox_probe.db';
    Database db = await openDatabase(path, singleInstance: false);
    final at = DateTime.now().toUtc();
    final context = TrackingContext(
      authSessionId: 'test-only-session', ownerKey: 'test-only-owner', workSessionId: 1,
      startedAt: at.subtract(const Duration(hours: 1)),
      autoCloseAt: at.add(const Duration(hours: 1)),
    );
    final payload = <String, dynamic>{
      'clientPointId': 'retained-point', 'workSessionId': 1,
      'latitude': 6.25, 'longitude': -75.56, 'recordedAt': at.toIso8601String(),
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
}
