import 'package:delivery_app/core/updates/delivery_app_release_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveApkDownloadUri', () {
    test('URL absoluta se devuelve tal cual', () {
      final u = resolveApkDownloadUri(
        'https://example.com/delivery-app-release.json',
        'https://cdn.example.com/app.apk',
      );
      expect(u.toString(), 'https://cdn.example.com/app.apk');
    });

    test('ruta absoluta usa el origin del manifiesto', () {
      final u = resolveApkDownloadUri(
        'https://example.com/public/delivery-app-release.json',
        '/senor-arroz-domiciliarios.apk',
      );
      expect(u.toString(), 'https://example.com/senor-arroz-domiciliarios.apk');
    });

    test('relativa sin slash', () {
      final u = resolveApkDownloadUri(
        'https://example.com/a/b/delivery-app-release.json',
        'files/app.apk',
      );
      expect(u.toString(), 'https://example.com/a/b/files/app.apk');
    });
  });

  group('shouldOfferInAppUpdate', () {
    test('nuevo build remoto', () {
      expect(
        shouldOfferInAppUpdate(
          localBuild: 3,
          remoteBuildNumber: 4,
          minimumBuild: 1,
        ),
        isTrue,
      );
    });

    test('mismo build y cumple mínimo', () {
      expect(
        shouldOfferInAppUpdate(
          localBuild: 5,
          remoteBuildNumber: 5,
          minimumBuild: 1,
        ),
        isFalse,
      );
    });

    test('local bajo minimumBuild aunque remote igual', () {
      expect(
        shouldOfferInAppUpdate(
          localBuild: 2,
          remoteBuildNumber: 5,
          minimumBuild: 4,
        ),
        isTrue,
      );
    });
  });

  group('DeliveryAppReleaseManifest.fromJson', () {
    test('parseo típico', () {
      final m = DeliveryAppReleaseManifest.fromJson({
        'versionName': '1.2.0',
        'buildNumber': 10,
        'apkFileName': 'x.apk',
        'apkUrl': '/x.apk',
        'minimumBuild': 3,
        'message': 'Notas',
      });
      expect(m.versionName, '1.2.0');
      expect(m.buildNumber, 10);
      expect(m.apkUrl, '/x.apk');
      expect(m.minimumBuild, 3);
      expect(m.message, 'Notas');
    });
  });

  group('updateKindFor', () {
    test('forced si bajo mínimo', () {
      expect(
        updateKindFor(
          localBuild: 1,
          remoteBuildNumber: 5,
          minimumBuild: 3,
        ),
        AppUpdateKind.forced,
      );
    });

    test('optional si solo hay build nuevo', () {
      expect(
        updateKindFor(
          localBuild: 3,
          remoteBuildNumber: 5,
          minimumBuild: 1,
        ),
        AppUpdateKind.optional,
      );
    });
  });
}
