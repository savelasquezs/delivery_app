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

  Future<AuthUser?> getAuthenticatedUser() async {
    final token = await _storage.getAuthToken();
    if (token == null) return null;
    final user = await getStoredUser();
    return user?.isDeliveryman == true ? user : null;
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

  Future<String?> getStoredSessionId() async =>
      (await _storage.readSession())?.id;

  Future<void> logout({String? expectedSessionId}) async {
    final session = await _storage.readSession();
    if (expectedSessionId != null && session?.id != expectedSessionId) {
      return;
    }
    if (session != null) {
      await _client.closeSessionResource(
        ApiConstants.logout,
        sessionId: session.id,
        data: {'refreshToken': session.refreshToken},
        requireSuccess: true,
      );
    }
    await _storage.withSessionLock((locked) async {
      if ((await locked.readSession())?.id == session?.id) {
        await locked.clearAll();
      }
    });
  }

  Future<void> clearLocalSession() => _storage.clearAll();
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    ref.watch(dioClientProvider),
    ref.watch(secureStorageProvider),
  );
});
