import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/storage/secure_storage.dart';
import '../../core/auth/session_refresh.dart';
import 'tracking_http_client.dart';
import 'tracking_outbox.dart';
import 'tracking_scheduler.dart';
import 'work_session_models.dart';
import '../../core/version/delivery_app_version.dart';
import 'location_tracking_policy.dart';

const _kAuthSessionId = 'sa_loc_auth_session_id';
const _kRejectedQueue = 'sa_loc_rejected_queue';
final _outbox = TrackingOutbox.shared;
const _kAuthToken = 'sa_loc_auth_token';
const _kBaseUrl = 'sa_loc_base_url';
const _kVersionName = 'sa_delivery_app_version';
const _kBuildNumber = 'sa_delivery_app_build';
const _kPackageName = 'sa_delivery_app_package';
const _kOfflineQueue = 'sa_loc_offline_queue';
const _kDeviceEventQueue = 'sa_device_event_queue';
const _kNativeDeviceEventQueue = 'sa_native_device_event_queue';
const _kNativeDeviceEventPrefix = 'sa_native_device_event_';
const _kNativeTrackingActive = 'sa_native_tracking_active';
const _kWorkSessionId = 'sa_loc_work_session_id';
const _kAutoCloseAt = 'sa_loc_auto_close_at';
const _kLightIntervalSeconds = 'sa_loc_light_interval_seconds';
const _kActiveIntervalSeconds = 'sa_loc_active_interval_seconds';
const _kTrackingMode = 'sa_loc_tracking_mode';
const _kDeliveryRouteId = 'sa_loc_delivery_route_id';
const _kGpsEnabled = 'sa_loc_gps_enabled';
const _kLocationPermissionGranted = 'sa_loc_permission_granted';
const _kInternetAvailable =
    'sa_loc_internet_available'; // Legacy preference, cleanup only.
const _kBatteryLowReported = 'sa_loc_battery_low_reported';
const _kTrackingExpectedActive = 'sa_loc_expected_active';
const _kUnexpectedStopReportedSession = 'sa_loc_stop_reported_session';
const _modeLight = 'light';
const _modeActiveDelivery = 'active_delivery';
const _batteryLowThresholdPercent = 15;
const _uuid = Uuid();
TrackingHttpClient? _cachedTrackingClient;
String? _cachedTrackingBaseUrl;
TrackingContext? _cachedTrackingContext;

/// Only stage names, elapsed times and exception types are logged. Never
/// include JWTs, device identifiers, coordinates or customer details.
Future<T> _traceTrackingPhase<T>(
    String stage, Future<T> Function() action) async {
  final watch = Stopwatch()..start();
  debugPrint('TrackingStartup phase=$stage begin');
  try {
    final result = await action();
    debugPrint(
        'TrackingStartup phase=$stage ok elapsedMs=${watch.elapsedMilliseconds}');
    return result;
  } catch (error) {
    debugPrint('TrackingStartup phase=$stage failed '
        'elapsedMs=${watch.elapsedMilliseconds} type=${error.runtimeType}');
    rethrow;
  }
}

Future<void> _recordDeviceEvent(
  String eventType, {
  String? clientEventId,
  int? batteryLevel,
  bool? internetAvailable,
  bool? gpsEnabled,
  bool? locationPermissionGranted,
  String? details,
  int? offlineLocationCount,
  DateTime? offlineStartedAt,
  DateTime? offlineEndedAt,
  DateTime? recordedAt,
}) async {
  final context = await _outbox.current();
  if (context == null) return;
  await _outbox.enqueue(context, 'event', {
    '_authSessionId': context.authSessionId,
    'clientEventId': clientEventId ?? _uuid.v4(),
    'workSessionId': context.workSessionId,
    'eventType': eventType,
    'batteryLevelPercent': batteryLevel,
    'internetAvailable': internetAvailable,
    'gpsEnabled': gpsEnabled,
    'locationPermissionGranted': locationPermissionGranted,
    'details': details,
    'offlineLocationCount': offlineLocationCount,
    'offlineStartedAt': offlineStartedAt?.toUtc().toIso8601String(),
    'offlineEndedAt': offlineEndedAt?.toUtc().toIso8601String(),
    'recordedAt': (recordedAt ?? DateTime.now()).toUtc().toIso8601String(),
  });
}

Future<void> _migrateLegacyQueues(TrackingContext context) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final sources = <String, String>{
    _kOfflineQueue: 'location',
    _kDeviceEventQueue: 'event',
    _kNativeDeviceEventQueue: 'event',
    _kRejectedQueue: 'location',
    for (final key in prefs
        .getKeys()
        .where((k) => k.startsWith(_kNativeDeviceEventPrefix)))
      key: 'event',
  };
  for (final source in sources.entries) {
    final raw = prefs.getString(source.key);
    if (raw == null) continue;
    final complete = await _outbox.importLegacyBatch(
        source.key, raw, source.value, context,
        rejected: source.key == _kRejectedQueue);
    if (!complete) {
      // One bounded batch per sync. A later tick will resume using the
      // committed cursor. No historical point or preference is discarded.
      break;
    }
    // SQL receipt is committed before removing the old value. Never overwrite
    // another writer's new native event or a changed legacy queue.
    await prefs.reload();
    if (prefs.getString(source.key) == raw) await prefs.remove(source.key);
  }
}

Future<TrackingContext?> _ensureTrackingContext() async {
  final existing = await _outbox.current();
  if (existing != null) return existing;
  // Upgrade/reboot of an existing, still-authorized work session needs no UI.
  final storage = SecureStorage();
  final auth = await storage.readSession();
  final raw = await storage.getWorkSessionData();
  final baseUrl = await FlutterForegroundTask.getData<String>(key: _kBaseUrl);
  final workId = await FlutterForegroundTask.getData<int>(key: _kWorkSessionId);
  final expected = await FlutterForegroundTask.getData<bool>(
          key: _kTrackingExpectedActive) ??
      false;
  if (!expected || auth == null || raw == null || baseUrl == null) return null;
  final session = DeliveryWorkSession.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map));
  final oldAuth =
      await FlutterForegroundTask.getData<String>(key: _kAuthSessionId);
  final oldToken =
      await FlutterForegroundTask.getData<String>(key: _kAuthToken);
  if (session.id != workId ||
      !session.isActive ||
      !DateTime.now().isBefore(session.autoCloseAt) ||
      (oldAuth != auth.id &&
          !(oldAuth == null && oldToken == auth.accessToken))) return null;
  final context = _contextFor(session, auth.id, baseUrl);
  await _outbox.activate(context, onlyIfAbsent: true);
  final current = await _outbox.current();
  if (current != null && current.matches(context)) {
    await FlutterForegroundTask.saveData(key: _kAuthSessionId, value: auth.id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'sa_native_tracking_context', jsonEncode(context.toJson()));
  }
  return current;
}

TrackingContext _contextFor(
        DeliveryWorkSession session, String authId, String baseUrl) =>
    TrackingContext(
        authSessionId: authId,
        ownerKey: jsonEncode([
          baseUrl,
          session.deliverymanId,
          session.branchId,
          session.deviceInstallationId
        ]),
        workSessionId: session.id,
        startedAt: session.startedAt,
        autoCloseAt: session.autoCloseAt);

Future<bool> _isCurrent(TrackingContext context) async {
  final current = await _outbox.current();
  return current != null &&
      current.matches(context) &&
      current.activeAt(DateTime.now());
}

Future<void> _recordBatteryLowTransition(int? batteryLevel) async {
  if (batteryLevel == null) return;
  final isLow = batteryLevel <= _batteryLowThresholdPercent;
  final wasLow = await FlutterForegroundTask.getData<bool>(
    key: _kBatteryLowReported,
  );
  await FlutterForegroundTask.saveData(
    key: _kBatteryLowReported,
    value: isLow,
  );
  if (isLow && wasLow != true) {
    await _recordDeviceEvent(
      'battery_low',
      batteryLevel: batteryLevel,
      details: 'threshold=$_batteryLowThresholdPercent',
    );
  }
}

Future<TrackingHttpClient> _trackingClient(
    String baseUrl, TrackingContext context, int pointWorkSession) async {
  if (_cachedTrackingClient?.sessionId == context.authSessionId &&
      _cachedTrackingClient?.workSessionId == pointWorkSession &&
      _cachedTrackingBaseUrl == baseUrl &&
      _cachedTrackingContext?.matches(context) == true)
    return _cachedTrackingClient!;
  _cachedTrackingClient?.dio.close();
  _cachedTrackingClient?.auth.dio.close();
  _cachedTrackingBaseUrl = baseUrl;
  _cachedTrackingContext = context;
  return _cachedTrackingClient = TrackingHttpClient(
      baseUrl: baseUrl,
      sessionId: context.authSessionId,
      workSessionId: pointWorkSession,
      versionHeaders: _trackingVersionHeaders,
      isCurrent: () => _isCurrent(context));
}

Future<void> _stopForContext(TrackingContext context) async {
  final current = await _outbox.current();
  if (current == null || !current.matches(context)) return;
  await LocationTrackingService._stopTracking(
      recordEvent: false, discardPending: false, expectedContext: context);
  FlutterForegroundTask.sendDataToMain({
    'type': 'tracking_session_ended',
    'sessionId': context.authSessionId,
  });
}

Future<Map<String, String>> _trackingVersionHeaders() async => {
      deliveryAppVersionHeader:
          await FlutterForegroundTask.getData<String>(key: _kVersionName) ?? '',
      deliveryAppBuildHeader:
          await FlutterForegroundTask.getData<String>(key: _kBuildNumber) ?? '',
      deliveryAppPackageHeader:
          await FlutterForegroundTask.getData<String>(key: _kPackageName) ?? '',
    };

DeliveryAppVersionPolicy? _updateRequiredPolicy(DioException error) =>
    error.error is DeliveryAppUpdateRequiredException
        ? (error.error as DeliveryAppUpdateRequiredException).policy
        : deliveryAppUpdatePolicyFromResponse(
            error.response?.statusCode, error.response?.data);

void _notifyMainOfRequiredUpdate(DeliveryAppVersionPolicy policy) {
  FlutterForegroundTask.sendDataToMain({
    'type': deliveryAppUpdateRequiredCode,
    'requiredVersion': policy.requiredVersion,
    'minimumBuild': policy.minimumBuild,
    'playStoreUrl': policy.playStoreUrl,
    'updateRequired': true,
  });
}

@pragma('vm:entry-point')
void locationTaskCallback() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

class LocationTaskHandler extends TaskHandler {
  late final TrackingScheduler _scheduler = TrackingScheduler(
      capture: _capture,
      synchronize: _synchronize,
      onError: (error) =>
          debugPrint('Tracking tick failed: ${error.runtimeType}'));
  Timer? _syncTimer;
  bool _destroyed = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _syncTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_scheduler.syncNow());
    });
    _scheduler.tick();
  }

  @override
  void onRepeatEvent(DateTime timestamp) => _scheduler.tick();

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _destroyed = true;
    _syncTimer?.cancel();
    _scheduler.close();
    _cachedTrackingClient?.dio.close(force: true);
    _cachedTrackingClient?.auth.dio.close(force: true);
    _cachedTrackingClient = null;
  }

  Future<TrackingContext?> _active() async {
    if (_destroyed) return null;
    final context = await _ensureTrackingContext();
    if (context == null) return null;
    if (!context.activeAt(DateTime.now())) {
      await LocationTrackingService._stopTracking(expectedContext: context);
      return null;
    }
    return context;
  }

  Future<void> _capture() async {
    final context = await _active();
    if (context == null) return;
    try {
      final permissions = await readLocationPermissionState();
      // Android's native state observer emits the versioned evidence. A GPS
      // timeout/read failure must never masquerade as revoked permission.
      if (!permissions.readFailed) {
        await FlutterForegroundTask.saveData(
            key: _kGpsEnabled, value: permissions.serviceEnabled);
        await FlutterForegroundTask.saveData(
            key: _kLocationPermissionGranted,
            value: permissions.permissionUsable);
      }
      if (!permissions.canTrackInBackground) {
        await _outbox.note(context,
            setCaptureIssue: true, captureIssue: permissions.issueMessage);
        return;
      }
      final mode =
          await FlutterForegroundTask.getData<String>(key: _kTrackingMode) ??
              _modeLight;
      final routeId =
          await FlutterForegroundTask.getData<int>(key: _kDeliveryRouteId);
      final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 10)));
      if (_destroyed || !await _isCurrent(context)) return;
      if (position.timestamp.isBefore(context.startedAt) ||
          !position.timestamp.isBefore(context.autoCloseAt)) {
        throw const FormatException('GPS fix outside work-session window');
      }
      int? battery;
      try {
        battery =
            await Battery().batteryLevel.timeout(const Duration(seconds: 2));
      } catch (_) {}
      if (_destroyed || !await _isCurrent(context)) return;
      final payload = <String, dynamic>{
        '_authSessionId': context.authSessionId,
        'clientPointId': _uuid.v4(),
        'workSessionId': context.workSessionId,
        'deliveryRouteId': routeId,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracyMeters': validAccuracyMeters(position.accuracy),
        'headingDegrees': validHeadingDegrees(position.heading),
        'batteryLevelPercent': battery,
        'internetAvailable': null, // Server reachability is not Internet state.
        'gpsEnabled': true,
        'trackingMode': mode,
        'recordedAt': position.timestamp.toUtc().toIso8601String(),
      };
      // Persist first. No HTTP or backlog processing blocks this capture path.
      await _outbox.enqueue(context, 'location', payload);
      await _recordBatteryLowTransition(battery);
      unawaited(_scheduler.syncNow());
    } catch (error) {
      await _outbox.note(context,
          setCaptureIssue: true,
          captureIssue: error is TimeoutException || error is FormatException
              ? 'GPS sin una posición reciente. Reintentando.'
              : 'No se pudo guardar u obtener la ubicación. Revisa el seguimiento.');
    }
  }

  Future<void> _synchronize() async {
    final context = await _active();
    if (context == null) return;
    await _outbox.note(context, heartbeat: true);
    try {
      await _migrateLegacyQueues(context);
    } catch (error) {
      // A damaged or oversized old queue must not prevent fresh captured
      // positions from being uploaded while the history is investigated.
      debugPrint('Tracking legacy import deferred: ${error.runtimeType}');
    }
    final baseUrl = await FlutterForegroundTask.getData<String>(key: _kBaseUrl);
    if (baseUrl == null || !await _isCurrent(context)) return;
    final locations = await _outbox.pending(context);
    // Small event passes cannot monopolize GPS upload; both share HTTP cooldown.
    final records = [...locations, ...await _outbox.events(context, limit: 3)];
    final watch = Stopwatch()..start();
    for (final record in records) {
      if (_destroyed ||
          !await _isCurrent(context) ||
          watch.elapsed > const Duration(seconds: 20)) break;
      final payload = {
        ...record.payload,
        '_authSessionId': context.authSessionId
      };
      try {
        final client =
            await _trackingClient(baseUrl, context, record.workSessionId);
        final response = await client.post<dynamic>(
            record.kind == 'location'
                ? '/deliverymen/location'
                : '/deliverymen/device-event',
            data: payload);
        // Even after logout, acknowledge only this original owned row. Never
        // replace a queue snapshot or attach an old reply to the new workday.
        final acceptedAt = DateTime.now().toUtc();
        await _outbox.acknowledge(record, acceptedAt);
        await _outbox.recoverCommunication(context, acceptedAt);
        if (_destroyed || !await _isCurrent(context)) break;
        await _outbox.note(context, setUploadIssue: true);
        if (record.kind == 'location' &&
            record.workSessionId == context.workSessionId) {
          final snapshot = await _outbox.snapshot(context);
          final recordedAt =
              DateTime.parse(record.payload['recordedAt'] as String);
          if (snapshot.capturedAt == null ||
              !recordedAt.isBefore(snapshot.capturedAt!)) {
            await _applyTrackingResult(response.data, context);
          }
        }
      } on DioException catch (error) {
        final update = _updateRequiredPolicy(error);
        if (update != null) {
          _notifyMainOfRequiredUpdate(update);
          await LocationTrackingService._stopTracking(
              recordEvent: false, expectedContext: context);
          break;
        }
        if (isTrackingSessionEnded(error)) {
          await _outbox.note(context,
              setUploadIssue: true, uploadIssue: 'Autenticación requerida');
          await _stopForContext(context);
          break;
        }
        final status = error.response?.statusCode;
        if (status == 400 || status == 422) {
          await _outbox.reject(record, 'http_$status');
          await _outbox.recoverCommunication(context, DateTime.now().toUtc());
          continue;
        }
        final issue = status == 401 || error.error is SessionRefreshUnavailable
            ? 'Renovación de sesión pendiente. Reintentando.'
            : status == 429
                ? 'Servidor ocupado. Envíos pausados temporalmente.'
                : isLocationTransportFailure(error)
                    ? 'Sin comunicación con el servidor. Ubicaciones guardadas.'
                    : error.error is TrackingDeferred
                        ? null
                        : 'No se pudo sincronizar. Ubicaciones guardadas.';
        if (issue != null)
          await _outbox.note(context, setUploadIssue: true, uploadIssue: issue);
        if (isLocationTransportFailure(error)) {
          await _outbox.beginCommunicationGap(context, DateTime.now().toUtc());
        }
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _applyTrackingResult(
      dynamic data, TrackingContext context) async {
    if (data is! Map || !await _isCurrent(context)) return;
    final routeId = int.tryParse(data['deliveryRouteId']?.toString() ?? '');
    final savedRouteId =
        await FlutterForegroundTask.getData<int>(key: _kDeliveryRouteId);
    final savedMode =
        await FlutterForegroundTask.getData<String>(key: _kTrackingMode);
    if (data['continueActiveTracking'] == true && routeId != null) {
      if (savedMode != _modeActiveDelivery || savedRouteId != routeId) {
        await LocationTrackingService.setActiveDeliveryMode(routeId: routeId);
      }
    } else if (savedMode != _modeLight || savedRouteId != null) {
      await LocationTrackingService.setLightMode();
    }

    if (data['returnReview'] is Map &&
        !await _outbox.hasPendingLocationHistory(context)) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'route_return_review',
        'sessionId': context.authSessionId,
        'review': data['returnReview'],
      });
    }
  }
}

class LocationTrackingService {
  static bool _initialized = false;
  static Future<void> _commandTail = Future<void>.value();

  static ForegroundTaskOptions _foregroundTaskOptions(int intervalMs) =>
      ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(intervalMs),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowAutoRestart: true,
        stopWithTask: false,
      );

  static Future<T> _enqueue<T>(Future<T> Function() operation) async {
    final previous = _commandTail;
    final gate = Completer<void>();
    _commandTail = gate.future;
    try {
      await previous;
      return await operation();
    } finally {
      gate.complete();
    }
  }

  static void initialize() {
    if (kIsWeb) return;
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'location_tracking',
        channelName: 'Seguimiento de jornada',
        channelDescription:
            'Señor Arroz — compartiendo ubicación durante la jornada laboral',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(300000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
  }

  /// A force-stop cannot execute Dart code at the moment it happens. The next
  /// launch records it while the previous work session is still expected to be
  /// tracking and has not reached its automatic closing time.
  static Future<void> detectUnexpectedStop() async {
    if (kIsWeb) return;
    if (!_initialized) initialize();
    final expectedActive = await FlutterForegroundTask.getData<bool>(
          key: _kTrackingExpectedActive,
        ) ??
        false;
    if (!expectedActive || await FlutterForegroundTask.isRunningService) return;

    final workSessionId =
        await FlutterForegroundTask.getData<int>(key: _kWorkSessionId);
    final autoCloseAtValue =
        await FlutterForegroundTask.getData<String>(key: _kAutoCloseAt);
    final autoCloseAt = DateTime.tryParse(autoCloseAtValue ?? '')?.toUtc();
    if (workSessionId == null ||
        autoCloseAt == null ||
        !DateTime.now().toUtc().isBefore(autoCloseAt)) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (prefs.getInt('sa_native_exit_reported_session') == workSessionId ||
        prefs.getInt(_kUnexpectedStopReportedSession) == workSessionId) return;
    await prefs.setInt(_kUnexpectedStopReportedSession, workSessionId);
    await _recordDeviceEvent(
      'app_stopped',
      details:
          'evidence_version=2;source=next_launch;cause=unknown;detected_on_next_launch=true',
    );
  }

  static Future<void> startTracking({
    required String authToken,
    required String baseUrl,
    required DeliveryWorkSession workSession,
    required String versionName,
    required String buildNumber,
    required String packageName,
  }) =>
      _enqueue(() => _startTracking(
          authToken: authToken,
          baseUrl: baseUrl,
          workSession: workSession,
          versionName: versionName,
          buildNumber: buildNumber,
          packageName: packageName));

  static Future<void> _startTracking({
    required String authToken,
    required String baseUrl,
    required DeliveryWorkSession workSession,
    required String versionName,
    required String buildNumber,
    required String packageName,
  }) async {
    if (kIsWeb)
      throw UnsupportedError(
          'El seguimiento en segundo plano requiere Android.');
    final workSessionId = workSession.id;
    final autoCloseAtUtc = workSession.autoCloseAt;
    final lightIntervalSeconds = workSession.tracking.lightIntervalSeconds;
    final activeIntervalSeconds = workSession.tracking.activeIntervalSeconds;
    if (!_initialized) initialize();

    final wasExpectedActive = await FlutterForegroundTask.getData<bool>(
          key: _kTrackingExpectedActive,
        ) ??
        false;
    final wasRunning = await FlutterForegroundTask.isRunningService;
    final previousSessionId =
        await FlutterForegroundTask.getData<int>(key: _kWorkSessionId);
    final previousMode =
        await FlutterForegroundTask.getData<String>(key: _kTrackingMode);
    final previousRouteId =
        await FlutterForegroundTask.getData<int>(key: _kDeliveryRouteId);
    final resumeActive = shouldResumeActiveTracking(
      previousWorkSessionId: previousSessionId,
      workSessionId: workSessionId,
      previousMode: previousMode,
      deliveryRouteId: previousRouteId,
    );
    if (previousSessionId != null && previousSessionId != workSessionId) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kUnexpectedStopReportedSession);
      await FlutterForegroundTask.removeData(key: _kGpsEnabled);
      await FlutterForegroundTask.removeData(
        key: _kLocationPermissionGranted,
      );
      await FlutterForegroundTask.removeData(key: _kInternetAvailable);
      await FlutterForegroundTask.removeData(key: _kBatteryLowReported);
    }

    final authSession = await SecureStorage().readSession();
    if (authSession == null) throw const SessionEndedException();
    await FlutterForegroundTask.saveData(
        key: _kAuthSessionId, value: authSession.id);
    await FlutterForegroundTask.saveData(
        key: _kAuthToken, value: authSession.accessToken);
    await FlutterForegroundTask.saveData(key: _kBaseUrl, value: baseUrl);
    await FlutterForegroundTask.saveData(
      key: _kVersionName,
      value: versionName,
    );
    await FlutterForegroundTask.saveData(
      key: _kBuildNumber,
      value: buildNumber,
    );
    await FlutterForegroundTask.saveData(
      key: _kPackageName,
      value: packageName,
    );
    await FlutterForegroundTask.saveData(
        key: _kWorkSessionId, value: workSessionId);
    await FlutterForegroundTask.saveData(
      key: _kAutoCloseAt,
      value: autoCloseAtUtc.toUtc().toIso8601String(),
    );
    await FlutterForegroundTask.saveData(
      key: _kLightIntervalSeconds,
      value: lightIntervalSeconds,
    );
    await FlutterForegroundTask.saveData(
      key: _kActiveIntervalSeconds,
      value: activeIntervalSeconds,
    );
    await FlutterForegroundTask.saveData(
        key: _kTrackingMode,
        value: resumeActive ? _modeActiveDelivery : _modeLight);
    if (!resumeActive)
      await FlutterForegroundTask.removeData(key: _kDeliveryRouteId);
    final context = _contextFor(workSession, authSession.id, baseUrl);
    if (!workSession.isActive || !context.activeAt(DateTime.now())) {
      throw const TrackingServiceException('La jornada ya no está activa.');
    }
    await _traceTrackingPhase(
        'activate_outbox', () => _outbox.activate(context));
    // Legacy data belongs to the background synchronizer. Never process it
    // here: this function is called while authentication is finishing.
    final nativePrefs = await SharedPreferences.getInstance();
    await nativePrefs.setString(
        'sa_native_tracking_context', jsonEncode(context.toJson()));
    await nativePrefs.setBool(_kNativeTrackingActive, true);

    if (wasRunning) {
      await FlutterForegroundTask.saveData(
        key: _kTrackingExpectedActive,
        value: true,
      );
      if (!wasExpectedActive || previousSessionId != workSessionId) {
        await _recordDeviceEvent('tracking_started');
      }
      if (resumeActive) {
        await _setActiveDeliveryMode(routeId: previousRouteId);
      } else {
        await _setLightMode();
      }
      return;
    }

    await FlutterForegroundTask.saveData(
      key: _kTrackingMode,
      value: resumeActive ? _modeActiveDelivery : _modeLight,
    );
    if (!resumeActive) {
      await FlutterForegroundTask.removeData(key: _kDeliveryRouteId);
    }
    final result = await _traceTrackingPhase(
      'start_android_service',
      () => FlutterForegroundTask.startService(
        serviceTypes: [ForegroundServiceTypes.location],
        notificationTitle: 'Señor Arroz',
        notificationText: 'Jornada activa — seguimiento liviano',
        callback: locationTaskCallback,
      ),
    );
    if (result is ServiceRequestFailure) {
      throw TrackingServiceException(
        'No pudimos iniciar el seguimiento de ubicación. Revisa el GPS y los permisos.',
      );
    }
    await FlutterForegroundTask.saveData(
      key: _kTrackingExpectedActive,
      value: true,
    );
    final restarted = wasExpectedActive && previousSessionId == workSessionId;
    await _recordDeviceEvent(
      restarted ? 'location_service_restarted' : 'tracking_started',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUnexpectedStopReportedSession);
    await _traceTrackingPhase('update_tracking_mode', () async {
      if (resumeActive) {
        await _setActiveDeliveryMode(routeId: previousRouteId);
      } else {
        await _setLightMode();
      }
    });
  }

  static Future<void> setLightMode() => _enqueue(_setLightMode);

  static Future<void> _setLightMode() async {
    if (kIsWeb) return;
    await FlutterForegroundTask.removeData(key: _kDeliveryRouteId);
    final interval = await FlutterForegroundTask.getData<int>(
          key: _kLightIntervalSeconds,
        ) ??
        300;
    await _setMode(
        _modeLight, interval, 'Jornada activa — seguimiento liviano');
  }

  static Future<void> setActiveDeliveryMode({int? routeId}) =>
      _enqueue(() => _setActiveDeliveryMode(routeId: routeId));

  static Future<void> _setActiveDeliveryMode({int? routeId}) async {
    if (kIsWeb) return;
    if (routeId == null) {
      await FlutterForegroundTask.removeData(key: _kDeliveryRouteId);
    } else {
      await FlutterForegroundTask.saveData(
        key: _kDeliveryRouteId,
        value: routeId,
      );
    }
    final interval = await FlutterForegroundTask.getData<int>(
          key: _kActiveIntervalSeconds,
        ) ??
        30;
    await _setMode(
      _modeActiveDelivery,
      interval,
      'Pedido en camino — seguimiento activo',
    );
  }

  static Future<void> _setMode(
    String mode,
    int intervalSeconds,
    String notificationText,
  ) async {
    if (!await FlutterForegroundTask.isRunningService) {
      throw const TrackingServiceException(
        'El servicio de ubicación no está ejecutándose.',
      );
    }
    await FlutterForegroundTask.saveData(key: _kTrackingMode, value: mode);
    final safeInterval = intervalSeconds.clamp(1, 86400).toInt();
    final context = await _outbox.current();
    if (context != null)
      await _outbox.note(context, intervalSeconds: safeInterval);
    final result = await FlutterForegroundTask.updateService(
      foregroundTaskOptions: _foregroundTaskOptions(safeInterval * 1000),
      notificationText: notificationText,
    );
    if (result is ServiceRequestFailure) {
      throw TrackingServiceException(
        'No pudimos actualizar el seguimiento de ubicación.',
      );
    }
  }

  static Future<void> stopTracking({
    bool recordEvent = true,
    bool discardPending = false,
  }) =>
      _enqueue(
        () => _stopTracking(
          recordEvent: recordEvent,
          discardPending: discardPending,
        ),
      );

  static Future<void> _stopTracking({
    bool recordEvent = true,
    bool discardPending = false,
    TrackingContext? expectedContext,
  }) async {
    if (kIsWeb) return;
    final current = await _outbox.current();
    if (expectedContext != null &&
        (current == null || !current.matches(expectedContext))) return;
    final expectedActive = await FlutterForegroundTask.getData<bool>(
          key: _kTrackingExpectedActive,
        ) ??
        false;
    if (expectedActive && recordEvent) {
      await _recordDeviceEvent('tracking_stopped');
    }
    await FlutterForegroundTask.saveData(
      key: _kTrackingExpectedActive,
      value: false,
    );
    if (current != null && !await _outbox.deactivate(current)) return;
    final nativePrefs = await SharedPreferences.getInstance();
    await nativePrefs.setBool(_kNativeTrackingActive, false);
    await nativePrefs.remove('sa_native_tracking_context');

    if (await FlutterForegroundTask.isRunningService) {
      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestFailure) {
        throw TrackingServiceException(
          'No pudimos detener el seguimiento de ubicación.',
        );
      }
    }

    await FlutterForegroundTask.removeData(key: _kAuthSessionId);
    await FlutterForegroundTask.removeData(key: _kAuthToken);
    await FlutterForegroundTask.removeData(key: _kBaseUrl);
    await FlutterForegroundTask.removeData(key: _kVersionName);
    await FlutterForegroundTask.removeData(key: _kBuildNumber);
    await FlutterForegroundTask.removeData(key: _kPackageName);
    await FlutterForegroundTask.removeData(key: _kWorkSessionId);
    await FlutterForegroundTask.removeData(key: _kAutoCloseAt);
    await FlutterForegroundTask.removeData(key: _kLightIntervalSeconds);
    await FlutterForegroundTask.removeData(key: _kActiveIntervalSeconds);
    await FlutterForegroundTask.removeData(key: _kTrackingMode);
    await FlutterForegroundTask.removeData(key: _kDeliveryRouteId);
    await FlutterForegroundTask.removeData(key: _kGpsEnabled);
    await FlutterForegroundTask.removeData(
      key: _kLocationPermissionGranted,
    );
    await FlutterForegroundTask.removeData(key: _kInternetAvailable);
    await FlutterForegroundTask.removeData(key: _kBatteryLowReported);
    final prefs = await SharedPreferences.getInstance();
    // A normal stop/update/logout never deletes unacknowledged coordinates.
    // The legacy argument is retained for existing call sites only.
    await prefs.remove(_kUnexpectedStopReportedSession);
  }

  static Future<void> updateToken(String newToken) async {
    if (kIsWeb) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.saveData(key: _kAuthToken, value: newToken);
  }

  static Future<void> updateAutoCloseAt(DateTime autoCloseAtUtc) async {
    if (kIsWeb) return;
    final cutoff = autoCloseAtUtc.toUtc();
    final context = await _outbox.current();
    if (context != null) {
      if (!await _outbox.updateCutoff(context, cutoff)) return;
      final updated = await _outbox.current();
      final prefs = await SharedPreferences.getInstance();
      if (updated != null)
        await prefs.setString(
            'sa_native_tracking_context', jsonEncode(updated.toJson()));
    }
    await FlutterForegroundTask.saveData(
      key: _kAutoCloseAt,
      value: cutoff.toIso8601String(),
    );
    if (!DateTime.now().toUtc().isBefore(cutoff)) {
      await stopTracking();
    }
  }

  static Future<bool> get isRunning => kIsWeb
      ? Future<bool>.value(false)
      : FlutterForegroundTask.isRunningService;
}
