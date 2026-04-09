import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/dio_client.dart';
import '../../../core/api/api_constants.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/storage/secure_storage.dart';
import 'auth_models.dart';

class AuthRepository {
  final DioClient _client;
  final SecureStorage _storage;

  const AuthRepository(this._client, this._storage);

  Future<AuthUser> login(LoginRequest request) async {
    try {
      final response = await _client.post<Map<String, dynamic>>(
        ApiConstants.login,
        data: request.toJson(),
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
    } catch (e) {
      throw ApiException('Error al iniciar sesión: ${e.toString()}');
    }
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

  Future<void> logout() => _storage.clearAll();
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    ref.watch(dioClientProvider),
    ref.watch(secureStorageProvider),
  );
});
