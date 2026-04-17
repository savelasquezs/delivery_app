import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'delivery_app_release_manifest.dart';

/// GET del manifiesto sin autenticación; errores de red → null (no molestar).
class AppUpdateChecker {
  AppUpdateChecker({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static String? get manifestUrlFromEnv {
    final u = dotenv.env['DELIVERY_APP_UPDATE_MANIFEST_URL']?.trim();
    if (u == null || u.isEmpty) return null;
    return u;
  }

  Future<AppUpdateCheckResult?> check() async {
    final url = manifestUrlFromEnv;
    if (url == null) return null;

    final info = await PackageInfo.fromPlatform();
    final localBuild = int.tryParse(info.buildNumber) ?? 0;

    try {
      final res = await _dio.get<dynamic>(
        url,
        options: Options(
          responseType: ResponseType.json,
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      final data = res.data;
      if (data is! Map<String, dynamic>) return null;

      final manifest = DeliveryAppReleaseManifest.fromJson(data);
      final apkUri = resolveApkDownloadUri(url, manifest.apkUrl);
      if (apkUri == null) return null;

      if (!shouldOfferInAppUpdate(
        localBuild: localBuild,
        remoteBuildNumber: manifest.buildNumber,
        minimumBuild: manifest.minimumBuild,
      )) {
        return null;
      }

      final kind = updateKindFor(
        localBuild: localBuild,
        remoteBuildNumber: manifest.buildNumber,
        minimumBuild: manifest.minimumBuild,
      );

      return AppUpdateCheckResult(
        manifest: manifest,
        localBuild: localBuild,
        kind: kind,
        apkUri: apkUri,
      );
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
