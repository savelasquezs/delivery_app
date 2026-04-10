import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_constants.dart';
import '../../../core/api/dio_client.dart';
import '../../auth/data/auth_models.dart';

class UserProfileRepository {
  final DioClient _client;

  const UserProfileRepository(this._client);

  Future<Map<String, dynamic>> fetchUser(int id) async {
    return _client.get<Map<String, dynamic>>(
      ApiConstants.userById(id),
      fromJson: (data) => data as Map<String, dynamic>,
    );
  }

  Future<AuthUser> updateProfile({
    required int userId,
    required String email,
    required String phone,
    required AuthUser current,
  }) async {
    final data = await _client.put<Map<String, dynamic>>(
      ApiConstants.userProfile(userId),
      data: {'email': email.trim(), 'phone': phone.trim()},
      fromJson: (d) => d as Map<String, dynamic>,
    );
    return AuthUser.fromUserApi(data, current);
  }

  Future<AuthUser> uploadProfileImage({
    required int userId,
    required File file,
    required AuthUser current,
  }) async {
    final fileName = file.path.split(Platform.pathSeparator).last;
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(file.path, filename: fileName),
    });
    final data = await _client.postMultipart<Map<String, dynamic>>(
      ApiConstants.userProfileImage(userId),
      formData: formData,
      fromJson: (d) => d as Map<String, dynamic>,
    );
    return AuthUser.fromUserApi(data, current);
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {
    await _client.post<void>(
      ApiConstants.authChangePassword,
      data: {
        'currentPassword': currentPassword,
        'newPassword': newPassword,
        'confirmPassword': confirmPassword,
      },
      fromJson: (_) {},
    );
  }
}

final userProfileRepositoryProvider = Provider<UserProfileRepository>((ref) {
  return UserProfileRepository(ref.watch(dioClientProvider));
});
