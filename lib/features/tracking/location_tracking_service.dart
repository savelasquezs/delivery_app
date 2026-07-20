import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kAuthToken = 'sa_loc_auth_token';
const _kBaseUrl = 'sa_loc_base_url';
const _kOfflineQueue = 'sa_loc_offline_queue';
const _kWorkSessionId = 'sa_loc_work_session_id';
const _kAutoCloseAt = 'sa_loc_auto_close_at';
const _kLightIntervalSeconds = 'sa_loc_light_interval_seconds';
const _kActiveIntervalSeconds = 'sa_loc_active_interval_seconds';
const _kTrackingMode = 'sa_loc_tracking_mode';
const _modeLight = 'LIGHT';
const _modeActiveDelivery = 'ACTIVE_DELIVERY';

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
        await FlutterForegroundTask.stopService();
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      final payload = <String, dynamic>{
        'workSessionId':
            await FlutterForegroundTask.getData<int>(key: _kWorkSessionId),
        'latitude': position.latitude,
        'longitude': position.longitude,
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
      };

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
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (_isPermanentClientError(status)) {
        await FlutterForegroundTask.stopService();
        return;
      }
      await _enqueueOffline(payload);
    } catch (_) {
      await _enqueueOffline(payload);
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
    if (queue.length < 100) {
      queue.add(payload);
      await prefs.setString(_kOfflineQueue, jsonEncode(queue));
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

  static Future<void> startTracking({
    required String authToken,
    required String baseUrl,
    required int workSessionId,
    required DateTime autoCloseAtUtc,
    required int lightIntervalSeconds,
    required int activeIntervalSeconds,
  }) async {
    if (!_initialized) initialize();

    final previousSessionId =
        await FlutterForegroundTask.getData<int>(key: _kWorkSessionId);
    if (previousSessionId != null && previousSessionId != workSessionId) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kOfflineQueue);
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

    if (await FlutterForegroundTask.isRunningService) {
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
    await setLightMode();
  }

  static Future<void> setLightMode() async {
    final interval = await FlutterForegroundTask.getData<int>(
          key: _kLightIntervalSeconds,
        ) ??
        300;
    await _setMode(
        _modeLight, interval, 'Jornada activa — seguimiento liviano');
  }

  static Future<void> setActiveDeliveryMode() async {
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kOfflineQueue);
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
