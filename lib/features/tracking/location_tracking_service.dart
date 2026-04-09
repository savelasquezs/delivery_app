import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── SharedPreferences keys (outside the class to be accessible from the isolate) ───

const _kAuthToken = 'sa_loc_auth_token';
const _kBaseUrl = 'sa_loc_base_url';
const _kOfflineQueue = 'sa_loc_offline_queue';

// ─── Top-level foreground task callback (must be top-level + @pragma) ────────

/// Entry point called by the foreground service in the background isolate.
@pragma('vm:entry-point')
void locationTaskCallback() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

// ─── Task handler ─────────────────────────────────────────────────────────────

class LocationTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('LocationTaskHandler: started');
  }

  /// Called every 60 seconds to send the current GPS location to the backend.
  @override
  void onRepeatEvent(DateTime timestamp) {
    _sendCurrentLocation();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('LocationTaskHandler: destroyed (timeout=$isTimeout)');
  }

  void _sendCurrentLocation() async {
    try {
      final token = await FlutterForegroundTask.getData<String>(key: _kAuthToken);
      final baseUrl = await FlutterForegroundTask.getData<String>(key: _kBaseUrl);
      if (token == null || baseUrl == null) return;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      final payload = {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
      };

      // Attempt to flush queued offline locations before sending new one
      await _flushOfflineQueue(token, baseUrl);
      await _postLocation(token, baseUrl, payload);
    } catch (e) {
      debugPrint('LocationTaskHandler: error sending location: $e');
    }
  }

  Future<void> _postLocation(
    String token,
    String baseUrl,
    Map<String, dynamic> payload,
  ) async {
    try {
      final dio = _buildDio(baseUrl, token);
      await dio.post('/deliverymen/location', data: payload);
    } catch (_) {
      // Network failure — persist for retry
      await _enqueueOffline(payload);
    }
  }

  Future<void> _flushOfflineQueue(String token, String baseUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = prefs.getString(_kOfflineQueue);
    if (queueJson == null) return;

    final List<dynamic> queue = jsonDecode(queueJson);
    if (queue.isEmpty) return;

    final dio = _buildDio(baseUrl, token);
    final remaining = <Map<String, dynamic>>[];

    for (final item in queue.cast<Map<String, dynamic>>()) {
      try {
        await dio.post('/deliverymen/location', data: item);
      } catch (_) {
        remaining.add(item);
      }
    }

    if (remaining.isEmpty) {
      await prefs.remove(_kOfflineQueue);
    } else {
      await prefs.setString(_kOfflineQueue, jsonEncode(remaining));
    }
  }

  Future<void> _enqueueOffline(Map<String, dynamic> payload) async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = prefs.getString(_kOfflineQueue);
    final List<dynamic> queue = queueJson != null ? jsonDecode(queueJson) : [];

    // Cap at 100 items to avoid unbounded growth (~3 hours of offline)
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

// ─── Service facade ───────────────────────────────────────────────────────────

/// Manages the GPS foreground tracking service lifecycle.
///
/// Call [initialize] once from `main()` before `runApp`.
/// Call [startTracking] when there are active "on the way" orders.
/// Call [stopTracking] when no active orders remain.
class LocationTrackingService {
  static bool _initialized = false;

  /// Must be called once before using [startTracking] or [stopTracking].
  static void initialize() {
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'location_tracking',
        channelName: 'Seguimiento de ruta',
        channelDescription:
            'Señor Arroz — compartiendo ubicación durante entregas activas',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowAutoRestart: true,
      ),
    );
  }

  /// Starts the foreground tracking service.
  ///
  /// [authToken]: the current JWT to authorize backend calls from the isolate.
  /// [baseUrl]: the API base URL (e.g. `https://senorarrozapi.up.railway.app/api`).
  static Future<void> startTracking({
    required String authToken,
    required String baseUrl,
  }) async {
    if (!_initialized) initialize();

    final alreadyRunning = await FlutterForegroundTask.isRunningService;
    if (alreadyRunning) {
      // Update token in case it was refreshed
      await FlutterForegroundTask.saveData(key: _kAuthToken, value: authToken);
      return;
    }

    // Store credentials for the background isolate
    await FlutterForegroundTask.saveData(key: _kAuthToken, value: authToken);
    await FlutterForegroundTask.saveData(key: _kBaseUrl, value: baseUrl);

    final result = await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.location],
      notificationTitle: 'Señor Arroz',
      notificationText: 'Ruta activa — compartiendo ubicación',
      callback: locationTaskCallback,
    );

    if (result is ServiceRequestFailure) {
      debugPrint('LocationTrackingService: failed to start — ${result.error}');
    }
  }

  /// Stops the foreground tracking service.
  static Future<void> stopTracking() async {
    final isRunning = await FlutterForegroundTask.isRunningService;
    if (!isRunning) return;

    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) {
      debugPrint('LocationTrackingService: failed to stop — ${result.error}');
    }

    // Clear stored credentials
    await FlutterForegroundTask.removeData(key: _kAuthToken);
    await FlutterForegroundTask.removeData(key: _kBaseUrl);
  }

  /// Updates the stored auth token (called after silent token refresh).
  static Future<void> updateToken(String newToken) async {
    final isRunning = await FlutterForegroundTask.isRunningService;
    if (!isRunning) return;
    await FlutterForegroundTask.saveData(key: _kAuthToken, value: newToken);
  }

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;
}
