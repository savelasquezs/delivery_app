import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:delivery_app/core/storage/secure_storage.dart';
import 'package:delivery_app/core/auth/token_session.dart';
import 'dart:async';
import 'dart:isolate';

import 'package:delivery_app/core/auth/session_mutex.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> contender(String path) async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(path,
      options: OpenDatabaseOptions(singleInstance: false));
  final mutex = SessionMutex(
      open: () async => db, pollInterval: const Duration(milliseconds: 5));
  try {
    await mutex.protect((lease) async {
      await db.rawUpdate('UPDATE probe SET active = active + 1');
      await db.rawUpdate('UPDATE probe SET maximum = max(maximum, active)');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await lease.ensureOwned();
      await db.rawUpdate(
          'UPDATE probe SET active = active - 1, completed = completed + 1');
    });
  } finally {
    await db.close();
  }
}

Future<void> runContender(String path) => Isolate.run(() => contender(path));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'atomic session reads stay available during refresh and legacy migration remains serialized',
      () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    final storage = SecureStorage(mutex: SessionMutex(open: () async => db));
    const old = TokenSession(
        id: 'login', accessToken: 'old-access', refreshToken: 'old-refresh');
    const next = TokenSession(
        id: 'login', accessToken: 'next-access', refreshToken: 'next-refresh');
    FlutterSecureStorage.setMockInitialValues(
        {'auth_session_v2': jsonEncode(old.toJson())});
    final entered = Completer<void>(), release = Completer<void>();
    final refreshing = storage.withSessionLock((locked) async {
      entered.complete();
      await release.future;
      await locked.writeSession(next);
    });
    try {
      await entered.future;
      expect(
          (await storage
                  .readSession()
                  .timeout(const Duration(milliseconds: 200)))!
              .refreshToken,
          'old-refresh');
    } finally {
      release.complete();
      await refreshing;
    }
    expect((await storage.readSession())!.refreshToken, 'next-refresh');
    FlutterSecureStorage.setMockInitialValues(
        {'auth_token': 'legacy-access', 'refresh_token': 'legacy-refresh'});
    final migrated =
        await Future.wait([storage.readSession(), storage.readSession()]);
    expect(migrated.first!.id, migrated.last!.id);
    expect(migrated.first!.accessToken, 'legacy-access');
    await storage.clearAll();
    expect(await storage.readSession(), isNull);
    await db.close();
  });
  test(
      'Android restart recovers the previous process without stealing a live engine lease',
      () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      await SessionMutex(open: () async => db).protect((_) async {});
      final expires =
          DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch;
      await db.rawUpdate('UPDATE session_mutex SET owner = ?, expires_at = ?',
          ['-1:terminated', expires]);
      final recovered =
          SessionMutex(open: () async => db, reclaimPreviousProcess: true);
      await recovered
          .protect((lease) => lease.ensureOwned())
          .timeout(const Duration(seconds: 2));
      await db.rawUpdate('UPDATE session_mutex SET owner = ?, expires_at = ?',
          ['$pid:live-engine', expires]);
      final contender = SessionMutex(
          open: () async => db,
          reclaimPreviousProcess: true,
          waitTimeout: const Duration(milliseconds: 50),
          pollInterval: const Duration(milliseconds: 5));
      await expectLater(
          contender.protect((_) async {}), throwsA(isA<TimeoutException>()));
    } finally {
      await db.close();
    }
  });
  test('SQLite CAS excludes contenders from separate Dart isolates', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('tracking-lock-');
    final path = '${directory.path}/coordination.db';
    final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      await db.execute(
          'CREATE TABLE probe (active INTEGER, maximum INTEGER, completed INTEGER)');
      await db.rawInsert('INSERT INTO probe VALUES (0, 0, 0)');
      // Initialize schema before launching the independent database connections.
      await SessionMutex(open: () async => db).protect((_) async {});
      await Future.wait(List.generate(4, (_) => runContender(path)));
      final row = (await db.query('probe')).single;
      expect(row['maximum'], 1);
      expect(row['active'], 0);
      expect(row['completed'], 4);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

  test(
      'exceptions release ownership and stale owner cannot release another lock',
      () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final mutex = SessionMutex(open: () async => db);
    try {
      await expectLater(mutex.protect<void>((_) async {
        throw StateError('failed');
      }), throwsStateError);
      await mutex.protect((lease) async {
        await lease.ensureOwned();
        await db
            .rawUpdate('UPDATE session_mutex SET owner = ?, expires_at = ?', [
          '$pid:replacement',
          DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch
        ]);
        await expectLater(lease.ensureOwned(), throwsStateError);
      });
      expect((await db.query('session_mutex')).single['owner'],
          '$pid:replacement');
    } finally {
      await db.close();
    }
  });
}
