import 'dart:math';
import 'dart:convert';

import 'package:uuid/uuid.dart';
import '../auth/session_mutex.dart';
import '../auth/token_session.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _kTokenSession = 'auth_session_v2';
const _kAuthToken = 'auth_token';
const _kRefreshToken = 'refresh_token';
const _kUserData = 'user_data';
const _kInstallationId = 'installation_id';
const _kWorkSessionData = 'work_session_data';

class SecureStorage {
  final FlutterSecureStorage _storage;
  final SessionMutex _mutex;
  final SessionLease? _lease;

  SecureStorage({SessionMutex? mutex})
      : _mutex = mutex ?? SessionMutex.shared,
        _lease = null,
        _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );

  SecureStorage._locked(this._storage, this._mutex, this._lease);

  Future<T> withSessionLock<T>(Future<T> Function(SecureStorage) body) async {
    if (_lease != null) {
      await _lease!.ensureOwned();
      return body(this);
    }
    return _mutex.protect(
        (lease) => body(SecureStorage._locked(_storage, _mutex, lease)));
  }

  Future<TokenSession?> readSession() => withSessionLock((store) async {
        final value = await _storage.read(key: _kTokenSession);
        if (value != null) {
          return TokenSession.fromJson(
              Map<String, dynamic>.from(jsonDecode(value) as Map));
        }
        final access = await _storage.read(key: _kAuthToken);
        final refresh = await _storage.read(key: _kRefreshToken);
        if (access == null || refresh == null) return null;
        final session = TokenSession(
            id: const Uuid().v4(), accessToken: access, refreshToken: refresh);
        await store.writeSession(session);
        return session;
      });

  Future<String?> getAuthToken() async => (await readSession())?.accessToken;
  Future<String?> getRefreshToken() async =>
      (await readSession())?.refreshToken;
  Future<String?> getUserData() => _storage.read(key: _kUserData);

  /// The pair and session generation are committed as one encrypted value.
  Future<void> writeSession(TokenSession session) =>
      withSessionLock((store) async {
        await store._lease!.ensureOwned();
        await _storage.write(
            key: _kTokenSession, value: jsonEncode(session.toJson()));
        // Legacy cleanup cannot turn a successful rotating-pair write into failure.
        try {
          await _storage.delete(key: _kAuthToken);
          await _storage.delete(key: _kRefreshToken);
        } catch (_) {}
      });

  Future<void> saveTokens(
          {required String authToken, required String refreshToken}) =>
      writeSession(TokenSession(
          id: const Uuid().v4(),
          accessToken: authToken,
          refreshToken: refreshToken));

  Future<void> saveUserData(String jsonData) =>
      _storage.write(key: _kUserData, value: jsonData);

  /// Removes a credential retained by older releases of the assignment flow.
  Future<void> deleteObsoleteSelfAssignPassword() =>
      _storage.delete(key: 'self_assign_password');

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

  Future<void> clearAll() => withSessionLock((store) async {
        await store._lease!.ensureOwned();
        final installationId = await _storage.read(key: _kInstallationId);
        await _storage.deleteAll();
        if (installationId != null && installationId.isNotEmpty) {
          await _storage.write(key: _kInstallationId, value: installationId);
        }
      });
}

final secureStorageProvider = Provider<SecureStorage>((_) => SecureStorage());
