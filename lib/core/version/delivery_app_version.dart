import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/api_constants.dart';

const deliveryAppUpdateRequiredCode = 'DELIVERY_APP_UPDATE_REQUIRED';
const deliveryAppVersionHeader = 'X-Delivery-App-Version';
const deliveryAppBuildHeader = 'X-Delivery-App-Build';
const deliveryAppPackageHeader = 'X-Delivery-App-Package';

class DeliveryAppVersionInfo {
  final String versionName;
  final int buildNumber;
  final String packageName;

  const DeliveryAppVersionInfo({
    required this.versionName,
    required this.buildNumber,
    required this.packageName,
  });

  factory DeliveryAppVersionInfo.fromPackageInfo(PackageInfo info) =>
      DeliveryAppVersionInfo(
        versionName: info.version,
        buildNumber: int.tryParse(info.buildNumber) ?? 0,
        packageName: kIsWeb ? 'com.senorarroz.delivery_app' : info.packageName,
      );

  Map<String, String> get headers => {
        deliveryAppVersionHeader: versionName,
        deliveryAppBuildHeader: buildNumber.toString(),
        deliveryAppPackageHeader: packageName,
      };
}

class DeliveryAppVersionInfoLoader {
  DeliveryAppVersionInfoLoader({Future<PackageInfo> Function()? load})
      : _load = load ?? PackageInfo.fromPlatform;

  final Future<PackageInfo> Function() _load;
  Future<DeliveryAppVersionInfo>? _cached;

  Future<DeliveryAppVersionInfo> get() =>
      _cached ??= _load().then(DeliveryAppVersionInfo.fromPackageInfo);

  Future<Map<String, String>> headers() async => (await get()).headers;
}

class DeliveryAppVersionPolicy {
  final String requiredVersion;
  final int minimumBuild;
  final String playStoreUrl;
  final bool updateRequired;

  const DeliveryAppVersionPolicy({
    required this.requiredVersion,
    required this.minimumBuild,
    required this.playStoreUrl,
    required this.updateRequired,
  });

  factory DeliveryAppVersionPolicy.fromJson(Map<String, dynamic> json) =>
      DeliveryAppVersionPolicy(
        requiredVersion:
            (json['requiredVersion'] ?? json['RequiredVersion'] ?? '')
                .toString(),
        minimumBuild: _toInt(json['minimumBuild'] ?? json['MinimumBuild']),
        playStoreUrl: (json['playStoreUrl'] ??
                json['PlayStoreUrl'] ??
                kDeliveryAppPlayStoreUrl)
            .toString(),
        updateRequired:
            json['updateRequired'] == true || json['UpdateRequired'] == true,
      );

  static int _toInt(dynamic value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '') ?? 0;
}

class DeliveryAppUpdateRequiredException implements Exception {
  final DeliveryAppVersionPolicy policy;

  const DeliveryAppUpdateRequiredException(this.policy);

  @override
  String toString() => 'Debes actualizar la aplicación para continuar.';
}

DeliveryAppVersionPolicy? deliveryAppUpdatePolicyFromResponse(
  int? statusCode,
  dynamic data,
) {
  if (statusCode != 426 || data is! Map) return null;
  final json = Map<String, dynamic>.from(data);
  final code = json['code'] ?? json['Code'];
  if (code != deliveryAppUpdateRequiredCode) return null;
  return DeliveryAppVersionPolicy.fromJson({
    ...json,
    'updateRequired': true,
  });
}

DeliveryAppUpdateRequiredException? deliveryAppUpdateFromError(Object error) {
  if (error is DeliveryAppUpdateRequiredException) return error;
  if (error is DioException &&
      error.error is DeliveryAppUpdateRequiredException) {
    return error.error! as DeliveryAppUpdateRequiredException;
  }
  return null;
}

final deliveryAppVersionInfoProvider = Provider<DeliveryAppVersionInfoLoader>(
  (_) => DeliveryAppVersionInfoLoader(),
);
