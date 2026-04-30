import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/tracking/location_tracking_service.dart';
import '../storage/secure_storage.dart';
import 'api_constants.dart';
import 'api_exception.dart';

class DioClient {
  final Dio _dio;
  final SecureStorage _storage;

  /// Una sola renovación a la vez (el backend rota el refresh token al usarlo).
  Completer<String?>? _refreshCompleter;

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
    final hasBearer = token != null && token.isNotEmpty;
    if (hasBearer) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  void _onResponse(Response response, ResponseInterceptorHandler handler) {
    handler.next(response);
  }

  bool _isAuthPath(RequestOptions o) {
    final p = o.path;
    return p.contains('auth/login') || p.contains('auth/refresh');
  }

  Future<void> _onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (_isAuthPath(err.requestOptions)) {
      final apiError = _mapDioError(err);
      return handler.next(
        DioException(
          requestOptions: err.requestOptions,
          response: err.response,
          type: err.type,
          error: apiError,
        ),
      );
    }
    if (err.response?.statusCode == 401 && !_isRetry(err.requestOptions)) {
      final newToken = await _refreshAccessToken();
      if (newToken != null) {
        final retryOptions = err.requestOptions
          ..headers['Authorization'] = 'Bearer $newToken'
          ..extra['_retry'] = true;
        final retryResponse = await _dio.fetch(retryOptions);
        return handler.resolve(retryResponse);
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

  static Map<String, dynamic>? _tryParseJsonObject(dynamic data) {
    if (data == null) return null;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  /// Acepta camelCase o PascalCase (según serialización del API).
  static String? _readStringKey(Map<String, dynamic> map, String camelKey) {
    final pascal =
        camelKey.isEmpty ? camelKey : '${camelKey[0].toUpperCase()}${camelKey.substring(1)}';
    final v = map[camelKey] ?? map[pascal];
    if (v is String && v.isNotEmpty) return v;
    return null;
  }

  static String _extractErrorMessage(dynamic data) {
    final map = _tryParseJsonObject(data);
    if (map != null) {
      final m = map['message'] ?? map['Message'] ?? map['title'] ?? map['Title'];
      if (m is String) return m;
    }
    if (data is String) return data;
    return '';
  }

  /// Solo cerrar sesión local cuando el refresh indica tokens inválidos, no por
  /// errores de red ni 400 genéricos (p. ej. bug de cabeceras).
  static bool _refreshFailureShouldLogout(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401) return true;
    if (code == 400) {
      final msg = _extractErrorMessage(e.response?.data).toLowerCase();
      if (msg.contains('inválido') || msg.contains('invalid')) return true;
      if (msg.contains('no encontrado')) return true;
    }
    return false;
  }

  /// El API exige `Authorization: Bearer` con el access token (aunque esté
  /// expirado) además del `refreshToken` en el body. El refresh rota el refresh.
  Future<String?> _refreshAccessToken() {
    if (_refreshCompleter != null) {
      return _refreshCompleter!.future;
    }
    final completer = Completer<String?>();
    _refreshCompleter = completer;

    Future<void> run() async {
      try {
        final refreshToken = await _storage.getRefreshToken();
        final accessToken = await _storage.getAuthToken();
        if (refreshToken == null ||
            refreshToken.isEmpty ||
            accessToken == null ||
            accessToken.isEmpty) {
          completer.complete(null);
          return;
        }
        final refreshDio = Dio(
          BaseOptions(
            baseUrl: ApiConstants.baseUrl,
            connectTimeout: ApiConstants.connectTimeout,
            receiveTimeout: ApiConstants.receiveTimeout,
          ),
        );
        final response = await refreshDio.post<dynamic>(
          ApiConstants.refresh,
          data: {'refreshToken': refreshToken},
          options: Options(
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
          ),
        );
        final map = _tryParseJsonObject(response.data);
        if (map == null) {
          completer.complete(null);
          return;
        }
        final newToken = _readStringKey(map, 'token');
        final newRefresh =
            _readStringKey(map, 'refreshToken') ?? refreshToken;
        if (newToken == null || newToken.isEmpty) {
          completer.complete(null);
          return;
        }
        await _storage.saveTokens(
          authToken: newToken,
          refreshToken: newRefresh,
        );
        await LocationTrackingService.updateToken(newToken);
        completer.complete(newToken);
      } on DioException catch (e) {
        if (kDebugMode) {
          debugPrint(
            '[DioClient] refresh falló: ${e.response?.statusCode} '
            '${_extractErrorMessage(e.response?.data)}',
          );
        }
        if (_refreshFailureShouldLogout(e)) {
          await _storage.clearAll();
        }
        completer.complete(null);
      } catch (_) {
        completer.complete(null);
      } finally {
        _refreshCompleter = null;
      }
    }

    run();
    return completer.future;
  }

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
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.sendTimeout) {
      return const ApiException('Tiempo de espera agotado. Verifica tu conexión');
    }
    if (err.type == DioExceptionType.connectionError) {
      return const ApiException(
        'No se pudo conectar con el servidor. Verifica tu conexión y la URL del API en .env',
      );
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
    Options? options,
  }) async {
    final response = await _dio.post<dynamic>(path, data: data, options: options);
    return fromJson != null ? fromJson(response.data) : response.data as T;
  }

  /// `FormData` con archivos: no usar Content-Type JSON global.
  Future<T> postMultipart<T>(
    String path, {
    required FormData formData,
    T Function(dynamic)? fromJson,
  }) async {
    final response = await _dio.post<dynamic>(
      path,
      data: formData,
      options: Options(contentType: null),
    );
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

  Future<T> delete<T>(
    String path, {
    dynamic data,
    T Function(dynamic)? fromJson,
  }) async {
    final response = await _dio.delete<dynamic>(path, data: data);
    return fromJson != null ? fromJson(response.data) : response.data as T;
  }
}

final dioClientProvider = Provider<DioClient>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return DioClient(storage);
});
