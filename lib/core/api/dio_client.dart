import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../storage/secure_storage.dart';
import 'api_constants.dart';
import 'api_exception.dart';

class DioClient {
  final Dio _dio;
  final SecureStorage _storage;

  DioClient(this._storage) : _dio = Dio() {
    _dio.options = BaseOptions(
      baseUrl: ApiConstants.baseUrl,
      connectTimeout: ApiConstants.connectTimeout,
      receiveTimeout: ApiConstants.receiveTimeout,
      headers: {'Content-Type': 'application/json'},
    );
    _setupInterceptors();
  }

  Dio get dio => _dio;

  void _setupInterceptors() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: _onRequest,
        onResponse: _onResponse,
        onError: _onError,
      ),
    );
  }

  Future<void> _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _storage.getAuthToken();
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  void _onResponse(Response response, ResponseInterceptorHandler handler) {
    handler.next(response);
  }

  Future<void> _onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (err.response?.statusCode == 401 && !_isRetry(err.requestOptions)) {
      try {
        final refreshToken = await _storage.getRefreshToken();
        if (refreshToken != null) {
          final refreshDio = Dio(
            BaseOptions(
              baseUrl: ApiConstants.baseUrl,
              connectTimeout: ApiConstants.connectTimeout,
            ),
          );
          final response = await refreshDio.post(
            ApiConstants.refresh,
            data: {'refreshToken': refreshToken},
          );
          final newToken = response.data['token'] as String;
          await _storage.saveTokens(
            authToken: newToken,
            refreshToken: refreshToken,
          );
          final retryOptions = err.requestOptions
            ..headers['Authorization'] = 'Bearer $newToken'
            ..extra['_retry'] = true;
          final retryResponse = await _dio.fetch(retryOptions);
          return handler.resolve(retryResponse);
        }
      } catch (_) {
        await _storage.clearAll();
      }
      return handler.next(
        DioException(
          requestOptions: err.requestOptions,
          response: err.response,
          type: DioExceptionType.badResponse,
          error: const ApiException('Sesión expirada', statusCode: 401),
        ),
      );
    }

    final apiError = _mapDioError(err);
    handler.next(
      DioException(
        requestOptions: err.requestOptions,
        response: err.response,
        type: err.type,
        error: apiError,
      ),
    );
  }

  bool _isRetry(RequestOptions options) =>
      options.extra['_retry'] == true;

  ApiException _mapDioError(DioException err) {
    if (err.response != null) {
      final statusCode = err.response!.statusCode ?? 0;
      final data = err.response!.data;
      String? serverMessage;
      if (data is Map) {
        serverMessage = (data['message'] ?? data['title']) as String?;
      }
      return ApiException.fromStatusCode(statusCode, serverMessage);
    }
    if (err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout) {
      return const ApiException('Tiempo de espera agotado. Verifica tu conexión');
    }
    return const ApiException('Sin conexión a internet');
  }

  // Helpers tipados
  Future<T> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    T Function(dynamic)? fromJson,
  }) async {
    final response = await _dio.get<dynamic>(path, queryParameters: queryParameters);
    return fromJson != null ? fromJson(response.data) : response.data as T;
  }

  Future<T> post<T>(
    String path, {
    dynamic data,
    T Function(dynamic)? fromJson,
  }) async {
    final response = await _dio.post<dynamic>(path, data: data);
    return fromJson != null ? fromJson(response.data) : response.data as T;
  }

  Future<T> put<T>(
    String path, {
    dynamic data,
    T Function(dynamic)? fromJson,
  }) async {
    final response = await _dio.put<dynamic>(path, data: data);
    return fromJson != null ? fromJson(response.data) : response.data as T;
  }
}

final dioClientProvider = Provider<DioClient>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return DioClient(storage);
});
