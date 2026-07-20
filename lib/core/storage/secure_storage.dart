import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _kAuthToken = 'auth_token';
const _kRefreshToken = 'refresh_token';
const _kUserData = 'user_data';
const _kSelfAssignPassword = 'self_assign_password';
const _kInstallationId = 'installation_id';
const _kWorkSessionData = 'work_session_data';

class SecureStorage {
  final FlutterSecureStorage _storage;

  SecureStorage()
      : _storage = const FlutterSecureStorage(
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

  Future<String?> getSelfAssignPassword() =>
      _storage.read(key: _kSelfAssignPassword);

  Future<void> saveSelfAssignPassword(String password) =>
      _storage.write(key: _kSelfAssignPassword, value: password);

  Future<void> deleteSelfAssignPassword() =>
      _storage.delete(key: _kSelfAssignPassword);

  Future<String> getOrCreateInstallationId() async {
    final existing = await _storage.read(key: _kInstallationId);
    if (existing != null && existing.isNotEmpty) return existing;

    final random = Random.secure();
    final id =
        List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
    await _storage.write(key: _kInstallationId, value: id);
    return id;
  }

  Future<String?> getWorkSessionData() => _storage.read(key: _kWorkSessionData);

  Future<void> saveWorkSessionData(String jsonData) =>
      _storage.write(key: _kWorkSessionData, value: jsonData);

  Future<void> deleteWorkSessionData() =>
      _storage.delete(key: _kWorkSessionData);

  Future<void> clearAll() async {
    final installationId = await _storage.read(key: _kInstallationId);
    await _storage.deleteAll();
    if (installationId != null && installationId.isNotEmpty) {
      await _storage.write(key: _kInstallationId, value: installationId);
    }
  }
}

final secureStorageProvider = Provider<SecureStorage>((_) => SecureStorage());
