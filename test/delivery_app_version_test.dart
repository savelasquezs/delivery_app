import 'dart:convert';
import 'package:delivery_app/core/auth/token_session.dart';
import 'dart:typed_data';

import 'package:delivery_app/core/api/dio_client.dart';
import 'package:delivery_app/core/api/refresh_access_result.dart';
import 'package:delivery_app/core/router/app_router.dart';
import 'package:delivery_app/core/storage/secure_storage.dart';
import 'package:delivery_app/core/theme/app_theme.dart';
import 'package:delivery_app/core/version/delivery_app_version.dart';
import 'package:delivery_app/features/auth/presentation/auth_notifier.dart';
import 'package:delivery_app/features/auth/presentation/delivery_app_update_required_screen.dart';
import 'package:delivery_app/features/auth/data/auth_repository.dart';
import 'package:delivery_app/features/auth/data/auth_models.dart';
import 'package:delivery_app/features/tracking/work_session_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUp(() {
    dotenv.testLoad(fileInput: 'API_BASE_URL=https://api.example.com/api');
  });

  test('extracts PackageInfo once and creates version headers', () async {
    var loads = 0;
    final loader = DeliveryAppVersionInfoLoader(load: () async {
      loads++;
      return PackageInfo(
        appName: 'Señor Arroz',
        packageName: 'com.senorarroz.delivery_app',
        version: '1.2.5',
        buildNumber: '15',
      );
    });

    final info = await loader.get();
    final headers = await loader.headers();

    expect(info.versionName, '1.2.5');
    expect(info.buildNumber, 15);
    expect(headers[deliveryAppVersionHeader], '1.2.5');
    expect(headers[deliveryAppBuildHeader], '15');
    expect(
      headers[deliveryAppPackageHeader],
      'com.senorarroz.delivery_app',
    );
    expect(loads, 1);
  });

  test('426 clears tokens and disables later refresh attempts', () async {
    final storage = _FakeSecureStorage();
    final adapter = _UpdateRequiredAdapter();
    final client = DioClient(
      storage,
      _versionLoader(),
      onUpdateRequiredCleanup: () async {},
    );
    client.dio.httpClientAdapter = adapter;

    await expectLater(
      client.get<Object>('/orders'),
      throwsA(
        isA<DioException>().having(
          (error) => error.error,
          'typed update error',
          isA<DeliveryAppUpdateRequiredException>(),
        ),
      ),
    );

    expect(storage.clearCount, 1);
    expect(adapter.calls, 1);
    expect(adapter.lastHeaders?[deliveryAppVersionHeader], '1.2.5');
    expect(adapter.lastHeaders?[deliveryAppBuildHeader], '11');
    expect(
      await client.silentRefreshAccessToken(),
      isA<RefreshAccessUpdateRequired>(),
    );
    expect(adapter.calls, 1);
  });

  test('update-required status always redirects to mandatory screen', () {
    expect(
      deliveryAuthRedirect(AuthStatus.updateRequired, '/login'),
      routeUpdateRequired,
    );
    expect(
      deliveryAuthRedirect(AuthStatus.updateRequired, '/'),
      routeUpdateRequired,
    );
    expect(
      deliveryAuthRedirect(AuthStatus.updateRequired, routeUpdateRequired),
      isNull,
    );
  });

  test('startup incompatibility clears a stored session despite concurrent local reads',
      () async {
    final storage = _FakeSecureStorage();
    final client = DioClient(storage, _versionLoader());
    final repository = _StartupAuthRepository(client, storage);
    final workSessions = _StartupWorkSessionRepository(client, storage);
    var trackingCleanupCount = 0;
    final notifier = AuthNotifier(
      repository,
      workSessions,
      client,
      onUpdateRequiredCleanup: () async => trackingCleanupCount++,
    );

    for (var i = 0;
        i < 20 && notifier.state.status != AuthStatus.updateRequired;
        i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(notifier.state.status, AuthStatus.updateRequired);
    expect(notifier.state.updatePolicy?.requiredVersion, '1.2.5');
    expect(repository.clearCount, 1);
    expect(workSessions.clearCount, 1);
    expect(trackingCleanupCount, 1);
    expect(notifier.state.status, AuthStatus.updateRequired);
    notifier.dispose();
  });

  testWidgets('mandatory screen only offers Google Play update',
      (tester) async {
    const policy = DeliveryAppVersionPolicy(
      requiredVersion: '1.2.5',
      minimumBuild: 11,
      playStoreUrl:
          'https://play.google.com/store/apps/details?id=com.senorarroz.delivery_app',
      updateRequired: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const DeliveryAppUpdateRequiredScreen(policy: policy),
        ),
      ),
    );

    expect(find.text('Actualización necesaria'), findsOneWidget);
    expect(find.text('Actualizar en Google Play'), findsOneWidget);
    expect(find.text('Más tarde'), findsNothing);
    expect(find.textContaining('Descargar'), findsNothing);
  });
}

DeliveryAppVersionInfoLoader _versionLoader() =>
    DeliveryAppVersionInfoLoader(load: () async {
      return PackageInfo(
        appName: 'Señor Arroz',
        packageName: 'com.senorarroz.delivery_app',
        version: '1.2.5',
        buildNumber: '11',
      );
    });

class _FakeSecureStorage extends SecureStorage {
  int clearCount = 0;

  @override
  Future<TokenSession?> readSession() async => const TokenSession(
      id: 'version-test',
      accessToken: 'access-token',
      refreshToken: 'refresh-token');

  @override
  Future<String?> getAuthToken() async => 'access-token';

  @override
  Future<String?> getRefreshToken() async => 'refresh-token';

  @override
  Future<void> clearAll() async {
    clearCount++;
  }
}

class _UpdateRequiredAdapter implements HttpClientAdapter {
  int calls = 0;
  Map<String, dynamic>? lastHeaders;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    lastHeaders = options.headers;
    return ResponseBody.fromString(
      jsonEncode({
        'code': deliveryAppUpdateRequiredCode,
        'message': 'Debes actualizar la aplicación para continuar.',
        'requiredVersion': '1.2.5',
        'minimumBuild': 11,
        'playStoreUrl':
            'https://play.google.com/store/apps/details?id=com.senorarroz.delivery_app',
      }),
      426,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _StartupAuthRepository extends AuthRepository {
  _StartupAuthRepository(super.client, super.storage);

  int clearCount = 0;
  bool sessionRestoreAttempted = false;

  @override
  Future<DeliveryAppVersionPolicy> checkDeliveryAppVersion() async =>
      const DeliveryAppVersionPolicy(
        requiredVersion: '1.2.5',
        minimumBuild: 11,
        playStoreUrl:
            'https://play.google.com/store/apps/details?id=com.senorarroz.delivery_app',
        updateRequired: true,
      );

  @override
  Future<AuthUser?> getAuthenticatedUser() async {
    sessionRestoreAttempted = true;
    return null;
  }

  @override
  Future<void> clearLocalSession() async {
    clearCount++;
  }
}

class _StartupWorkSessionRepository extends WorkSessionRepository {
  _StartupWorkSessionRepository(super.client, super.storage);

  int clearCount = 0;

  @override
  Future<void> clearLocal() async {
    clearCount++;
  }
}
