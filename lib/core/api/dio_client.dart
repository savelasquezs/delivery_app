import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../auth/auth_session_bridge.dart';
import '../auth/session_refresh.dart';
import '../auth/session_replacement.dart';
import '../../features/tracking/location_tracking_service.dart';
import '../storage/secure_storage.dart';
import '../version/delivery_app_version.dart';
import 'api_constants.dart';
import 'api_exception.dart';
import 'refresh_access_result.dart';

/// MultipartFile.fromBytes conserva una factoría de stream; clone permite reintentar tras renovar el JWT.
dynamic replayableRequestBody(dynamic data) => data is FormData ? data.clone() : data;

class DioClient {
  final Dio _dio;
  final SecureStorage _storage;
  final DeliveryAppVersionInfoLoader _versionInfo;
  final void Function(String? reason)? onSessionInvalidated;
  final Future<void> Function()? onUpdateRequiredCleanup;
  DeliveryAppVersionPolicy? _updatePolicy;

  DioClient(
    this._storage,
    this._versionInfo, {
    this.onSessionInvalidated,
    this.onUpdateRequiredCleanup,
  }) : _dio = Dio() {
    _dio.options = BaseOptions(
      baseUrl: ApiConstants.baseUrl,
      connectTimeout: ApiConstants.connectTimeout,
      receiveTimeout: ApiConstants.receiveTimeout,
      headers: {'Content-Type': 'application/json'},
    );
    _setupInterceptors();
  }

  Dio get dio => _dio;

  Future<Map<String, String>> versionHeaders() => _versionInfo.headers();

  void _setupInterceptors() {
    _dio.interceptors.add(
      InterceptorsWrapper(onRequest: _onRequest, onResponse: _onResponse, onError: _onError),
    );
  }

  Future<void> _onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    try {
      options.headers.addAll(await _versionInfo.headers());
      final session = await _storage.readSession();
      final requestSessionId = options.extra['_sessionId'];
      if (_isRetry(options) && requestSessionId != session?.id) {
        handler.reject(DioException(requestOptions: options, type: DioExceptionType.cancel,
            error: const ApiException('La sesión cambió. Reintenta la operación.')));
        return;
      }
      options.extra['_sessionId'] = session?.id;
      if (session != null && session.accessToken.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer ${session.accessToken}';
      } else {
        options.headers.remove('Authorization');
      }
      handler.next(options);
    } catch (_) {
      handler.reject(DioException(requestOptions: options, error: const SessionRefreshUnavailable()));
    }
  }

  void _onResponse(Response response, ResponseInterceptorHandler handler) => handler.next(response);

  bool _isAuthPath(RequestOptions o) {
    final p = o.path;
    return p.contains('auth/login') || p.contains('auth/refresh');
  }

  Future<void> _onError(DioException err, ErrorInterceptorHandler handler) async {
    final updatePolicy = deliveryAppUpdatePolicyFromResponse(err.response?.statusCode, err.response?.data);
    if (updatePolicy != null) {
      await _activateUpdateRequired(updatePolicy);
      return handler.next(DioException(requestOptions: err.requestOptions, response: err.response,
          type: DioExceptionType.badResponse, error: DeliveryAppUpdateRequiredException(updatePolicy)));
    }

    if (isSessionReplacedResponse(err.response?.statusCode, err.response?.data)) {
      final reason = sessionReplacementMessage(err.response?.data) ?? sessionReplacedMessage;
      final invalidated = await _storage.withSessionLock((locked) async {
        final current = await locked.readSession();
        if (current == null || current.id != err.requestOptions.extra['_sessionId']) return false;
        await locked.clearAll();
        return true;
      });
      if (!invalidated) {
        return handler.next(DioException(requestOptions: err.requestOptions, type: DioExceptionType.cancel,
            error: const ApiException('La sesión cambió. Reintenta la operación.')));
      }
      onSessionInvalidated?.call(reason);
      return handler.next(DioException(requestOptions: err.requestOptions, response: err.response,
          type: DioExceptionType.badResponse, error: ApiException(reason, statusCode: 401)));
    }

    if (_isAuthPath(err.requestOptions)) {
      return handler.next(DioException(requestOptions: err.requestOptions, response: err.response,
          type: err.type, error: _mapDioError(err)));
    }
    if (err.response?.statusCode == 401 && !_isRetry(err.requestOptions)) {
      final result = await _refreshAccessToken(
        rejectedToken: err.requestOptions.headers['Authorization']?.toString().replaceFirst('Bearer ', ''),
        expectedSessionId: err.requestOptions.extra['_sessionId'] as String?,
      );
      if (result is RefreshAccessSuccess) {
        final retryOptions = err.requestOptions
          ..headers['Authorization'] = 'Bearer ${result.token}'
          ..extra['_retry'] = true;
        try {
          retryOptions.data = replayableRequestBody(retryOptions.data);
          final retryResponse = await _dio.fetch(retryOptions);
          return handler.resolve(retryResponse);
        } on DioException catch (retryError) {
          return handler.next(retryError);
        } catch (_) {
          return handler.next(DioException(requestOptions: retryOptions,
              error: const ApiException('No se pudo reintentar el archivo. Confirma nuevamente.')));
        }
      }
      if (result is RefreshAccessUpdateRequired) {
        return handler.next(DioException(requestOptions: err.requestOptions, response: err.response,
            type: DioExceptionType.badResponse, error: DeliveryAppUpdateRequiredException(result.policy)));
      }
      if (result is RefreshAccessSessionEnded) {
        return handler.next(DioException(requestOptions: err.requestOptions, response: err.response,
            type: DioExceptionType.badResponse, error: const SessionEndedException()));
      }
      return handler.next(DioException(requestOptions: err.requestOptions, response: err.response, type: err.type,
          error: result is RefreshAccessSessionChanged
              ? const ApiException('La sesión cambió. Reintenta la operación.') : const SessionRefreshUnavailable()));
    }
    handler.next(DioException(requestOptions: err.requestOptions, response: err.response, type: err.type, error: _mapDioError(err)));
  }

  bool _isRetry(RequestOptions options) => options.extra['_retry'] == true;
  Future<RefreshAccessResult> silentRefreshAccessToken() => _refreshAccessToken();

  Future<RefreshAccessResult> _refreshAccessToken({String? rejectedToken, String? expectedSessionId}) async {
    if (_updatePolicy != null) return RefreshAccessUpdateRequired(_updatePolicy!);
    try {
      final contextId = expectedSessionId ?? (await _storage.readSession())?.id;
      final result = await SessionRefresher(storage: _storage, baseUrl: ApiConstants.baseUrl,
        versionHeaders: _versionInfo.headers).ensureAccess(rejectedToken: rejectedToken, expectedSessionId: contextId);
      if (result is RefreshAccessSuccess) {
        final current = await _storage.readSession();
        if (current == null || current.id != contextId) return const RefreshAccessSessionChanged();
        await LocationTrackingService.updateToken(current.accessToken);
        return RefreshAccessSuccess(current.accessToken);
      } else if (result is RefreshAccessSessionEnded) {
        if (await _storage.readSession() != null) return const RefreshAccessSessionChanged();
        onSessionInvalidated?.call(null);
      } else if (result is RefreshAccessUpdateRequired) {
        await _activateUpdateRequired(result.policy);
      }
      return result;
    } catch (_) { return const RefreshAccessTransientFailure(); }
  }

  Future<void> _activateUpdateRequired(DeliveryAppVersionPolicy policy) async {
    if (_updatePolicy != null) return;
    _updatePolicy = policy;
    try {
      if (onUpdateRequiredCleanup != null) {
        await onUpdateRequiredCleanup!();
      } else {
        await LocationTrackingService.stopTracking(recordEvent: false, discardPending: false);
      }
    } catch (_) {}
    await _storage.clearAll();
    notifyDeliveryAppUpdateRequired(policy);
  }

  ApiException _mapDioError(DioException err) {
    if (err.response != null) {
      final statusCode = err.response!.statusCode ?? 0;
      final data = err.response!.data;
      String? serverMessage;
      if (data is Map) serverMessage = (data['message'] ?? data['title']) as String?;
      return ApiException.fromStatusCode(statusCode, serverMessage);
    }
    if (err.type == DioExceptionType.connectionTimeout || err.type == DioExceptionType.receiveTimeout || err.type == DioExceptionType.sendTimeout) {
      return const ApiException('Tiempo de espera agotado. Verifica tu conexión');
    }
    if (err.type == DioExceptionType.connectionError) {
      return const ApiException('No pudimos conectarnos. Revisa tu conexión a internet e inténtalo de nuevo.');
    }
    return const ApiException('Sin conexión a internet');
  }

  Future<T> get<T>(String path, {Map<String, dynamic>? queryParameters, T Function(dynamic)? fromJson}) async {
    final response = await _dio.get<dynamic>(path, queryParameters: queryParameters);
    return fromJson != null ? fromJson(response.data) : response.data as T;
  }

  Future<T> post<T>(String path, {dynamic data, T Function(dynamic)? fromJson, Options? options}) async {
    final response = await _dio.post<dynamic>(path, data: data, options: options);
    return fromJson != null ? fromJson(response.data) : response.data as T;
  }

  /// FormData con archivos no utiliza el Content-Type JSON global.
  Future<T> postMultipart<T>(String path, {required FormData formData, T Function(dynamic)? fromJson}) async {
    final response = await _dio.post<dynamic>(path, data: formData, options: Options(contentType: null));
    return fromJson != null ? fromJson(response.data) : response.data as T;
  }

  Future<T> put<T>(String path, {dynamic data, T Function(dynamic)? fromJson}) async {
    final response = await _dio.put<dynamic>(path, data: data);
    return fromJson != null ? fromJson(response.data) : response.data as T;
  }

  Future<T> delete<T>(String path, {dynamic data, T Function(dynamic)? fromJson}) async {
    final response = await _dio.delete<dynamic>(path, data: data);
    return fromJson != null ? fromJson(response.data) : response.data as T;
  }
}

final dioClientProvider = Provider<DioClient>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return DioClient(storage, ref.watch(deliveryAppVersionInfoProvider), onSessionInvalidated: notifyAuthSessionInvalidatedByApi);
});
