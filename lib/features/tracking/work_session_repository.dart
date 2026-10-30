import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:dio/dio.dart';

import '../../core/api/api_constants.dart';
import '../../core/auth/session_refresh.dart';
import '../../core/api/dio_client.dart';
import '../../core/storage/secure_storage.dart';
import 'work_session_models.dart';

class WorkSessionRepository {
  final DioClient _client;
  final SecureStorage _storage;

  const WorkSessionRepository(this._client, this._storage);

  Future<DeliveryWorkSession> startOrResume() async {
    final auth = await _storage.readSession();
    if (auth == null) throw const SessionEndedException();
    final installationId = await _storage.getOrCreateInstallationId();
    final package = await PackageInfo.fromPlatform();
    try {
      final response = await _client.post<Map<String, dynamic>>(
        ApiConstants.myWorkSession,
        options: Options(extra: {'_sessionId': auth.id}),
        data: {
          'deviceInstallationId': installationId,
          'devicePlatform': kIsWeb ? 'web' : Platform.operatingSystem,
          'deviceDescription': kIsWeb
              ? 'Navegador de desarrollo'
              : Platform.operatingSystemVersion,
          'appVersion': '${package.version}+${package.buildNumber}',
        },
        fromJson: (data) => Map<String, dynamic>.from(data as Map),
      );
      final session = DeliveryWorkSession.fromJson(response);
      if (!await _storage.updateWorkSessionData(
          jsonEncode(session.toJson()), auth.id))
        throw const SessionEndedException();
      return session;
    } on DioException catch (error) {
      final stored = await getStored();
      if (isTransientSessionFailure(error) &&
          stored != null &&
          stored.isActive &&
          DateTime.now().toUtc().isBefore(stored.autoCloseAt)) {
        return stored;
      }
      rethrow;
    }
  }

  Future<DeliveryWorkSession?> current() async {
    final auth = await _storage.readSession();
    if (auth == null) throw const SessionEndedException();
    DeliveryWorkSession? result;
    try {
      result = await _client.get<DeliveryWorkSession?>(
          ApiConstants.myWorkSession,
          options: Options(extra: {'_sessionId': auth.id}),
          fromJson: (value) => value == null || value == ''
              ? null
              : DeliveryWorkSession.fromJson(
                  Map<String, dynamic>.from(value as Map)));
    } on DioException catch (error) {
      final cached = await getStored();
      if (isTransientSessionFailure(error) &&
          (await _storage.readSession())?.id == auth.id &&
          cached != null &&
          cached.isActive &&
          DateTime.now().toUtc().isBefore(cached.autoCloseAt)) return cached;
      rethrow;
    }
    if (!await _storage.updateWorkSessionData(
        result == null ? null : jsonEncode(result.toJson()), auth.id))
      throw const SessionEndedException();
    return result;
  }

  Future<DeliveryWorkSession?> getStored() async {
    final value = await _storage.getWorkSessionData();
    if (value == null) return null;
    try {
      return DeliveryWorkSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(value) as Map),
      );
    } catch (_) {
      await _storage.deleteWorkSessionData();
      return null;
    }
  }

  Future<void> closeCurrent({String? expectedSessionId}) async {
    final auth = await _storage.readSession();
    if (auth == null ||
        expectedSessionId != null && auth.id != expectedSessionId) return;
    await _client.closeSessionResource(
      ApiConstants.myWorkSession,
      method: 'DELETE',
      sessionId: auth.id,
      requireSuccess: true,
    );
    await _storage.updateWorkSessionData(null, auth.id);
  }

  Future<void> clearLocal() => _storage.deleteWorkSessionData();
}

final workSessionRepositoryProvider = Provider<WorkSessionRepository>((ref) {
  return WorkSessionRepository(
    ref.watch(dioClientProvider),
    ref.watch(secureStorageProvider),
  );
});
