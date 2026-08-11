import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import '../../../core/api/dio_client.dart';
import '../../../core/api/api_constants.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/errors/user_facing_error.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/version/delivery_app_version.dart';
import 'auth_models.dart';

class AuthRepository {
  final DioClient _client;
  final SecureStorage _storage;

  const AuthRepository(this._client, this._storage);

  Future<DeliveryAppVersionPolicy> checkDeliveryAppVersion() =>
      _client.get<DeliveryAppVersionPolicy>(
        ApiConstants.deliveryAppVersion,
        fromJson: (data) => DeliveryAppVersionPolicy.fromJson(
          Map<String, dynamic>.from(data as Map),
        ),
      );

  Future<AuthUser> login(LoginRequest request) async {
    try {
      final installationId = await _storage.getOrCreateInstallationId();
      final response = await _client.post<Map<String, dynamic>>(
        ApiConstants.login,
        data: {
          ...request.toJson(),
          'deviceInstallationId': installationId,
        },
        fromJson: (data) => data as Map<String, dynamic>,
      );
      final loginResponse = LoginResponse.fromJson(response);

      if (!loginResponse.user.isDeliveryman) {
        throw const ApiException(
          'Solo domiciliarios pueden acceder a esta aplicación',
          statusCode: 403,
        );
      }

      await _storage.saveTokens(
        authToken: loginResponse.token,
        refreshToken: loginResponse.refreshToken,
      );
      await _storage.saveUserData(
        jsonEncode(loginResponse.user.toJson()),
      );

      return loginResponse.user;
    } on ApiException {
      rethrow;
    } on DioException catch (error) {
      final update = deliveryAppUpdateFromError(error);
      if (update != null) throw update;
      if (error.error is ApiException) throw error.error! as ApiException;
      throw ApiException(
        userFacingErrorMessage(
          error,
          fallback: 'No pudimos iniciar sesión. Inténtalo de nuevo.',
        ),
      );
    } catch (e) {
      throw ApiException(
        userFacingErrorMessage(
          e,
          fallback: 'No pudimos iniciar sesión. Inténtalo de nuevo.',
        ),
      );
    }
  }

  Future<void> persistUser(AuthUser user) async {
    await _storage.saveUserData(jsonEncode(user.toJson()));
  }

  Future<AuthUser?> getStoredUser() async {
    final jsonData = await _storage.getUserData();
    if (jsonData == null) return null;
    try {
      return AuthUser.fromJson(jsonDecode(jsonData) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasValidSession() async {
    final token = await _storage.getAuthToken();
    final user = await getStoredUser();
    return token != null && user != null && user.isDeliveryman;
  }

  Future<String?> getStoredAccessToken() => _storage.getAuthToken();

  Future<void> forgotPassword(String email) async {
    try {
      await _client.post<void>(
        ApiConstants.forgotPassword,
        data: {'email': email},
        fromJson: (_) {},
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(
        userFacingErrorMessage(
          e,
          fallback: 'No pudimos enviar el correo. Inténtalo de nuevo.',
        ),
      );
    }
  }

  Future<void> logout() async {
    final refreshToken = await _storage.getRefreshToken();
    try {
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await _client.post<void>(
          ApiConstants.logout,
          data: {'refreshToken': refreshToken},
          fromJson: (_) {},
        );
      }
    } finally {
      await _storage.clearAll();
    }
  }

  Future<void> clearLocalSession() => _storage.clearAll();
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    ref.watch(dioClientProvider),
    ref.watch(secureStorageProvider),
  );
});
