import 'dart:async';
import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// A short SQLite CAS, not a Dart static/Completer, arbitrates different engines.
/// No SQLite transaction or native worker is held while doing HTTP/secure I/O.
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
    await db.execute('PRAGMA busy_timeout = 1000');
    await db.execute('CREATE TABLE IF NOT EXISTS session_mutex ('
        'name TEXT PRIMARY KEY, owner TEXT, expires_at INTEGER NOT NULL)');
    await db.rawInsert(
        'INSERT OR IGNORE INTO session_mutex '
        '(name, owner, expires_at) VALUES (?, NULL, 0)',
        ['auth']);
    return db;
  }

  Future<T> protect<T>(Future<T> Function(SessionLease lease) operation) async {
    final db = await _db();
    final owner = '$pid:${const Uuid().v4()}';
    final watch = Stopwatch()..start();
    while (true) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final changed = await db.rawUpdate(
        'UPDATE session_mutex SET owner = ?, expires_at = ? '
        'WHERE name = ? AND (owner IS NULL OR expires_at <= ?)',
        [owner, now + leaseDuration.inMilliseconds, 'auth', now],
      );
      if (changed == 1) break;
      if (watch.elapsed >= waitTimeout) {
        throw TimeoutException('Session coordination is busy');
      }
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
      await db.rawUpdate(
        'UPDATE session_mutex SET owner = NULL, expires_at = 0 '
        'WHERE name = ? AND owner = ?',
        ['auth', owner],
      );
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
    final rows = await _db.rawQuery(
      'SELECT owner, expires_at FROM session_mutex WHERE name = ?',
      ['auth'],
    );
    if (rows.isEmpty ||
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
      final now = DateTime.now().millisecondsSinceEpoch;
      final changed = await _db.rawUpdate(
        'UPDATE session_mutex SET expires_at = ? '
        'WHERE name = ? AND owner = ? AND expires_at > ?',
        [now + _duration.inMilliseconds, 'auth', _owner, now],
      );
      if (changed != 1) _lost = true;
    } catch (_) {
      _lost =
          true; // Fail closed: never save credentials after losing ownership.
    } finally {
      _renewing = false;
    }
  }
}
