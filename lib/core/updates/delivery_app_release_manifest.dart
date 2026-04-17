/// Manifiesto alineado con [senorArrozFront/public/delivery-app-release.json].
class DeliveryAppReleaseManifest {
  final String versionName;
  final int buildNumber;
  final String? apkFileName;
  final String apkUrl;
  final int minimumBuild;
  final String? message;

  const DeliveryAppReleaseManifest({
    required this.versionName,
    required this.buildNumber,
    this.apkFileName,
    required this.apkUrl,
    required this.minimumBuild,
    this.message,
  });

  factory DeliveryAppReleaseManifest.fromJson(Map<String, dynamic> json) {
    final build = json['buildNumber'];
    final minB = json['minimumBuild'];
    return DeliveryAppReleaseManifest(
      versionName: json['versionName'] as String? ?? '',
      buildNumber: build is int ? build : (build as num?)?.toInt() ?? 0,
      apkFileName: json['apkFileName'] as String?,
      apkUrl: json['apkUrl'] as String? ?? '',
      minimumBuild: minB is int ? minB : (minB as num?)?.toInt() ?? 0,
      message: json['message'] as String?,
    );
  }
}

/// Resuelve la URL de descarga del APK: absoluta tal cual, o relativa al origin del manifiesto.
Uri? resolveApkDownloadUri(String manifestUrl, String apkUrlFromJson) {
  final raw = apkUrlFromJson.trim();
  if (raw.isEmpty) return null;
  final lower = raw.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return Uri.tryParse(raw);
  }
  final base = Uri.tryParse(manifestUrl);
  if (base == null) return null;
  if (raw.startsWith('/')) {
    return base.replace(path: raw, query: null, fragment: null);
  }
  return base.resolve(raw);
}

enum AppUpdateKind { optional, forced }

class AppUpdateCheckResult {
  final DeliveryAppReleaseManifest manifest;
  final int localBuild;
  final AppUpdateKind kind;
  final Uri apkUri;

  const AppUpdateCheckResult({
    required this.manifest,
    required this.localBuild,
    required this.kind,
    required this.apkUri,
  });
}

/// `true` si debe mostrarse aviso: hay build más nuevo o el mínimo obligatorio no se cumple.
bool shouldOfferInAppUpdate({
  required int localBuild,
  required int remoteBuildNumber,
  required int minimumBuild,
}) {
  final belowMinimum = minimumBuild > 0 && localBuild < minimumBuild;
  final newerAvailable = remoteBuildNumber > localBuild;
  return belowMinimum || newerAvailable;
}

AppUpdateKind updateKindFor({
  required int localBuild,
  required int remoteBuildNumber,
  required int minimumBuild,
}) {
  final belowMinimum = minimumBuild > 0 && localBuild < minimumBuild;
  if (belowMinimum) return AppUpdateKind.forced;
  return AppUpdateKind.optional;
}
