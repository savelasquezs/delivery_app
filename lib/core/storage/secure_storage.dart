import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _kAuthToken = 'auth_token';
const _kRefreshToken = 'refresh_token';
const _kUserData = 'user_data';

class SecureStorage {
  final FlutterSecureStorage _storage;

  SecureStorage() : _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String?> getAuthToken() => _storage.read(key: _kAuthToken);
  Future<String?> getRefreshToken() => _storage.read(key: _kRefreshToken);
  Future<String?> getUserData() => _storage.read(key: _kUserData);

  Future<void> saveTokens({
    required String authToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _kAuthToken, value: authToken);
    await _storage.write(key: _kRefreshToken, value: refreshToken);
  }

  Future<void> saveUserData(String jsonData) =>
      _storage.write(key: _kUserData, value: jsonData);

  Future<void> clearAll() => _storage.deleteAll();
}

final secureStorageProvider = Provider<SecureStorage>((_) => SecureStorage());
