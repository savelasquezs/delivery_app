import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth/session_mutex.dart';

const _legacyNamespace = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';

/// Metadata only. Access/refresh tokens remain in encrypted secure storage.
class TrackingContext {
  final String authSessionId;
  final String ownerKey;
  final int workSessionId;
  final DateTime startedAt;
  final DateTime autoCloseAt;

  const TrackingContext(
      {required this.authSessionId,
      required this.ownerKey,
      required this.workSessionId,
      required this.startedAt,
      required this.autoCloseAt});

  bool matches(TrackingContext other) =>
      authSessionId == other.authSessionId &&
      workSessionId == other.workSessionId &&
      ownerKey == other.ownerKey;
  bool activeAt(DateTime now) =>
      !now.isBefore(startedAt) && now.isBefore(autoCloseAt);
  Map<String, Object?> toJson() => {
        'authSessionId': authSessionId,
        'ownerKey': ownerKey,
        'workSessionId': workSessionId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'autoCloseAt': autoCloseAt.toUtc().toIso8601String(),
        'startedAtMs': startedAt.millisecondsSinceEpoch,
        'autoCloseAtMs': autoCloseAt.millisecondsSinceEpoch
      };
  factory TrackingContext.fromJson(Map<String, dynamic> json) =>
      TrackingContext(
          authSessionId: json['authSessionId'] as String,
          ownerKey: json['ownerKey'] as String,
          workSessionId: (json['workSessionId'] as num).toInt(),
          startedAt: DateTime.parse(json['startedAt'] as String).toUtc(),
          autoCloseAt: DateTime.parse(json['autoCloseAt'] as String).toUtc());
}

class OutboxRecord {
  final String id;
  final String kind;
  final String ownerKey;
  final int workSessionId;
  final Map<String, dynamic> payload;
  const OutboxRecord(
      {required this.id,
      required this.kind,
      required this.ownerKey,
      required this.workSessionId,
      required this.payload});
  factory OutboxRecord.fromRow(Map<String, Object?> row) => OutboxRecord(
      id: row['id'] as String,
      kind: row['kind'] as String,
      ownerKey: row['owner_key'] as String,
      workSessionId: row['work_session'] as int,
      payload: Map<String, dynamic>.from(
          jsonDecode(row['payload'] as String) as Map));
}

class TrackingSnapshot {
  final DateTime? capturedAt;
  final DateTime? acceptedPointAt;
  final DateTime? acceptedAt;
  final DateTime? heartbeatAt;
  final String? captureIssue;
  final String? uploadIssue;
  final int pending;
  final int rejected;
  final int intervalSeconds;
  const TrackingSnapshot(
      {this.capturedAt,
      this.acceptedPointAt,
      this.acceptedAt,
      this.heartbeatAt,
      this.captureIssue,
      this.uploadIssue,
      this.pending = 0,
      this.rejected = 0,
      this.intervalSeconds = 300});

  bool healthyAt(DateTime now) {
    final tolerance = Duration(seconds: intervalSeconds * 2 + 30);
    return captureIssue == null &&
        uploadIssue == null &&
        acceptedPointAt != null &&
        heartbeatAt != null &&
        now.difference(acceptedPointAt!) <= tolerance &&
        now.difference(heartbeatAt!) <= const Duration(seconds: 90);
  }

  String labelAt(DateTime now) {
    final issue = captureIssue ?? uploadIssue;
    if (issue != null) return issue;
    if (acceptedPointAt == null) return 'Esperando el primer envío confirmado';
    final seconds =
        now.difference(acceptedPointAt!).inSeconds.clamp(0, 9999999);
    final age = seconds < 60 ? '${seconds}s' : '${seconds ~/ 60} min';
    final suffix =
        '${pending > 0 ? ' · $pending pendientes' : ''}${rejected > 0 ? ' · $rejected rechazados' : ''}';
    return 'Última ubicación confirmada: hace $age$suffix';
  }
}

/// All outbox/ACK/migration writes are short transactions. Network never runs
/// inside a transaction. Removing an ACK cannot overwrite a concurrent capture.
class TrackingOutbox {
  static final shared = TrackingOutbox();
  final Future<Database> Function() open;
  Future<Database>? _opening;
  TrackingOutbox({Future<Database> Function()? open}) : open = open ?? _open;
  static Future<Database> _open() =>
      openDatabase('sa_tracking_outbox_v2.db', singleInstance: false);

  Future<Database> _db() async {
    if (_opening != null) return _opening!;
    final opening = _initialize();
    _opening = opening;
    try {
      return await opening;
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
  }

  Future<Database> _initialize() async {
    final db = await open();
    try {
      // This PRAGMA returns a row; Android rejects it through execute.
      await db.rawQuery('PRAGMA busy_timeout = 1000');
      await retrySqliteBusy(() => db.transaction((tx) async {
            await tx.execute(
                'CREATE TABLE IF NOT EXISTS tracking_context (id INTEGER PRIMARY KEY, value TEXT NOT NULL)');
            await tx.execute('CREATE TABLE IF NOT EXISTS tracking_outbox ('
                'id TEXT PRIMARY KEY, kind TEXT NOT NULL, owner_key TEXT NOT NULL, '
                'work_session INTEGER NOT NULL, payload TEXT NOT NULL, recorded_at INTEGER NOT NULL, '
                "state TEXT NOT NULL DEFAULT 'pending', reason TEXT, attempts INTEGER NOT NULL DEFAULT 0)");
            await tx.execute(
                'CREATE INDEX IF NOT EXISTS tracking_pending ON tracking_outbox(owner_key, state, kind, recorded_at)');
            await tx.execute('CREATE TABLE IF NOT EXISTS tracking_status ('
                'owner_key TEXT NOT NULL, work_session INTEGER NOT NULL, captured_at INTEGER, '
                'accepted_point_at INTEGER, accepted_at INTEGER, heartbeat_at INTEGER, '
                'capture_issue TEXT, upload_issue TEXT, interval_seconds INTEGER NOT NULL DEFAULT 300, '
                'PRIMARY KEY(owner_key, work_session))');
            await tx.execute(
                'CREATE TABLE IF NOT EXISTS tracking_import (fingerprint TEXT PRIMARY KEY)');
            await tx.execute(
                'CREATE TABLE IF NOT EXISTS tracking_communication ('
                'owner_key TEXT NOT NULL, work_session INTEGER NOT NULL, id TEXT NOT NULL, '
                'started_at INTEGER NOT NULL, recovered_at INTEGER, acknowledged INTEGER NOT NULL DEFAULT 0, '
                'PRIMARY KEY(owner_key, work_session))');
          }));
      return db;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  Future<T> _transaction<T>(Future<T> Function(Transaction) body) async {
    final db = await _db();
    return retrySqliteBusy(() => db.transaction(body));
  }

  Future<TrackingContext?> current() async {
    final db = await _db();
    final rows = await retrySqliteBusy(
        () => db.query('tracking_context', where: 'id = 1'));
    if (rows.isEmpty) return null;
    return TrackingContext.fromJson(Map<String, dynamic>.from(
        jsonDecode(rows.single['value'] as String) as Map));
  }

  Future<void> activate(TrackingContext context, {bool onlyIfAbsent = false}) =>
      _transaction((tx) async {
        await tx.insert('tracking_context',
            {'id': 1, 'value': jsonEncode(context.toJson())},
            conflictAlgorithm: onlyIfAbsent
                ? ConflictAlgorithm.ignore
                : ConflictAlgorithm.replace);
        await _ensureStatus(tx, context.ownerKey, context.workSessionId);
      });

  Future<bool> updateCutoff(TrackingContext expected, DateTime cutoff) =>
      _transaction((tx) async {
        final rows = await tx.query('tracking_context', where: 'id = 1');
        if (rows.isEmpty) return false;
        final current = TrackingContext.fromJson(Map<String, dynamic>.from(
            jsonDecode(rows.single['value'] as String) as Map));
        if (!current.matches(expected)) return false;
        final updated = TrackingContext(
            authSessionId: current.authSessionId,
            ownerKey: current.ownerKey,
            workSessionId: current.workSessionId,
            startedAt: current.startedAt,
            autoCloseAt: cutoff);
        await tx.update(
            'tracking_context', {'value': jsonEncode(updated.toJson())},
            where: 'id = 1');
        return true;
      });

  Future<bool> deactivate(TrackingContext expected) => _transaction((tx) async {
        final rows = await tx.query('tracking_context', where: 'id = 1');
        if (rows.isEmpty) return false;
        final context = TrackingContext.fromJson(Map<String, dynamic>.from(
            jsonDecode(rows.single['value'] as String) as Map));
        if (!context.matches(expected)) return false;
        await tx.delete('tracking_context', where: 'id = 1');
        return true;
      });

  Future<void> _ensureStatus(
      DatabaseExecutor tx, String owner, int session) async {
    await tx.insert(
        'tracking_status', {'owner_key': owner, 'work_session': session},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> enqueue(
          TrackingContext context, String kind, Map<String, dynamic> payload) =>
      _transaction((tx) async {
        await _insert(tx, context.ownerKey, kind, payload);
        if (kind == 'location') {
          await _ensureStatus(tx, context.ownerKey, context.workSessionId);
          final recorded = DateTime.parse(payload['recordedAt'] as String)
              .millisecondsSinceEpoch;
          await tx.rawUpdate(
              'UPDATE tracking_status SET captured_at = max(coalesce(captured_at, 0), ?), capture_issue = NULL '
              'WHERE owner_key = ? AND work_session = ?',
              [recorded, context.ownerKey, context.workSessionId]);
        }
      });

  Future<void> _insert(DatabaseExecutor tx, String owner, String kind,
      Map<String, dynamic> payload,
      {String state = 'pending', String? reason}) async {
    final id = payload[kind == 'location' ? 'clientPointId' : 'clientEventId']
        ?.toString();
    final session = int.tryParse(payload['workSessionId']?.toString() ?? '');
    final recorded = DateTime.tryParse(payload['recordedAt']?.toString() ?? '');
    if (id == null || session == null || recorded == null)
      throw const FormatException('Incomplete outbox record');
    await tx.insert(
        'tracking_outbox',
        {
          'id': id,
          'kind': kind,
          'owner_key': owner,
          'work_session': session,
          'payload': jsonEncode(payload),
          'recorded_at': recorded.millisecondsSinceEpoch,
          'state': state,
          'reason': reason
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<OutboxRecord>> pending(TrackingContext context,
      {int limit = 10}) async {
    final db = await _db();
    return retrySqliteBusy(() => db.transaction((tx) async {
          // Latest first, then chronological backfill. The paired API freshness
          // guard prevents historical points from changing live delivery state.
          final rows = await tx.query('tracking_outbox',
              where:
                  "owner_key = ? AND state = 'pending' AND kind = 'location'",
              whereArgs: [context.ownerKey],
              orderBy: 'recorded_at, id',
              limit: limit - 1);
          final latest = await tx.query('tracking_outbox',
              where:
                  "owner_key = ? AND work_session = ? AND state = 'pending' AND kind = 'location'",
              whereArgs: [context.ownerKey, context.workSessionId],
              orderBy: 'recorded_at DESC, id DESC',
              limit: 1);
          final ids = latest.map((r) => r['id']).toSet();
          final selected = [
            ...latest,
            ...rows.where((r) => !ids.contains(r['id']))
          ];
          return selected.map(OutboxRecord.fromRow).toList();
        }));
  }

  Future<List<OutboxRecord>> events(TrackingContext context,
      {int limit = 5}) async {
    final db = await _db();
    final rows = await retrySqliteBusy(() => db.query('tracking_outbox',
        where: "owner_key = ? AND state = 'pending' AND kind = 'event'",
        whereArgs: [context.ownerKey],
        orderBy: 'recorded_at, id',
        limit: limit));
    return rows.map(OutboxRecord.fromRow).toList();
  }

  Future<void> acknowledge(OutboxRecord record, DateTime now) =>
      _transaction((tx) async {
        final deleted = await tx.delete('tracking_outbox',
            where: 'id = ? AND owner_key = ?',
            whereArgs: [record.id, record.ownerKey]);
        if (deleted == 0)
          return; // Duplicate ACK cannot inflate recovered counts.
        if (record.kind == 'location') {
          final recorded =
              DateTime.parse(record.payload['recordedAt'] as String)
                  .millisecondsSinceEpoch;
          await tx.rawUpdate(
              'UPDATE tracking_communication SET acknowledged = acknowledged + 1 '
              'WHERE owner_key = ? AND work_session = ? AND (recovered_at IS NULL OR ? <= recovered_at)',
              [record.ownerKey, record.workSessionId, recorded]);
        }
        if (record.kind == 'location') {
          await _ensureStatus(tx, record.ownerKey, record.workSessionId);
          final recorded =
              DateTime.parse(record.payload['recordedAt'] as String)
                  .millisecondsSinceEpoch;
          await tx.rawUpdate(
              'UPDATE tracking_status SET accepted_point_at = max(coalesce(accepted_point_at, 0), ?), '
              'accepted_at = ?, upload_issue = NULL WHERE owner_key = ? AND work_session = ?',
              [
                recorded,
                now.millisecondsSinceEpoch,
                record.ownerKey,
                record.workSessionId
              ]);
        }
      });

  /// This measures inability to reach our API, not the state of Internet.
  /// Episodes and their summary event are committed with stable identifiers.
  Future<void> beginCommunicationGap(TrackingContext context, DateTime now) =>
      _transaction((tx) async {
        final rows = await tx.query('tracking_communication',
            where: 'owner_key = ? AND work_session = ?',
            whereArgs: [context.ownerKey, context.workSessionId]);
        if (rows.isNotEmpty) {
          if (rows.single['recovered_at'] == null) return;
          // A new failure after a confirmed receipt is a new episode, even if
          // the older backlog has not finished. Never extend across recovery.
          await _finishCommunication(tx, context, rows.single);
        }
        final id = const Uuid().v4();
        await tx.insert('tracking_communication', {
          'owner_key': context.ownerKey,
          'work_session': context.workSessionId,
          'id': id,
          'started_at': now.millisecondsSinceEpoch,
        });
        await _insert(tx, context.ownerKey, 'event', {
          'clientEventId': const Uuid().v5(_legacyNamespace, '$id:lost'),
          '_authSessionId': context.authSessionId,
          'workSessionId': context.workSessionId,
          'eventType':
              'internet_lost', // Compatible wire type; source disambiguates.
          'internetAvailable': null,
          'details':
              'evidence_version=2;source=api_transport;episode=$id;cause=unknown',
          'recordedAt': now.toUtc().toIso8601String(),
        });
      });

  Future<void> recoverCommunication(
          TrackingContext context, DateTime acceptedAt) =>
      _transaction((tx) async {
        await tx.rawUpdate(
            'UPDATE tracking_communication SET recovered_at = coalesce(recovered_at, ?) '
            'WHERE owner_key = ? AND work_session = ?',
            [
              acceptedAt.millisecondsSinceEpoch,
              context.ownerKey,
              context.workSessionId
            ]);
        final rows = await tx.query('tracking_communication',
            where: 'owner_key = ? AND work_session = ?',
            whereArgs: [context.ownerKey, context.workSessionId]);
        if (rows.isEmpty) return;
        final row = rows.single;
        final waiting = Sqflite.firstIntValue(await tx.rawQuery(
                "SELECT count(*) FROM tracking_outbox WHERE owner_key = ? AND work_session = ? "
                "AND kind = 'location' AND state = 'pending' AND recorded_at <= ?",
                [
                  context.ownerKey,
                  context.workSessionId,
                  row['recovered_at']
                ])) ??
            0;
        if (waiting == 0) await _finishCommunication(tx, context, row);
      });

  Future<void> _finishCommunication(DatabaseExecutor tx,
      TrackingContext context, Map<String, Object?> row) async {
    final ended = row['recovered_at'] as int?;
    if (ended == null) return;
    final start = row['started_at'] as int;
    final id = row['id'] as String;
    final count = row['acknowledged'] as int;
    await _insert(tx, context.ownerKey, 'event', {
      'clientEventId': const Uuid().v5(_legacyNamespace, '$id:recovered'),
      '_authSessionId': context.authSessionId,
      'workSessionId': context.workSessionId,
      'eventType': 'internet_recovered',
      'internetAvailable': null,
      'details':
          'evidence_version=2;source=api_transport;episode=$id;queued_location_count=$count',
      'offlineLocationCount': count.clamp(0, 10000),
      'offlineStartedAt':
          DateTime.fromMillisecondsSinceEpoch(start, isUtc: true)
              .toIso8601String(),
      'offlineEndedAt': DateTime.fromMillisecondsSinceEpoch(
              ended < start ? start : ended,
              isUtc: true)
          .toIso8601String(),
      'recordedAt': DateTime.fromMillisecondsSinceEpoch(
              ended < start ? start : ended,
              isUtc: true)
          .toIso8601String(),
    });
    await tx.delete('tracking_communication',
        where: 'owner_key = ? AND work_session = ? AND id = ?',
        whereArgs: [context.ownerKey, context.workSessionId, id]);
  }

  Future<void> reject(OutboxRecord record, String reason) =>
      _transaction((tx) async {
        await tx.update(
            'tracking_outbox', {'state': 'rejected', 'reason': reason},
            where: 'id = ? AND owner_key = ?',
            whereArgs: [record.id, record.ownerKey]);
      });

  Future<void> note(TrackingContext context,
          {String? captureIssue,
          String? uploadIssue,
          bool setCaptureIssue = false,
          bool setUploadIssue = false,
          int? intervalSeconds,
          bool heartbeat = false}) =>
      _transaction((tx) async {
        await _ensureStatus(tx, context.ownerKey, context.workSessionId);
        final values = <String, Object?>{};
        if (setCaptureIssue) values['capture_issue'] = captureIssue;
        if (setUploadIssue) values['upload_issue'] = uploadIssue;
        if (heartbeat)
          values['heartbeat_at'] = DateTime.now().millisecondsSinceEpoch;
        if (intervalSeconds != null)
          values['interval_seconds'] = intervalSeconds;
        if (values.isNotEmpty)
          await tx.update('tracking_status', values,
              where: 'owner_key = ? AND work_session = ?',
              whereArgs: [context.ownerKey, context.workSessionId]);
      });

  Future<TrackingSnapshot> snapshot(TrackingContext context) async {
    final db = await _db();
    return retrySqliteBusy(() => db.transaction((tx) async {
          final rows = await tx.query('tracking_status',
              where: 'owner_key = ? AND work_session = ?',
              whereArgs: [context.ownerKey, context.workSessionId]);
          final row = rows.isEmpty ? <String, Object?>{} : rows.single;
          final counts = await tx.rawQuery(
              'SELECT state, count(*) AS count FROM tracking_outbox '
              'WHERE owner_key = ? GROUP BY state',
              [context.ownerKey]);
          int count(String state) => counts
              .where((r) => r['state'] == state)
              .fold(0, (n, r) => n + (r['count'] as int));
          DateTime? date(String key) => row[key] is int
              ? DateTime.fromMillisecondsSinceEpoch(row[key] as int,
                  isUtc: true)
              : null;
          return TrackingSnapshot(
              capturedAt: date('captured_at'),
              acceptedPointAt: date('accepted_point_at'),
              acceptedAt: date('accepted_at'),
              heartbeatAt: date('heartbeat_at'),
              captureIssue: row['capture_issue'] as String?,
              uploadIssue: row['upload_issue'] as String?,
              intervalSeconds: row['interval_seconds'] as int? ?? 300,
              pending: count('pending'),
              rejected: count('rejected'));
        }));
  }

  /// A commit receipt makes a crash between SQL commit and preference removal
  /// harmless, including after an acknowledged imported point has been deleted.
  Future<void> importLegacy(
          String sourceKey, String raw, String kind, TrackingContext context,
          {bool rejected = false}) =>
      _transaction((tx) async {
        final fingerprint =
            const Uuid().v5(_legacyNamespace, '$sourceKey:$raw');
        if ((await tx.query('tracking_import',
                where: 'fingerprint = ?', whereArgs: [fingerprint]))
            .isNotEmpty) return;
        List<dynamic> items;
        try {
          final decoded = jsonDecode(raw);
          items = decoded is List ? decoded : [decoded];
        } catch (_) {
          items = [raw];
        }
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
          final payload = item is Map
              ? Map<String, dynamic>.from(
                  item['payload'] is Map ? item['payload'] as Map : item)
              : <String, dynamic>{'raw': item};
          payload[kind == 'location' ? 'clientPointId' : 'clientEventId'] ??=
              const Uuid().v5(_legacyNamespace, '$fingerprint:$i');
          final session =
              int.tryParse(payload['workSessionId']?.toString() ?? '');
          final bound = session != null &&
              (session == context.workSessionId ||
                  payload['_authSessionId'] == context.authSessionId ||
                  payload['_ownerKey'] == context.ownerKey);
          final parsedTime =
              DateTime.tryParse(payload['recordedAt']?.toString() ?? '');
          final validTime = parsedTime != null;
          payload['workSessionId'] = session ?? -1;
          payload['recordedAt'] = (parsedTime ??
                  DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
              .toUtc()
              .toIso8601String();
          if (!validTime)
            payload['recordedAt'] =
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
                    .toIso8601String();
          await _insert(tx, bound ? context.ownerKey : 'unbound', kind, payload,
              state: rejected || !bound || !validTime ? 'rejected' : 'pending',
              reason: !bound
                  ? 'legacy_owner_unverified'
                  : !validTime
                      ? 'invalid_recorded_at'
                      : rejected
                          ? 'legacy_rejected'
                          : null);
        }
        await tx.insert('tracking_import', {'fingerprint': fingerprint});
      });
}
