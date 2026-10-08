import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../api/refresh_access_result.dart';
import '../storage/secure_storage.dart';
import '../version/delivery_app_version.dart';
import 'jwt_expiration.dart';
import 'token_session.dart';

/// One refresh implementation for UI and foreground task. The storage lock is
/// shared across Flutter engines, including login/logout and refresh rotation.
class SessionRefresher {
  final SecureStorage storage;
  final Dio dio;
  final Future<Map<String, String>> Function() versionHeaders;
  final DateTime Function() now;

  SessionRefresher({
    required this.storage,
    required String baseUrl,
    required this.versionHeaders,
    Dio? dio,
    DateTime Function()? now,
  })  : dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
            )),
        now = now ?? DateTime.now;

  Future<RefreshAccessResult> ensureAccess({
    String? rejectedToken,
    String? expectedSessionId,
  }) async {
    try {
      return await storage.withSessionLock((locked) async {
        final session = await locked.readSession();
        if (session == null) return const RefreshAccessSessionEnded();
        if (expectedSessionId != null && session.id != expectedSessionId) {
          return const RefreshAccessSessionChanged();
        }
        final expiry = JwtExpiration.expiresAtUtc(session.accessToken);
        final nearExpiry = expiry == null ||
            !expiry.isAfter(now().add(JwtExpiration.defaultProactiveSkew));
        if (!nearExpiry &&
            (rejectedToken == null || rejectedToken != session.accessToken)) {
          return RefreshAccessSuccess(session.accessToken);
        }
        // Refresh failures are throttled across both engines, not just in memory.
        if (session.retryRefreshAt > now().millisecondsSinceEpoch) {
          return _usableOrTransient(session, rejectedToken);
        }
        final cancellation = CancelToken();
        final deadline = Timer(const Duration(seconds: 20), () {
          cancellation.cancel('Refresh deadline exceeded');
        });
        try {
          final response = await dio.post<dynamic>(
            '/auth/refresh',
            data: {'refreshToken': session.refreshToken},
            options: Options(headers: {
              'Authorization': 'Bearer ${session.accessToken}',
              'Content-Type': 'application/json',
              ...await versionHeaders(),
            }),
            cancelToken: cancellation,
          );
          final data = _object(response.data);
          final access = data?['token'] ?? data?['Token'];
          final refresh = data?['refreshToken'] ?? data?['RefreshToken'];
          // A rotating pair must be complete; never combine new/old credentials.
          if (access is! String ||
              access.isEmpty ||
              refresh is! String ||
              refresh.isEmpty) {
            await _defer(locked, session);
            return _usableOrTransient(session, rejectedToken);
          }
          await locked.writeSession(TokenSession(
            id: session.id,
            accessToken: access,
            refreshToken: refresh,
          ));
          return RefreshAccessSuccess(access);
        } on DioException catch (error) {
          final update = deliveryAppUpdatePolicyFromResponse(
            error.response?.statusCode,
            error.response?.data,
          );
          if (update != null) return RefreshAccessUpdateRequired(update);
          if (_definitiveRejection(error)) {
            await locked.clearAll();
            return const RefreshAccessSessionEnded();
          }
          await _defer(locked, session,
              retryAfter: error.response?.headers.value('retry-after'));
          return _usableOrTransient(session, rejectedToken);
        } catch (_) {
          await _defer(locked, session);
          return _usableOrTransient(session, rejectedToken);
        } finally {
          deadline.cancel();
        }
      });
    } catch (_) {
      // Lock/storage errors are not evidence of an expired/revoked session.
      return const RefreshAccessTransientFailure();
    }
  }

  RefreshAccessResult _usableOrTransient(
      TokenSession session, String? rejected) {
    final expiry = JwtExpiration.expiresAtUtc(session.accessToken);
    if (rejected == null &&
        expiry != null &&
        expiry.isAfter(now().add(const Duration(seconds: 30)))) {
      return RefreshAccessSuccess(session.accessToken);
    }
    return const RefreshAccessTransientFailure();
  }

  Future<void> _defer(SecureStorage locked, TokenSession session,
      {String? retryAfter}) async {
    final current = await locked.readSession();
    if (current == null ||
        current.id != session.id ||
        current.accessToken != session.accessToken ||
        current.refreshToken != session.refreshToken) return;
    final attempts = min(session.refreshFailures + 1, 6);
    final delay = retryDelay(attempts, now: now(), retryAfter: retryAfter);
    await locked.writeSession(TokenSession(
      id: session.id,
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      refreshFailures: attempts,
      retryRefreshAt: now().add(delay).millisecondsSinceEpoch,
    ));
  }

  static bool _definitiveRejection(DioException error) {
    final status = error.response?.statusCode;
    if (status == 401) return true;
    if (status != 400) return false;
    final data = _object(error.response?.data);
    final code = (data?['code'] ?? data?['Code'])?.toString().toUpperCase();
    if (const {
      'INVALID_REFRESH_TOKEN',
      'REFRESH_TOKEN_EXPIRED',
      'REFRESH_TOKEN_REVOKED'
    }.contains(code)) {
      return true;
    }
    final message =
        (data?['message'] ?? data?['Message'] ?? '').toString().toLowerCase();
    return (message.contains('refresh') || message.contains('actualización')) &&
        (message.contains('inválido') ||
            message.contains('invalid') ||
            message.contains('expirado') ||
            message.contains('revocado') ||
            message.contains('no encontrado'));
  }

  static Map<String, dynamic>? _object(dynamic value) {
    try {
      final data = value is String ? jsonDecode(value) : value;
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      return null;
    }
  }
}

Duration retryDelay(int failures,
    {required DateTime now, String? retryAfter, double jitter = 0}) {
  var seconds =
      min(300, 15 * (1 << (failures.clamp(1, 6).toInt() - 1))).toDouble();
  seconds *= 1 + jitter.clamp(0, 0.25);
  var delay = Duration(milliseconds: (seconds * 1000).ceil());
  if (retryAfter != null) {
    final number = int.tryParse(retryAfter.trim());
    Duration? requested;
    if (number != null && number >= 0) {
      requested = Duration(seconds: number);
    } else {
      try {
        requested = HttpDate.parse(retryAfter).difference(now.toUtc());
      } catch (_) {}
    }
    if (requested != null && requested > delay) delay = requested;
  }
  return delay;
}

class SessionRefreshUnavailable implements Exception {
  const SessionRefreshUnavailable();
}

class SessionEndedException implements Exception {
  const SessionEndedException();
}

bool isTransientSessionFailure(Object error) {
  if (error is! DioException) return false;
  final status = error.response?.statusCode;
  return error.error is SessionRefreshUnavailable ||
      status == null ||
      status == 408 ||
      status == 429 ||
      (status >= 500 && status <= 599);
}
