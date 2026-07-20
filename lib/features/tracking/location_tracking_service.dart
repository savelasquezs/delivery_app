import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const _kAuthToken = 'sa_loc_auth_token';
const _kBaseUrl = 'sa_loc_base_url';
const _kOfflineQueue = 'sa_loc_offline_queue';
const _kDeviceEventQueue = 'sa_device_event_queue';
const _kWorkSessionId = 'sa_loc_work_session_id';
const _kAutoCloseAt = 'sa_loc_auto_close_at';
const _kLightIntervalSeconds = 'sa_loc_light_interval_seconds';
const _kActiveIntervalSeconds = 'sa_loc_active_interval_seconds';
const _kTrackingMode = 'sa_loc_tracking_mode';
const _kDeliveryRouteId = 'sa_loc_delivery_route_id';
const _kGpsEnabled = 'sa_loc_gps_enabled';
const _kLocationPermissionGranted = 'sa_loc_permission_granted';
const _kInternetAvailable = 'sa_loc_internet_available';
const _kTrackingExpectedActive = 'sa_loc_expected_active';
const _kUnexpectedStopReportedSession = 'sa_loc_stop_reported_session';
const _modeLight = 'LIGHT';
const _modeActiveDelivery = 'ACTIVE_DELIVERY';
const _modeOffline = 'OFFLINE';
const _maxOfflinePoints = 100;
const _uuid = Uuid();

Future<void> _recordDeviceEvent(
  String eventType, {
  int? batteryLevel,
  bool? internetAvailable,
  bool? gpsEnabled,
  bool? locationPermissionGranted,
  String? details,
}) async {
  final token = await FlutterForegroundTask.getData<String>(key: _kAuthToken);
  final baseUrl = await FlutterForegroundTask.getData<String>(key: _kBaseUrl);
  final workSessionId =
      await FlutterForegroundTask.getData<int>(key: _kWorkSessionId);
  if (workSessionId == null) return;

  final payload = <String, dynamic>{
    'clientEventId': _uuid.v4(),
    'workSessionId': workSessionId,
    'eventType': eventType,
    'batteryLevelPercent': batteryLevel,
    'internetAvailable': internetAvailable,
    'gpsEnabled': gpsEnabled,
    'locationPermissionGranted': locationPermissionGranted,
    'details': details,
    'recordedAt': DateTime.now().toUtc().toIso8601String(),
  };
  if (token == null || baseUrl == null) {
    await _enqueueDeviceEvent(payload);
    return;
  }

  try {
    await _trackingDio(baseUrl, token)
        .post('/deliverymen/device-event', data: payload);
  } on DioException catch (error) {
    if (!_isPermanentClientErrorStatus(error.response?.statusCode)) {
      await _enqueueDeviceEvent(payload);
    }
  } catch (_) {
    await _enqueueDeviceEvent(payload);
  }
}

Future<void> _enqueueDeviceEvent(Map<String, dynamic> payload) async {
  final prefs = await SharedPreferences.getInstance();
  final encoded = prefs.getString(_kDeviceEventQueue);
  final queue =
      encoded == null ? <dynamic>[] : jsonDecode(encoded) as List<dynamic>;
  if (queue.length >= 100) return;
  queue.add(payload);
  await prefs.setString(_kDeviceEventQueue, jsonEncode(queue));
}

Future<void> _flushDeviceEvents(String token, String baseUrl) async {
  final prefs = await SharedPreferences.getInstance();
  final encoded = prefs.getString(_kDeviceEventQueue);
  if (encoded == null) return;
  final queue = jsonDecode(encoded) as List<dynamic>;
  final remaining = <Map<String, dynamic>>[];
  final dio = _trackingDio(baseUrl, token);
  for (final item in queue) {
    final payload = Map<String, dynamic>.from(item as Map);
    try {
      await dio.post('/deliverymen/device-event', data: payload);
    } on DioException catch (error) {
      if (!_isPermanentClientErrorStatus(error.response?.statusCode)) {
        remaining.add(payload);
      }
    } catch (_) {
      remaining.add(payload);
    }
  }
  if (remaining.isEmpty) {
    await prefs.remove(_kDeviceEventQueue);
  } else {
    await prefs.setString(_kDeviceEventQueue, jsonEncode(remaining));
  }
}

Future<void> _recordBooleanTransition({
  required String storageKey,
  required bool current,
  required String negativeEvent,
  required String positiveEvent,
  bool internetState = false,
  bool gpsState = false,
  bool permissionState = false,
}) async {
  final previous = await FlutterForegroundTask.getData<bool>(key: storageKey);
  await FlutterForegroundTask.saveData(key: storageKey, value: current);
  if (previous == current || (previous == null && current)) return;
  await _recordDeviceEvent(
    current ? positiveEvent : negativeEvent,
    internetAvailable: internetState ? current : null,
    gpsEnabled: gpsState ? current : null,
    locationPermissionGranted: permissionState ? current : null,
  );
}

bool _isPermanentClientErrorStatus(int? status) {
  if (status == null || status < 400 || status >= 500) return false;
  return status != 401 && status != 408 && status != 429;
}

Dio _trackingDio(String baseUrl, String token) => Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ),
    );

@pragma('vm:entry-point')
void locationTaskCallback() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

class LocationTaskHandler extends TaskHandler {
  bool _sending = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('LocationTaskHandler: started');
    await _sendCurrentLocation();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_sending) return;
    unawaited(_sendCurrentLocation());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('LocationTaskHandler: destroyed (timeout=$isTimeout)');
  }

  Future<void> _sendCurrentLocation() async {
    _sending = true;
    try {
      final token =
          await FlutterForegroundTask.getData<String>(key: _kAuthToken);
      final baseUrl =
          await FlutterForegroundTask.getData<String>(key: _kBaseUrl);
      final autoCloseAtValue =
          await FlutterForegroundTask.getData<String>(key: _kAutoCloseAt);
      if (token == null || baseUrl == null || autoCloseAtValue == null) return;

      final autoCloseAt = DateTime.tryParse(autoCloseAtValue)?.toUtc();
      if (autoCloseAt == null ||
          !DateTime.now().toUtc().isBefore(autoCloseAt)) {
        final expectedActive = await FlutterForegroundTask.getData<bool>(
              key: _kTrackingExpectedActive,
            ) ??
            false;
        if (expectedActive) {
          await _recordDeviceEvent(
            'tracking_stopped',
            details: 'automatic_cutoff',
          );
        }
        await FlutterForegroundTask.saveData(
          key: _kTrackingExpectedActive,
          value: false,
        );
        await FlutterForegroundTask.stopService();
        return;
      }

      final gpsEnabled = await Geolocator.isLocationServiceEnabled();
      await _recordBooleanTransition(
        storageKey: _kGpsEnabled,
        current: gpsEnabled,
        negativeEvent: 'gps_disabled',
        positiveEvent: 'gps_enabled',
        gpsState: true,
      );
      if (!gpsEnabled) return;

      final permission = await Geolocator.checkPermission();
      final permissionGranted = permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
      await _recordBooleanTransition(
        storageKey: _kLocationPermissionGranted,
        current: permissionGranted,
        negativeEvent: 'location_permission_revoked',
        positiveEvent: 'location_permission_recovered',
        permissionState: true,
      );
      if (!permissionGranted) return;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      final trackingMode =
          await FlutterForegroundTask.getData<String>(key: _kTrackingMode) ??
              _modeLight;
      final batteryLevel = await _readBatteryLevel();
      final payload = <String, dynamic>{
        'clientPointId': _uuid.v4(),
        'workSessionId':
            await FlutterForegroundTask.getData<int>(key: _kWorkSessionId),
        'deliveryRouteId':
            await FlutterForegroundTask.getData<int>(key: _kDeliveryRouteId),
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracyMeters': position.accuracy.isFinite ? position.accuracy : null,
        'headingDegrees': position.heading.isFinite ? position.heading : null,
        'batteryLevelPercent': batteryLevel,
        'internetAvailable': true,
        'gpsEnabled': true,
        'trackingMode': trackingMode,
        'recordedAt': position.timestamp.toUtc().toIso8601String(),
      };

      await _flushDeviceEvents(token, baseUrl);
      await _flushOfflineQueue(token, baseUrl);
      await _postLocation(token, baseUrl, payload);
    } catch (e) {
      debugPrint('LocationTaskHandler: error sending location: $e');
    } finally {
      _sending = false;
    }
  }

  Future<void> _postLocation(
    String token,
    String baseUrl,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _buildDio(baseUrl, token)
          .post('/deliverymen/location', data: payload);
      await _recordBooleanTransition(
        storageKey: _kInternetAvailable,
        current: true,
        negativeEvent: 'internet_lost',
        positiveEvent: 'internet_recovered',
        internetState: true,
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (_isPermanentClientError(status)) {
        await FlutterForegroundTask.saveData(
          key: _kTrackingExpectedActive,
          value: false,
        );
        await FlutterForegroundTask.stopService();
        return;
      }
      if (error.response == null) {
        await _recordBooleanTransition(
          storageKey: _kInternetAvailable,
          current: false,
          negativeEvent: 'internet_lost',
          positiveEvent: 'internet_recovered',
          internetState: true,
        );
      }
      await _enqueueOffline(
        error.response == null ? _asOfflinePayload(payload) : payload,
      );
    } catch (_) {
      await _recordBooleanTransition(
        storageKey: _kInternetAvailable,
        current: false,
        negativeEvent: 'internet_lost',
        positiveEvent: 'internet_recovered',
        internetState: true,
      );
      await _enqueueOffline(_asOfflinePayload(payload));
    }
  }

  Future<void> _flushOfflineQueue(String token, String baseUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = prefs.getString(_kOfflineQueue);
    if (queueJson == null) return;

    final queue = jsonDecode(queueJson) as List<dynamic>;
    if (queue.isEmpty) return;

    final dio = _buildDio(baseUrl, token);
    final remaining = <Map<String, dynamic>>[];
    for (final item in queue) {
      final payload = Map<String, dynamic>.from(item as Map);
      try {
        await dio.post('/deliverymen/location', data: payload);
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (!_isPermanentClientError(status)) {
          remaining.add(payload);
        }
      } catch (_) {
        remaining.add(payload);
      }
    }

    if (remaining.isEmpty) {
      await prefs.remove(_kOfflineQueue);
    } else {
      await prefs.setString(_kOfflineQueue, jsonEncode(remaining));
    }
  }

  bool _isPermanentClientError(int? status) {
    if (status == null || status < 400 || status >= 500) return false;
    return status != 401 && status != 408 && status != 429;
  }

  Future<void> _enqueueOffline(Map<String, dynamic> payload) async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = prefs.getString(_kOfflineQueue);
    final queue = queueJson != null
        ? jsonDecode(queueJson) as List<dynamic>
        : <dynamic>[];
    if (queue.length < _maxOfflinePoints) {
      queue.add(payload);
      await prefs.setString(_kOfflineQueue, jsonEncode(queue));
    }
  }

  Map<String, dynamic> _asOfflinePayload(Map<String, dynamic> payload) => {
        ...payload,
        'internetAvailable': false,
        'trackingMode': _modeOffline,
      };

  Future<int?> _readBatteryLevel() async {
    try {
      return await Battery().batteryLevel;
    } catch (_) {
      return null;
    }
  }

  Dio _buildDio(String baseUrl, String token) => Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ),
      );
}

class LocationTrackingService {
  static bool _initialized = false;

  static void initialize() {
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
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowAutoRestart: true,
      ),
    );
  }

  /// A force-stop cannot execute Dart code at the moment it happens. The next
  /// launch records it while the previous work session is still expected to be
  /// tracking and has not reached its automatic closing time.
  static Future<void> detectUnexpectedStop() async {
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
    if (prefs.getInt(_kUnexpectedStopReportedSession) == workSessionId) return;
    await prefs.setInt(_kUnexpectedStopReportedSession, workSessionId);
    await _recordDeviceEvent(
      'app_stopped',
      details: 'detected_on_next_launch',
    );
  }

  static Future<void> startTracking({
    required String authToken,
    required String baseUrl,
    required int workSessionId,
    required DateTime autoCloseAtUtc,
    required int lightIntervalSeconds,
    required int activeIntervalSeconds,
  }) async {
    if (!_initialized) initialize();

    final wasExpectedActive = await FlutterForegroundTask.getData<bool>(
          key: _kTrackingExpectedActive,
        ) ??
        false;
    final wasRunning = await FlutterForegroundTask.isRunningService;
    final previousSessionId =
        await FlutterForegroundTask.getData<int>(key: _kWorkSessionId);
    if (previousSessionId != null && previousSessionId != workSessionId) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kOfflineQueue);
      await prefs.remove(_kUnexpectedStopReportedSession);
      await FlutterForegroundTask.removeData(key: _kGpsEnabled);
      await FlutterForegroundTask.removeData(
        key: _kLocationPermissionGranted,
      );
      await FlutterForegroundTask.removeData(key: _kInternetAvailable);
    }

    await FlutterForegroundTask.saveData(key: _kAuthToken, value: authToken);
    await FlutterForegroundTask.saveData(key: _kBaseUrl, value: baseUrl);
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
    await _flushDeviceEvents(authToken, baseUrl);

    if (wasRunning) {
      await FlutterForegroundTask.saveData(
        key: _kTrackingExpectedActive,
        value: true,
      );
      if (!wasExpectedActive || previousSessionId != workSessionId) {
        await _recordDeviceEvent('tracking_started');
      }
      await setLightMode();
      return;
    }

    await FlutterForegroundTask.saveData(
        key: _kTrackingMode, value: _modeLight);
    final result = await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.location],
      notificationTitle: 'Señor Arroz',
      notificationText: 'Jornada activa — seguimiento liviano',
      callback: locationTaskCallback,
    );
    if (result is ServiceRequestFailure) {
      debugPrint('LocationTrackingService: failed to start — ${result.error}');
      return;
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
    await setLightMode();
  }

  static Future<void> setLightMode() async {
    await FlutterForegroundTask.removeData(key: _kDeliveryRouteId);
    final interval = await FlutterForegroundTask.getData<int>(
          key: _kLightIntervalSeconds,
        ) ??
        300;
    await _setMode(
        _modeLight, interval, 'Jornada activa — seguimiento liviano');
  }

  static Future<void> setActiveDeliveryMode({int? routeId}) async {
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
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.saveData(key: _kTrackingMode, value: mode);
    final safeInterval = intervalSeconds.clamp(1, 86400).toInt();
    final result = await FlutterForegroundTask.updateService(
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(safeInterval * 1000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowAutoRestart: true,
      ),
      notificationText: notificationText,
    );
    if (result is ServiceRequestFailure) {
      debugPrint('LocationTrackingService: failed to update — ${result.error}');
    }
  }

  static Future<void> stopTracking() async {
    final expectedActive = await FlutterForegroundTask.getData<bool>(
          key: _kTrackingExpectedActive,
        ) ??
        false;
    if (expectedActive) {
      await _recordDeviceEvent('tracking_stopped');
    }
    await FlutterForegroundTask.saveData(
      key: _kTrackingExpectedActive,
      value: false,
    );

    if (await FlutterForegroundTask.isRunningService) {
      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestFailure) {
        debugPrint('LocationTrackingService: failed to stop — ${result.error}');
      }
    }

    await FlutterForegroundTask.removeData(key: _kAuthToken);
    await FlutterForegroundTask.removeData(key: _kBaseUrl);
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kOfflineQueue);
    await prefs.remove(_kUnexpectedStopReportedSession);
  }

  static Future<void> updateToken(String newToken) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.saveData(key: _kAuthToken, value: newToken);
  }

  static Future<void> updateAutoCloseAt(DateTime autoCloseAtUtc) async {
    final cutoff = autoCloseAtUtc.toUtc();
    await FlutterForegroundTask.saveData(
      key: _kAutoCloseAt,
      value: cutoff.toIso8601String(),
    );
    if (!DateTime.now().toUtc().isBefore(cutoff)) {
      await stopTracking();
    }
  }

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;
}
