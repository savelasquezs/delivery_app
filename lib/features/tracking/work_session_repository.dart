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
    final installationId = await _storage.getOrCreateInstallationId();
    final package = await PackageInfo.fromPlatform();
    try {
      final response = await _client.post<Map<String, dynamic>>(
        ApiConstants.myWorkSession,
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
      await _storage.saveWorkSessionData(jsonEncode(session.toJson()));
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

  Future<void> closeCurrent() async {
    try {
      await _client.delete<void>(
        ApiConstants.myWorkSession,
        fromJson: (_) {},
      );
    } finally {
      await _storage.deleteWorkSessionData();
    }
  }

  Future<void> clearLocal() => _storage.deleteWorkSessionData();
}

final workSessionRepositoryProvider = Provider<WorkSessionRepository>((ref) {
  return WorkSessionRepository(
    ref.watch(dioClientProvider),
    ref.watch(secureStorageProvider),
  );
});
