import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/refresh_access_result.dart';
import '../../core/auth/session_refresh.dart';
import '../../core/auth/session_replacement.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/version/delivery_app_version.dart';

class TrackingDeferred implements Exception {
  const TrackingDeferred();
}

abstract class UploadPauseStore {
  Future<Map<String, dynamic>?> read(String sessionId);
  Future<void> write(String sessionId, Map<String, dynamic> value);
  Future<void> clear(String sessionId);
}

class PreferencesUploadPauseStore implements UploadPauseStore {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  String _key(String id) => 'sa_upload_pause_$id';
  @override
  Future<Map<String, dynamic>?> read(String sessionId) async {
    final value = await _prefs.getString(_key(sessionId));
    if (value == null) return null;
    return Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  @override
  Future<void> write(String sessionId, Map<String, dynamic> value) =>
      _prefs.setString(_key(sessionId), jsonEncode(value));
  @override
  Future<void> clear(String sessionId) => _prefs.remove(_key(sessionId));
}

/// Bounded authentication recovery and a pause shared by location/device events.
/// Every invocation loads current credentials; a batch never freezes a bearer.
class TrackingHttpClient {
  final String sessionId;
  final int? workSessionId;
  final Dio dio;
  final SessionRefresher auth;
  final UploadPauseStore pauses;
  final Future<Map<String, String>> Function() versionHeaders;
  final Future<bool> Function() isCurrent;
  final DateTime Function() now;

  TrackingHttpClient({
    required String baseUrl,
    required this.sessionId,
    this.workSessionId,
    required this.versionHeaders,
    required this.isCurrent,
    SecureStorage? storage,
    Dio? dio,
    SessionRefresher? auth,
    UploadPauseStore? pauses,
    DateTime Function()? now,
  })  : dio = dio ??
            Dio(BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
                sendTimeout: const Duration(seconds: 10))),
        auth = auth ??
            SessionRefresher(
                storage: storage ?? SecureStorage(),
                baseUrl: baseUrl,
                versionHeaders: versionHeaders),
        pauses = pauses ?? PreferencesUploadPauseStore(),
        now = now ?? DateTime.now;

  DioException _deferred(String path, {Object? cause}) => DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.cancel,
        error: cause ?? const TrackingDeferred(),
      );

  Future<Response<T>> post<T>(String path, {required dynamic data}) async {
    if (!await isCurrent()) throw _deferred(path);
    if (data is Map &&
        ((data['_authSessionId'] != null &&
                data['_authSessionId'] != sessionId) ||
            (workSessionId != null &&
                data['workSessionId'] != workSessionId))) {
      throw _deferred(path);
    }
    final oldPause = await pauses.read(sessionId);
    if ((oldPause?['until'] as num? ?? 0) > now().millisecondsSinceEpoch) {
      throw _deferred(path);
    }
    final startedAt = now().millisecondsSinceEpoch;
    try {
      var token = await _token(
          path, await auth.ensureAccess(expectedSessionId: sessionId));
      Response<T> response;
      try {
        response = await _send<T>(path, data, token);
      } on DioException catch (error) {
        if (isSessionReplacedResponse(
            error.response?.statusCode, error.response?.data)) {
          await auth.storage.withSessionLock((locked) async {
            if ((await locked.readSession())?.id == sessionId)
              await locked.clearAll();
          });
          rethrow;
        }
        if (error.response?.statusCode != 401) rethrow;
        token = await _token(
            path,
            await auth.ensureAccess(
              rejectedToken: token,
              expectedSessionId: sessionId,
            ));
        response = await _send<T>(path, data, token); // One replay only.
      }
      final currentPause = await pauses.read(sessionId);
      if ((currentPause?['changedAt'] as num? ?? 0) <= startedAt) {
        await pauses.clear(sessionId);
      }
      return response;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      // A bad point is quarantined by the queue. All other failures stop the
      // batch, including fresh-token 401/403/404 and auth-refresh outages.
      if (status != 400 && status != 422) {
        final state = await pauses.read(sessionId);
        final failures =
            min(6, ((state?['failures'] as num?)?.toInt() ?? 0) + 1);
        final delay = retryDelay(failures,
            now: now(),
            retryAfter: error.response?.headers.value('retry-after'),
            jitter: Random().nextDouble() * 0.25);
        final until = now().add(delay).millisecondsSinceEpoch;
        await pauses.write(sessionId, {
          'failures': failures,
          'until': max(until, (state?['until'] as num?)?.toInt() ?? 0),
          'changedAt': now().millisecondsSinceEpoch,
          'status': status,
        });
      }
      rethrow;
    }
  }

  Future<String> _token(String path, RefreshAccessResult result) async {
    if (result is RefreshAccessSuccess) return result.token;
    if (result is RefreshAccessUpdateRequired) {
      throw _deferred(path,
          cause: DeliveryAppUpdateRequiredException(result.policy));
    }
    if (result is RefreshAccessSessionEnded ||
        result is RefreshAccessSessionChanged) {
      throw DioException(
          requestOptions: RequestOptions(path: path),
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
              requestOptions: RequestOptions(path: path),
              statusCode: 401,
              data: {'code': 'TRACKING_SESSION_ENDED'}));
    }
    throw _deferred(path, cause: const SessionRefreshUnavailable());
  }

  Future<Response<T>> _send<T>(String path, dynamic data, String token) async {
    if (!await isCurrent()) throw _deferred(path);
    final body = data is Map
        ? Map<String, dynamic>.fromEntries(data.entries
            .where((e) => !e.key.toString().startsWith('_'))
            .map((e) => MapEntry(e.key.toString(), e.value)))
        : data;
    final cancellation = CancelToken();
    final deadline = Timer(const Duration(seconds: 20),
        () => cancellation.cancel('Upload deadline exceeded'));
    try {
      return await dio.post<T>(path,
          data: body,
          cancelToken: cancellation,
          options: Options(headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            ...await versionHeaders(),
          }));
    } finally {
      deadline.cancel();
    }
  }
}

bool isTrackingSessionEnded(DioException error) =>
    isSessionReplacedResponse(
        error.response?.statusCode, error.response?.data) ||
    (error.response?.statusCode == 401 &&
        error.response?.data is Map &&
        error.response?.data['code'] == 'TRACKING_SESSION_ENDED');

bool isLocationTransportFailure(DioException error) =>
    error.response == null &&
    const {
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    }.contains(error.type);
