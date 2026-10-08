import 'dart:async';
import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// SQLite busy_timeout is not uniformly honored by all native/FFI adapters.
/// Retry only lock contention, never malformed SQL, corruption or I/O errors.
Future<T> retrySqliteBusy<T>(Future<T> Function() operation,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final watch = Stopwatch()..start();
  while (true) {
    try {
      return await operation();
    } on DatabaseException catch (error) {
      final code = error.getResultCode();
      final primaryCode = code == null ? null : code & 0xff;
      final message = error.toString().toLowerCase();
      final busy = primaryCode == 5 || primaryCode == 6 ||
          (code == null && (message.contains('database is locked') ||
              message.contains('database is busy')));
      if (!busy || watch.elapsed >= timeout) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
}

/// Short SQLite CAS operations arbitrate different Flutter engines/isolate heaps.
/// No database transaction is held during HTTP or encrypted credential I/O.
class SessionMutex {
  static final shared = SessionMutex();
  final Future<Database> Function() open;
  final Duration leaseDuration;
  final Duration waitTimeout;
  final Duration pollInterval;
  Future<Database>? _database;

  SessionMutex({
    Future<Database> Function()? open,
    this.leaseDuration = const Duration(minutes: 2),
    this.waitTimeout = const Duration(seconds: 30),
    this.pollInterval = const Duration(milliseconds: 100),
  }) : open = open ?? _open;

  static Future<Database> _open() => openDatabase(
        'sa_session_mutex.db',
        singleInstance: false,
      );

  Future<Database> _db() async {
    if (_database != null) return _database!;
    final opening = _initialize();
    _database = opening;
    try {
      return await opening;
    } catch (_) {
      if (identical(_database, opening)) _database = null;
      rethrow;
    }
  }

  Future<Database> _initialize() async {
    final db = await open();
    try {
      await db.execute('PRAGMA busy_timeout = 1000');
      await retrySqliteBusy(() => db.execute(
          'CREATE TABLE IF NOT EXISTS session_mutex ('
          'name TEXT PRIMARY KEY, owner TEXT, expires_at INTEGER NOT NULL)'));
      await retrySqliteBusy(() => db.rawInsert(
          'INSERT OR IGNORE INTO session_mutex '
          '(name, owner, expires_at) VALUES (?, NULL, 0)', ['auth']));
      return db;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  Future<T> protect<T>(Future<T> Function(SessionLease lease) operation) async {
    final db = await _db();
    final owner = '$pid:${const Uuid().v4()}';
    final watch = Stopwatch()..start();
    while (true) {
      final remaining = waitTimeout - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Session coordination is busy');
      }
      final changed = await retrySqliteBusy(() {
        final now = DateTime.now().millisecondsSinceEpoch;
        return db.rawUpdate(
          'UPDATE session_mutex SET owner = ?, expires_at = ? '
          'WHERE name = ? AND (owner IS NULL OR expires_at <= ?)',
          [owner, now + leaseDuration.inMilliseconds, 'auth', now],
        );
      }, timeout: remaining);
      if (changed == 1) break;
      await Future<void>.delayed(pollInterval);
    }
    final lease = SessionLease._(db, owner, leaseDuration);
    final heartbeat = Timer.periodic(leaseDuration ~/ 4, (_) {
      unawaited(lease._renew());
    });
    try {
      return await operation(lease);
    } finally {
      heartbeat.cancel();
      lease._closed = true;
      // Never mask a completed credential write with a cleanup exception.
      // Expiry recovers the lock if the database becomes unavailable here.
      try {
        await retrySqliteBusy(() => db.rawUpdate(
          'UPDATE session_mutex SET owner = NULL, expires_at = 0 '
          'WHERE name = ? AND owner = ?', ['auth', owner]));
      } on DatabaseException catch (_) {}
    }
  }
}

class SessionLease {
  final Database _db;
  final String _owner;
  final Duration _duration;
  bool _closed = false;
  bool _renewing = false;
  bool _lost = false;

  SessionLease._(this._db, this._owner, this._duration);

  Future<void> ensureOwned() async {
    if (_closed || _lost) throw StateError('Session lease lost');
    final rows = await retrySqliteBusy(() => _db.rawQuery(
      'SELECT owner, expires_at FROM session_mutex WHERE name = ?', ['auth']));
    if (_closed || _lost || rows.isEmpty ||
        rows.single['owner'] != _owner ||
        (rows.single['expires_at'] as int) <=
            DateTime.now().millisecondsSinceEpoch) {
      _lost = true;
      throw StateError('Session lease lost');
    }
  }

  Future<void> _renew() async {
    if (_closed || _lost || _renewing) return;
    _renewing = true;
    try {
      final changed = await retrySqliteBusy(() {
        if (_closed) return Future<int>.value(0);
        final now = DateTime.now().millisecondsSinceEpoch;
        return _db.rawUpdate(
          'UPDATE session_mutex SET expires_at = ? '
          'WHERE name = ? AND owner = ? AND expires_at > ?',
          [now + _duration.inMilliseconds, 'auth', _owner, now],
        );
      });
      if (changed != 1) _lost = true;
    } catch (_) {
      _lost = true;
    } finally {
      _renewing = false;
    }
  }
}
