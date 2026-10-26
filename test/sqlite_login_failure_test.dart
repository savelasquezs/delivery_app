import 'package:delivery_app/core/api/dio_client.dart';
import 'package:delivery_app/core/errors/user_facing_error.dart';
import 'package:delivery_app/core/storage/secure_storage.dart';
import 'package:delivery_app/core/version/delivery_app_version.dart';
import 'package:delivery_app/features/auth/data/auth_models.dart';
import 'package:delivery_app/features/auth/data/auth_repository.dart';
import 'package:delivery_app/features/auth/presentation/auth_notifier.dart';
import 'package:delivery_app/features/tracking/work_session_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class _AndroidPragmaError implements DatabaseException {
  @override
  String toString() => 'DatabaseException(Queries can be performed using '
      "SQLiteDatabase query or rawQuery methods only.) sql 'PRAGMA busy_timeout = 1000' args []";

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailedLoginRepository extends AuthRepository {
  int cleanupAttempts = 0;
  _FailedLoginRepository(super.client, super.storage);

  @override
  Future<DeliveryAppVersionPolicy> checkDeliveryAppVersion() async =>
      const DeliveryAppVersionPolicy(
        requiredVersion: '1.2.5',
        minimumBuild: 11,
        playStoreUrl:
            'https://play.google.com/store/apps/details?id=com.senorarroz.delivery_app',
        updateRequired: false,
      );

  @override
  Future<AuthUser?> getAuthenticatedUser() async => null;

  @override
  Future<AuthUser> login(LoginRequest request) async =>
      throw _AndroidPragmaError();

  @override
  Future<void> clearLocalSession() async {
    cleanupAttempts++;
    throw _AndroidPragmaError();
  }
}

class _FailedCleanupWorkSessions extends WorkSessionRepository {
  int cleanupAttempts = 0;
  _FailedCleanupWorkSessions(super.client, super.storage);

  @override
  Future<void> clearLocal() async {
    cleanupAttempts++;
    throw _AndroidPragmaError();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    dotenv.testLoad(fileInput: 'API_BASE_URL=https://api.example.invalid/api');
    SharedPreferences.setMockInitialValues({});
  });

  test('native SQLite errors never expose SQL in the login message', () {
    final error = _AndroidPragmaError();
    expect(userFacingErrorMessage(error), localStorageErrorMessage);
    expect(
        userFacingErrorMessage(DioException(
          requestOptions: RequestOptions(path: '/login'), error: error,
        )),
        localStorageErrorMessage);
    expect(userFacingErrorMessage(error.toString(), fallback: 'Reintenta.'),
        'Reintenta.');
  });

  test('failed login reaches an error state even when cleanup also fails',
      () async {
    final storage = SecureStorage();
    final client = DioClient(storage, DeliveryAppVersionInfoLoader());
    final repository = _FailedLoginRepository(client, storage);
    final sessions = _FailedCleanupWorkSessions(client, storage);
    final notifier = AuthNotifier(repository, sessions, client);
    addTearDown(notifier.dispose);
    for (var i = 0;
        i < 20 && notifier.state.status == AuthStatus.loading;
        i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(notifier.state.status, AuthStatus.unauthenticated);
    // The plugin is intentionally unavailable in this host test. Cleanup must
    // attempt the remaining steps instead of leaving a loading spinner.
    await notifier.login('test@example.invalid', 'not-a-real-password');
    expect(sessions.cleanupAttempts, 1);
    expect(repository.cleanupAttempts, 1);
    expect(notifier.state.status, AuthStatus.error);
    expect(notifier.state.errorMessage, localStorageErrorMessage);
    expect(notifier.state.trackingActive, isFalse);
  });
}
