import 'dart:async';
import 'dart:convert';

import 'package:delivery_app/core/api/dio_client.dart';
import 'package:delivery_app/core/storage/secure_storage.dart';
import 'package:delivery_app/core/version/delivery_app_version.dart';
import 'package:delivery_app/features/auth/data/auth_models.dart';
import 'package:delivery_app/features/auth/data/auth_repository.dart';
import 'package:delivery_app/features/auth/presentation/auth_notifier.dart';
import 'package:delivery_app/features/tracking/location_tracking_policy.dart';
import 'package:delivery_app/features/tracking/work_session_models.dart';
import 'package:delivery_app/features/tracking/work_session_repository.dart';
import 'package:dio/dio.dart';
import 'package:delivery_app/core/auth/token_session.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _driver = AuthUser(
  id: 9,
  name: 'Courier',
  email: 'courier@example.invalid',
  role: 'deliveryman',
  branchId: 1,
);

String _jwt() {
  final expiration =
      DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch ~/
          1000;
  final encoded = base64Url
      .encode(utf8.encode(jsonEncode({'exp': expiration})))
      .replaceAll('=', '');
  return 'header.$encoded.signature';
}

DeliveryWorkSession _activeSession() {
  final now = DateTime.now().toUtc();
  return DeliveryWorkSession(
    id: 123,
    deliverymanId: _driver.id,
    branchId: 1,
    deviceInstallationId: 'test-device',
    status: 'Active',
    startedAt: now.subtract(const Duration(minutes: 5)),
    autoCloseAt: now.add(const Duration(hours: 6)),
    lastCommunicationAt: now,
    tracking: const DeliveryTrackingConfiguration(
      autoCloseTime: '21:00',
      lightIntervalSeconds: 300,
      activeIntervalSeconds: 30,
      stayThresholdMinutes: 10,
      stayRadiusMeters: 20,
      allowedDistanceMeters: 50,
      locationRetentionDays: 3,
      incidentRetentionDays: 15,
    ),
  );
}

class _SessionStore extends SecureStorage {
  String? cached = 'old work session';
  @override
  Future<TokenSession?> readSession() async => const TokenSession(
      id: 'current-login', accessToken: 'token', refreshToken: 'refresh');
  @override
  Future<bool> updateWorkSessionData(
      String? value, String expectedSessionId) async {
    expect(expectedSessionId, 'current-login');
    cached = value;
    return true;
  }
}

class _AuthRepo extends AuthRepository {
  _AuthRepo(super.client, super.storage);
  @override
  Future<DeliveryAppVersionPolicy> checkDeliveryAppVersion() async =>
      const DeliveryAppVersionPolicy(
        requiredVersion: '1.2.5',
        minimumBuild: 23,
        playStoreUrl: 'https://example.invalid/play',
        updateRequired: false,
      );
  @override
  Future<AuthUser?> getAuthenticatedUser() async => _driver;
  @override
  Future<String?> getStoredAccessToken() async => _jwt();
  @override
  Future<AuthUser?> getStoredUser() async => _driver;
}

class _WorkRepo extends WorkSessionRepository {
  _WorkRepo(super.client, super.storage);
  final DeliveryWorkSession session = _activeSession();
  @override
  Future<DeliveryWorkSession?> getStored() async => session;
  @override
  Future<DeliveryWorkSession> startOrResume() async => session;
  @override
  Future<DeliveryWorkSession?> current() async => session;
  @override
  Future<void> clearLocal() async {}
}

class _LogoutRepo extends _AuthRepo {
  _LogoutRepo(super.client, super.storage);
  int attempts = 0;
  int? rejectionStatus;
  @override
  Future<String?> getStoredSessionId() async => 'login-a';
  @override
  Future<void> logout({String? expectedSessionId}) async {
    attempts++;
    final request = RequestOptions(path: '/auth/logout');
    throw DioException(
        requestOptions: request,
        type: rejectionStatus == null
            ? DioExceptionType.connectionError
            : DioExceptionType.badResponse,
        response: rejectionStatus == null
            ? null
            : Response(
                requestOptions: request,
                statusCode: rejectionStatus,
                data: {
                    'message':
                        'Entrega o reasigna todos tus pedidos pendientes antes de cerrar sesión.'
                  }));
  }
}

class _DelayedVersionRepo extends _AuthRepo {
  _DelayedVersionRepo(super.client, super.storage);
  final first = Completer<DeliveryAppVersionPolicy>();
  int checks = 0;
  int clears = 0;

  @override
  Future<DeliveryAppVersionPolicy> checkDeliveryAppVersion() =>
      checks++ == 0 ? first.future : super.checkDeliveryAppVersion();

  @override
  Future<void> clearLocalSession() async => clears++;
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var i = 0; i < 150 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    dotenv.testLoad(fileInput: 'API_BASE_URL=https://api.example.invalid/api');
  });

  DioClient client() => DioClient(
        SecureStorage(),
        DeliveryAppVersionInfoLoader(
            load: () async => PackageInfo(
                  appName: 'Señor Arroz',
                  packageName: 'com.senorarroz.delivery_app',
                  version: '1.2.5',
                  buildNumber: '24',
                )),
      );

  for (final rejectionStatus in [null, 400]) {
    test('rejected logout retains Home and tracking; status=$rejectionStatus',
        () async {
      SharedPreferences.setMockInitialValues({});
      final dio = client();
      final repository = _LogoutRepo(dio, SecureStorage())
        ..rejectionStatus = rejectionStatus;
      final notifier = AuthNotifier(
          repository, _WorkRepo(dio, SecureStorage()), dio,
          permissionReader: () async => const LocationPermissionState(
              serviceEnabled: true,
              permission: LocationPermission.always,
              accuracy: LocationAccuracyStatus.precise),
          registerFcm: () async {},
          isTrackingRunning: () async => true,
          trackingStarter: (
              {required authToken,
              required baseUrl,
              required workSession,
              required versionName,
              required buildNumber,
              required packageName}) async {},
          trackingStopper: (
              {required recordEvent, required discardPending}) async {
            expect(discardPending, isFalse);
          });
      addTearDown(notifier.dispose);
      await _waitFor(() => notifier.state.trackingActive);
      await notifier.logout();
      expect(repository.attempts, 1);
      expect(notifier.state.status, AuthStatus.authenticated);
      expect(notifier.state.trackingActive, isTrue);
      expect(notifier.state.user?.id, _driver.id);
      expect(notifier.state.errorMessage, isNotEmpty);
      if (rejectionStatus != null)
        expect(notifier.state.errorMessage, contains('pedidos pendientes'));
    });
  }
  test(
      'absent work session accepts the empty HTTP 204 body and clears stale cache',
      () async {
    final storage = _SessionStore();
    final dio = DioClient(
        storage,
        DeliveryAppVersionInfoLoader(
            load: () async => PackageInfo(
                appName: 'Delivery',
                packageName: 'delivery',
                version: '1',
                buildNumber: '1')));
    dio.dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
            Response(requestOptions: options, statusCode: 204, data: ''))));
    expect(await WorkSessionRepository(dio, storage).current(), isNull);
    expect(storage.cached, isNull);
  });

  test(
      'version HTTP does not block restore or preparation and still enforces an update',
      () async {
    final dio = client();
    final repository = _DelayedVersionRepo(dio, SecureStorage());
    final notifier = AuthNotifier(
        repository, _WorkRepo(dio, SecureStorage()), dio,
        onUpdateRequiredCleanup: () async {},
        registerFcm: () async {},
        permissionReader: () async => const LocationPermissionState(
            serviceEnabled: true,
            permission: LocationPermission.always,
            accuracy: LocationAccuracyStatus.precise),
        isTrackingRunning: () async => true,
        trackingStarter: (
            {required authToken,
            required baseUrl,
            required workSession,
            required versionName,
            required buildNumber,
            required packageName}) async {});
    addTearDown(notifier.dispose);
    await _waitFor(() => notifier.state.status == AuthStatus.authenticated);
    await _waitFor(() => repository.checks == 1);
    expect(notifier.state.user?.id, _driver.id);
    await _waitFor(() => notifier.state.trackingActive);
    expect(await notifier.canBeginDelivery(), isTrue);
    expect(repository.clears, 0);
    repository.first.complete(const DeliveryAppVersionPolicy(
        requiredVersion: '99.0.0',
        minimumBuild: 999,
        playStoreUrl: 'https://example.invalid/play',
        updateRequired: true));
    await _waitFor(() => notifier.state.status == AuthStatus.updateRequired);
    expect(repository.clears, 1);
  });

  test('restoring a verified session does not await a blocked Android service',
      () async {
    final dio = client();
    final started = Completer<void>();
    var calls = 0;
    final notifier = AuthNotifier(
      _AuthRepo(dio, SecureStorage()),
      _WorkRepo(dio, SecureStorage()),
      dio,
      permissionReader: () async => const LocationPermissionState(
        serviceEnabled: true,
        permission: LocationPermission.always,
        accuracy: LocationAccuracyStatus.precise,
      ),
      registerFcm: () async {},
      trackingStarter: ({
        required authToken,
        required baseUrl,
        required workSession,
        required versionName,
        required buildNumber,
        required packageName,
      }) async {
        calls++;
        await started.future;
      },
      isTrackingRunning: () async => true,
    );
    addTearDown(notifier.dispose);

    await _waitFor(() => notifier.state.status == AuthStatus.authenticated);
    expect(notifier.state.workSession?.id, 123);
    expect(notifier.state.trackingActive, isFalse);
    expect(notifier.state.trackingIssue, contains('Iniciando'));
    expect(await notifier.canBeginDelivery(), isFalse);
    expect(calls, 1);

    started.complete();
    await _waitFor(() => notifier.state.trackingActive);
    expect(notifier.state.trackingIssue, isNull);
    expect(await notifier.canBeginDelivery(), isTrue);
  });

  test('Android startup error keeps user logged in but blocks delivery',
      () async {
    final dio = client();
    final notifier = AuthNotifier(
      _AuthRepo(dio, SecureStorage()),
      _WorkRepo(dio, SecureStorage()),
      dio,
      permissionReader: () async => const LocationPermissionState(
        serviceEnabled: true,
        permission: LocationPermission.always,
        accuracy: LocationAccuracyStatus.precise,
      ),
      registerFcm: () async {},
      trackingStarter: ({
        required authToken,
        required baseUrl,
        required workSession,
        required versionName,
        required buildNumber,
        required packageName,
      }) async {
        throw const TrackingServiceException('Android service startup failed');
      },
      isTrackingRunning: () async => false,
    );
    addTearDown(notifier.dispose);
    await _waitFor(() =>
        notifier.state.status == AuthStatus.authenticated &&
        notifier.state.trackingIssue != null &&
        !notifier.state.trackingIssue!.contains('Iniciando'));
    expect(notifier.state.workSession?.id, 123);
    expect(notifier.state.trackingActive, isFalse);
    expect(await notifier.canBeginDelivery(), isFalse);
  });
}
