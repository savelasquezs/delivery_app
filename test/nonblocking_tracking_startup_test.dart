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
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _driver = AuthUser(
  id: 9,
  name: 'Courier',
  email: 'courier@example.invalid',
  role: 'deliveryman',
  branchId: 1,
);

String _jwt() {
  final expiration =
      DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000;
  final encoded = base64Url.encode(utf8.encode(jsonEncode({'exp': expiration})))
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
  Future<bool> hasValidSession() async => true;
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
        DeliveryAppVersionInfoLoader(load: () async => PackageInfo(
          appName: 'Señor Arroz',
          packageName: 'com.senorarroz.delivery_app',
          version: '1.2.5',
          buildNumber: '24',
        )),
      );

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
    await _waitFor(() => notifier.state.status == AuthStatus.authenticated &&
        notifier.state.trackingIssue != null &&
        !notifier.state.trackingIssue!.contains('Iniciando'));
    expect(notifier.state.workSession?.id, 123);
    expect(notifier.state.trackingActive, isFalse);
    expect(await notifier.canBeginDelivery(), isFalse);
  });
}
