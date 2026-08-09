import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/api_constants.dart';
import 'delivery_app_release_manifest.dart';

/// GET del manifiesto sin autenticación; errores de red → null (no molestar).
class AppUpdateChecker {
  AppUpdateChecker({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<AppUpdateCheckResult?> check() async {
    final url = ApiConstants.deliveryAppUpdateManifestUrl;

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
      final apkUri = resolveApkDownloadUri(url, manifest.apkUrl) ??
          Uri.parse(kPlayStoreUrl);

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
        updateUri: kPlayDistribution ? Uri.parse(kPlayStoreUrl) : apkUri,
      );
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
