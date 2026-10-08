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
import '../../core/version/delivery_app_version.dart';
import 'location_tracking_policy.dart';

const _kAuthSessionId = 'sa_loc_auth_session_id';
const _kRejectedQueue = 'sa_loc_rejected_queue';
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
const _kInternetAvailable = 'sa_loc_internet_available';
const _kBatteryLowReported = 'sa_loc_battery_low_reported';
const _kTrackingExpectedActive = 'sa_loc_expected_active';
const _kUnexpectedStopReportedSession = 'sa_loc_stop_reported_session';
const _modeLight = 'light';
const _modeActiveDelivery = 'active_delivery';
const _modeOffline = 'offline';
const _batteryLowThresholdPercent = 15;
const _uuid = Uuid();
TrackingHttpClient? _cachedTrackingClient;
String? _cachedTrackingBaseUrl;

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
  final token = await FlutterForegroundTask.getData<String>(key: _kAuthToken);
  final baseUrl = await FlutterForegroundTask.getData<String>(key: _kBaseUrl);
  final workSessionId =
      await FlutterForegroundTask.getData<int>(key: _kWorkSessionId);
  if (workSessionId == null) return;

  final payload = <String, dynamic>{
    '_authSessionId':
        await FlutterForegroundTask.getData<String>(key: _kAuthSessionId),
    'clientEventId': clientEventId ?? _uuid.v4(),
    'workSessionId': workSessionId,
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
  };
  if (token == null || baseUrl == null) {
    await _enqueueDeviceEvent(payload);
    return;
  }

  try {
    await (await _trackingClient(baseUrl, token))
        .post('/deliverymen/device-event', data: payload);
  } on DioException catch (error) {
    final updatePolicy = _updateRequiredPolicy(error);
    if (updatePolicy != null) {
      _notifyMainOfRequiredUpdate(updatePolicy);
      await LocationTrackingService._stopTracking(
        recordEvent: false,
        discardPending: false,
      );
      return;
    }
    if (isTrackingSessionEnded(error)) {
      await _stopForPayload(payload);
      return;
    }
    if (_isPermanentClientErrorStatus(error.response?.statusCode)) {
      await _quarantineRejected(payload, error.response?.statusCode);
    } else {
      await _enqueueDeviceEvent(payload);
    }
  } catch (_) {
    await _enqueueDeviceEvent(payload);
  }
}

Future<void> _drainNativeDeviceEvents() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final pendingKeys = prefs
      .getKeys()
      .where((key) => key.startsWith(_kNativeDeviceEventPrefix))
      .toList()
    ..sort();
  for (final key in pendingKeys) {
    final encoded = prefs.getString(key);
    if (encoded == null) continue;
    final event = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    await _recordDeviceEvent(
      event['eventType']?.toString() ?? '',
      clientEventId: event['clientEventId']?.toString(),
      details: event['details']?.toString(),
      recordedAt: DateTime.tryParse(event['recordedAt']?.toString() ?? ''),
    );
    await prefs.remove(key);
  }

  final legacyEncoded = prefs.getString(_kNativeDeviceEventQueue);
  if (legacyEncoded == null) return;
  final legacyQueue = jsonDecode(legacyEncoded) as List<dynamic>;
  await prefs.remove(_kNativeDeviceEventQueue);
  for (final item in legacyQueue) {
    final event = Map<String, dynamic>.from(item as Map);
    await _recordDeviceEvent(
      event['eventType']?.toString() ?? '',
      clientEventId: event['clientEventId']?.toString(),
      details: event['details']?.toString(),
      recordedAt: DateTime.tryParse(event['recordedAt']?.toString() ?? ''),
    );
  }
}

class _OfflineSyncResult {
  final int count;
  final DateTime? startedAt;
  final DateTime? endedAt;

  const _OfflineSyncResult(this.count, this.startedAt, this.endedAt);
}

Future<void> _enqueueDeviceEvent(Map<String, dynamic> payload) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final encoded = prefs.getString(_kDeviceEventQueue);
  final queue =
      encoded == null ? <dynamic>[] : jsonDecode(encoded) as List<dynamic>;
  queue.add(payload);
  await prefs.setString(_kDeviceEventQueue, jsonEncode(queue));
}

Future<void> _flushDeviceEvents(String token, String baseUrl) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final encoded = prefs.getString(_kDeviceEventQueue);
  if (encoded == null) return;
  final queue = jsonDecode(encoded) as List<dynamic>;
  final remaining = <Map<String, dynamic>>[];
  final dio = await _trackingClient(baseUrl, token);
  var attempted = 0;
  for (var index = 0; index < queue.length; index++) {
    final payload = Map<String, dynamic>.from(queue[index] as Map);
    if (!await _belongsToCurrentTracking(payload)) {
      remaining.add(payload);
      continue;
    }
    if (attempted >= 10) {
      remaining.addAll(
          queue.skip(index).map((e) => Map<String, dynamic>.from(e as Map)));
      break;
    }
    attempted++;
    payload['_authSessionId'] ??= dio.sessionId;
    try {
      await dio.post('/deliverymen/device-event', data: payload);
    } on DioException catch (error) {
      final updatePolicy = _updateRequiredPolicy(error);
      if (updatePolicy != null) {
        _notifyMainOfRequiredUpdate(updatePolicy);
        await LocationTrackingService._stopTracking(
          recordEvent: false,
          discardPending: false,
        );
        return;
      }
      if (isTrackingSessionEnded(error)) {
        await _stopForPayload(payload);
        return;
      }
      if (_isPermanentClientErrorStatus(error.response?.statusCode)) {
        await _quarantineRejected(payload, error.response?.statusCode);
      } else {
        remaining.addAll(
            queue.skip(index).map((e) => Map<String, dynamic>.from(e as Map)));
        break;
      }
    } catch (_) {
      remaining.addAll(
          queue.skip(index).map((e) => Map<String, dynamic>.from(e as Map)));
      break;
    }
  }
  if (remaining.isEmpty) {
    await prefs.remove(_kDeviceEventQueue);
  } else {
    await prefs.setString(_kDeviceEventQueue, jsonEncode(remaining));
  }
}

Future<bool> _recordBooleanTransition({
  required String storageKey,
  required bool current,
  required String negativeEvent,
  required String positiveEvent,
  bool internetState = false,
  bool gpsState = false,
  bool permissionState = false,
  String? details,
  int? offlineLocationCount,
  DateTime? offlineStartedAt,
  DateTime? offlineEndedAt,
}) async {
  final previous = await FlutterForegroundTask.getData<bool>(key: storageKey);
  await FlutterForegroundTask.saveData(key: storageKey, value: current);
  if (previous == current || (previous == null && current)) return false;
  await _recordDeviceEvent(
    current ? positiveEvent : negativeEvent,
    internetAvailable: internetState ? current : null,
    gpsEnabled: gpsState ? current : null,
    locationPermissionGranted: permissionState ? current : null,
    details: details,
    offlineLocationCount: offlineLocationCount,
    offlineStartedAt: offlineStartedAt,
    offlineEndedAt: offlineEndedAt,
  );
  return true;
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

bool _isPermanentClientErrorStatus(int? status) =>
    status == 400 || status == 422;

Future<TrackingHttpClient> _trackingClient(
    String baseUrl, String legacyToken) async {
  var sessionId =
      await FlutterForegroundTask.getData<String>(key: _kAuthSessionId);
  // One-time migration after upgrading an already-running installation. Never
  // infer ownership from a different token or attach old data to a new login.
  if (sessionId == null) {
    final session = await SecureStorage().readSession();
    if (session != null && session.accessToken == legacyToken) {
      sessionId = session.id;
      await FlutterForegroundTask.saveData(
          key: _kAuthSessionId, value: sessionId);
    }
  }
  final expected = sessionId ?? 'unbound';
  final workSession =
      await FlutterForegroundTask.getData<int>(key: _kWorkSessionId);
  if (_cachedTrackingClient?.sessionId == expected &&
      _cachedTrackingClient?.workSessionId == workSession &&
      _cachedTrackingBaseUrl == baseUrl) {
    return _cachedTrackingClient!;
  }
  _cachedTrackingClient?.dio.close();
  _cachedTrackingClient?.auth.dio.close();
  _cachedTrackingBaseUrl = baseUrl;
  return _cachedTrackingClient = TrackingHttpClient(
      baseUrl: baseUrl,
      sessionId: expected,
      workSessionId: workSession,
      versionHeaders: _trackingVersionHeaders,
      isCurrent: () async {
        final current =
            await FlutterForegroundTask.getData<String>(key: _kAuthSessionId);
        final currentWorkSession =
            await FlutterForegroundTask.getData<int>(key: _kWorkSessionId);
        final cutoff =
            await FlutterForegroundTask.getData<String>(key: _kAutoCloseAt);
        final until = DateTime.tryParse(cutoff ?? '');
        return current == expected &&
            currentWorkSession == workSession &&
            until != null &&
            DateTime.now().isBefore(until);
      });
}

Future<bool> _belongsToCurrentTracking(Map<String, dynamic> payload) async {
  final workSession =
      await FlutterForegroundTask.getData<int>(key: _kWorkSessionId);
  final authSession =
      await FlutterForegroundTask.getData<String>(key: _kAuthSessionId);
  return payload['workSessionId'] == workSession &&
      (payload['_authSessionId'] == null ||
          payload['_authSessionId'] == authSession);
}

Future<void> _stopForPayload(Map<String, dynamic> payload) async {
  if (!await _belongsToCurrentTracking(payload)) return;
  await LocationTrackingService._stopTracking(
      recordEvent: false, discardPending: false);
  FlutterForegroundTask.sendDataToMain({
    'type': 'tracking_session_ended',
    'sessionId': payload['_authSessionId'],
  });
}

Future<void> _quarantineRejected(
    Map<String, dynamic> payload, int? status) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final encoded = prefs.getString(_kRejectedQueue);
  final rows =
      encoded == null ? <dynamic>[] : jsonDecode(encoded) as List<dynamic>;
  rows.add({
    'payload': payload,
    'status': status,
    'rejectedAt': DateTime.now().toUtc().toIso8601String()
  });
  await prefs.setString(_kRejectedQueue, jsonEncode(rows));
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
        final nativePrefs = await SharedPreferences.getInstance();
        await nativePrefs.setBool(_kNativeTrackingActive, false);
        await FlutterForegroundTask.stopService();
        return;
      }

      final permissionState = await readLocationPermissionState();
      final gpsEnabled = permissionState.serviceEnabled;
      await _recordBooleanTransition(
        storageKey: _kGpsEnabled,
        current: gpsEnabled,
        negativeEvent: 'gps_disabled',
        positiveEvent: 'gps_enabled',
        gpsState: true,
      );
      if (!gpsEnabled) return;

      final permissionGranted = permissionState.canTrackInBackground;
      await _recordBooleanTransition(
        storageKey: _kLocationPermissionGranted,
        current: permissionGranted,
        negativeEvent: 'location_permission_revoked',
        positiveEvent: 'location_permission_recovered',
        permissionState: true,
        details: permissionState.eventDetails,
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
      await _recordBatteryLowTransition(batteryLevel);
      final payload = <String, dynamic>{
        '_authSessionId':
            await FlutterForegroundTask.getData<String>(key: _kAuthSessionId),
        'clientPointId': _uuid.v4(),
        'workSessionId':
            await FlutterForegroundTask.getData<int>(key: _kWorkSessionId),
        'deliveryRouteId':
            await FlutterForegroundTask.getData<int>(key: _kDeliveryRouteId),
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracyMeters': validAccuracyMeters(position.accuracy),
        'headingDegrees': validHeadingDegrees(position.heading),
        'batteryLevelPercent': batteryLevel,
        'internetAvailable': true,
        'gpsEnabled': true,
        'trackingMode': trackingMode,
        'recordedAt': position.timestamp.toUtc().toIso8601String(),
      };

      await _drainNativeDeviceEvents();
      await _flushDeviceEvents(token, baseUrl);
      final offlineSync = await _flushOfflineQueue(token, baseUrl);
      await _postLocation(token, baseUrl, payload, offlineSync);
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
    _OfflineSyncResult offlineSync,
  ) async {
    try {
      if (!await _belongsToCurrentTracking(payload)) return;
      final response = await (await _buildDio(baseUrl, token))
          .post('/deliverymen/location', data: payload);
      if (await _belongsToCurrentTracking(payload))
        await _applyTrackingResult(response.data);
      final recoveryReported = await _recordBooleanTransition(
        storageKey: _kInternetAvailable,
        current: true,
        negativeEvent: 'internet_lost',
        positiveEvent: 'internet_recovered',
        internetState: true,
        details: offlineSync.count > 0
            ? 'queued_location_count=${offlineSync.count}'
            : null,
        offlineLocationCount: offlineSync.count > 0 ? offlineSync.count : null,
        offlineStartedAt: offlineSync.startedAt,
        offlineEndedAt: offlineSync.endedAt,
      );
      if (offlineSync.count > 0 && !recoveryReported) {
        await _recordDeviceEvent(
          'internet_recovered',
          internetAvailable: true,
          details: 'queued_location_count=${offlineSync.count}',
          offlineLocationCount: offlineSync.count,
          offlineStartedAt: offlineSync.startedAt,
          offlineEndedAt: offlineSync.endedAt,
        );
      }
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final updatePolicy = _updateRequiredPolicy(error);
      if (updatePolicy != null) {
        _notifyMainOfRequiredUpdate(updatePolicy);
        await LocationTrackingService._stopTracking(
          recordEvent: false,
          discardPending: false,
        );
        return;
      }
      if (isTrackingSessionEnded(error)) {
        await _stopForPayload(payload);
        return;
      }
      final disposition = locationFailureDisposition(status);
      if (disposition == LocationFailureDisposition.quarantinePoint) {
        await _quarantineRejected(payload, status);
        return;
      }
      if (isLocationTransportFailure(error)) {
        await _recordBooleanTransition(
          storageKey: _kInternetAvailable,
          current: false,
          negativeEvent: 'internet_lost',
          positiveEvent: 'internet_recovered',
          internetState: true,
        );
      }
      await _enqueueOffline(
        isLocationTransportFailure(error)
            ? _asOfflinePayload(payload)
            : payload,
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

  Future<_OfflineSyncResult> _flushOfflineQueue(
      String token, String baseUrl) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final queueJson = prefs.getString(_kOfflineQueue);
    if (queueJson == null) return const _OfflineSyncResult(0, null, null);

    final queue = jsonDecode(queueJson) as List<dynamic>;
    if (queue.isEmpty) return const _OfflineSyncResult(0, null, null);

    final dio = await _buildDio(baseUrl, token);
    final remaining = <Map<String, dynamic>>[];
    var syncedCount = 0;
    DateTime? syncedStartedAt;
    DateTime? syncedEndedAt;
    var attempted = 0;
    for (var index = 0; index < queue.length; index++) {
      final payload = Map<String, dynamic>.from(queue[index] as Map);
      if (!await _belongsToCurrentTracking(payload)) {
        remaining.add(payload);
        continue;
      }
      if (attempted >= 10) {
        remaining.addAll(
            queue.skip(index).map((e) => Map<String, dynamic>.from(e as Map)));
        break;
      }
      attempted++;
      payload['_authSessionId'] ??= dio.sessionId;
      try {
        final response = await dio.post('/deliverymen/location', data: payload);
        if (await _belongsToCurrentTracking(payload))
          await _applyTrackingResult(response.data);
        syncedCount++;
        final recordedAt =
            DateTime.tryParse(payload['recordedAt']?.toString() ?? '')?.toUtc();
        if (recordedAt != null) {
          if (syncedStartedAt == null || recordedAt.isBefore(syncedStartedAt)) {
            syncedStartedAt = recordedAt;
          }
          if (syncedEndedAt == null || recordedAt.isAfter(syncedEndedAt)) {
            syncedEndedAt = recordedAt;
          }
        }
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        final updatePolicy = _updateRequiredPolicy(error);
        if (updatePolicy != null) {
          _notifyMainOfRequiredUpdate(updatePolicy);
          await LocationTrackingService._stopTracking(
            recordEvent: false,
            discardPending: false,
          );
          return _OfflineSyncResult(
              syncedCount, syncedStartedAt, syncedEndedAt);
        }
        if (isTrackingSessionEnded(error)) {
          await _stopForPayload(payload);
          return _OfflineSyncResult(
              syncedCount, syncedStartedAt, syncedEndedAt);
        }
        if (locationFailureDisposition(status) ==
            LocationFailureDisposition.quarantinePoint) {
          await _quarantineRejected(payload, status);
        } else {
          remaining.addAll(queue
              .skip(index)
              .map((e) => Map<String, dynamic>.from(e as Map)));
          break;
        }
      } catch (_) {
        remaining.addAll(
            queue.skip(index).map((e) => Map<String, dynamic>.from(e as Map)));
        break;
      }
    }

    if (remaining.isEmpty) {
      await prefs.remove(_kOfflineQueue);
    } else {
      await prefs.setString(_kOfflineQueue, jsonEncode(remaining));
    }
    return _OfflineSyncResult(syncedCount, syncedStartedAt, syncedEndedAt);
  }

  Future<void> _applyTrackingResult(dynamic data) async {
    if (data is! Map) return;
    final continueActive = data['continueActiveTracking'] == true;
    final routeIdValue = data['deliveryRouteId'];
    final routeId = routeIdValue is int
        ? routeIdValue
        : int.tryParse(routeIdValue?.toString() ?? '');
    if (continueActive && routeId != null) {
      await LocationTrackingService.setActiveDeliveryMode(routeId: routeId);
    } else {
      await LocationTrackingService.setLightMode();
    }
  }

  Future<void> _enqueueOffline(Map<String, dynamic> payload) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final queueJson = prefs.getString(_kOfflineQueue);
    final queue = queueJson != null
        ? jsonDecode(queueJson) as List<dynamic>
        : <dynamic>[];
    // Do not silently discard a location. The queue is drained before every
    // new point is posted and every item remains until the API acknowledges it.
    queue.add(payload);
    await prefs.setString(_kOfflineQueue, jsonEncode(queue));
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

  Future<TrackingHttpClient> _buildDio(String baseUrl, String token) =>
      _trackingClient(baseUrl, token);
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
    required String versionName,
    required String buildNumber,
    required String packageName,
  }) =>
      _enqueue(
        () => _startTracking(
          authToken: authToken,
          baseUrl: baseUrl,
          workSessionId: workSessionId,
          autoCloseAtUtc: autoCloseAtUtc,
          lightIntervalSeconds: lightIntervalSeconds,
          activeIntervalSeconds: activeIntervalSeconds,
          versionName: versionName,
          buildNumber: buildNumber,
          packageName: packageName,
        ),
      );

  static Future<void> _startTracking({
    required String authToken,
    required String baseUrl,
    required int workSessionId,
    required DateTime autoCloseAtUtc,
    required int lightIntervalSeconds,
    required int activeIntervalSeconds,
    required String versionName,
    required String buildNumber,
    required String packageName,
  }) async {
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
    await _drainNativeDeviceEvents();
    final nativePrefs = await SharedPreferences.getInstance();
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
    final result = await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.location],
      notificationTitle: 'Señor Arroz',
      notificationText: 'Jornada activa — seguimiento liviano',
      callback: locationTaskCallback,
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
    if (resumeActive) {
      await _setActiveDeliveryMode(routeId: previousRouteId);
    } else {
      await _setLightMode();
    }
  }

  static Future<void> setLightMode() => _enqueue(_setLightMode);

  static Future<void> _setLightMode() async {
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
  }) async {
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
    final nativePrefs = await SharedPreferences.getInstance();
    await nativePrefs.setBool(_kNativeTrackingActive, false);

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
    if (discardPending) {
      await prefs.remove(_kOfflineQueue);
      await prefs.remove(_kDeviceEventQueue);
    }
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
