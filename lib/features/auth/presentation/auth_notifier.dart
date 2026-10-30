import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/api/api_constants.dart';
import '../../../core/api/dio_client.dart';
import '../../../core/api/refresh_access_result.dart';
import '../../../core/auth/auth_session_bridge.dart';
import '../../../core/auth/jwt_expiration.dart';
import '../../../core/auth/session_refresh.dart';
import '../../../core/auth/session_replacement.dart';
import '../../../core/errors/user_facing_error.dart';
import '../../../core/version/delivery_app_version.dart';
import '../../notifications/fcm_service.dart';
import '../../tracking/location_tracking_policy.dart';
import '../../tracking/location_tracking_service.dart';
import '../../tracking/work_session_models.dart';
import '../../tracking/work_session_repository.dart';
import '../data/auth_models.dart';
import '../data/auth_repository.dart';

enum AuthStatus {
  initial,
  loading,
  authenticated,
  unauthenticated,
  updateRequired,
  error,
}

class AuthState {
  final AuthStatus status;
  final AuthUser? user;
  final DeliveryWorkSession? workSession;
  final bool trackingActive;
  final String? trackingIssue;
  final String? errorMessage;
  final DeliveryAppVersionPolicy? updatePolicy;
  final bool canRetrySession;

  const AuthState({
    this.status = AuthStatus.initial,
    this.user,
    this.workSession,
    this.trackingActive = false,
    this.trackingIssue,
    this.errorMessage,
    this.updatePolicy,
    this.canRetrySession = false,
  });

  AuthState copyWith({
    AuthStatus? status,
    AuthUser? user,
    DeliveryWorkSession? workSession,
    bool clearWorkSession = false,
    bool? trackingActive,
    String? trackingIssue,
    bool clearTrackingIssue = false,
    String? errorMessage,
    DeliveryAppVersionPolicy? updatePolicy,
    bool? canRetrySession,
  }) =>
      AuthState(
        status: status ?? this.status,
        user: user ?? this.user,
        workSession: clearWorkSession ? null : workSession ?? this.workSession,
        trackingActive: trackingActive ?? this.trackingActive,
        trackingIssue:
            clearTrackingIssue ? null : trackingIssue ?? this.trackingIssue,
        errorMessage: errorMessage,
        updatePolicy: updatePolicy ?? this.updatePolicy,
        canRetrySession: canRetrySession ?? this.canRetrySession,
      );
}

class _TrackingReconciliation {
  final DeliveryWorkSession? session;
  final String? issue;

  const _TrackingReconciliation({
    required this.session,
    this.issue,
  });
}

typedef TrackingStartRunner = Future<void> Function({
  required String authToken,
  required String baseUrl,
  required DeliveryWorkSession workSession,
  required String versionName,
  required String buildNumber,
  required String packageName,
});

typedef TrackingStopRunner = Future<void> Function({
  required bool recordEvent,
  required bool discardPending,
});

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthRepository _repository;
  final WorkSessionRepository _workSessions;
  final DioClient _client;
  final Future<void> Function()? _onUpdateRequiredCleanup;
  final TrackingStartRunner _trackingStarter;
  final TrackingStopRunner _trackingStopper;
  final Future<bool> Function() _isTrackingRunning;
  final Future<LocationPermissionState> Function() _permissionReader;
  final Future<void> Function()? _registerFcm;
  final Duration sessionRestoreTimeout;
  Future<void>? _resumeInFlight;
  Future<void>? _versionInFlight;
  Future<void>? _trackingStartInFlight;
  DeliveryWorkSession? _queuedTrackingSession;
  int? _startingTrackingSessionId;
  int? _startingTrackingGeneration;
  int _authGeneration = 0;
  Future<void>? _logoutInFlight;
  Timer? _trackingRetryTimer;

  AuthNotifier(
    this._repository,
    this._workSessions,
    this._client, {
    Future<void> Function()? onUpdateRequiredCleanup,
    TrackingStartRunner? trackingStarter,
    TrackingStopRunner? trackingStopper,
    Future<bool> Function()? isTrackingRunning,
    Future<LocationPermissionState> Function()? permissionReader,
    Future<void> Function()? registerFcm,
    this.sessionRestoreTimeout = const Duration(seconds: 30),
  })  : _onUpdateRequiredCleanup = onUpdateRequiredCleanup,
        _trackingStopper =
            trackingStopper ?? LocationTrackingService.stopTracking,
        _trackingStarter =
            trackingStarter ?? LocationTrackingService.startTracking,
        _isTrackingRunning =
            isTrackingRunning ?? (() => LocationTrackingService.isRunning),
        _permissionReader = permissionReader ?? readLocationPermissionState,
        _registerFcm = registerFcm,
        super(const AuthState()) {
    setAuthSessionInvalidatedHandler(onSessionInvalidatedByApi);
    setDeliveryAppUpdateRequiredHandler(onDeliveryAppUpdateRequired);
    setWorkSessionChangedByPushHandler(onWorkSessionChangedByPush);
    unawaited(restoreSession());
  }

  @override
  void dispose() {
    _authGeneration++;
    _trackingRetryTimer?.cancel();
    setAuthSessionInvalidatedHandler(null);
    setDeliveryAppUpdateRequiredHandler(null);
    setWorkSessionChangedByPushHandler(null);
    super.dispose();
  }

  void onSessionInvalidatedByApi(String? reason) {
    unawaited(_endLocalSession(errorMessage: reason));
  }

  void onDeliveryAppUpdateRequired(DeliveryAppVersionPolicy policy) {
    unawaited(_activateUpdateRequired(policy));
  }

  void onWorkSessionChangedByPush() {
    unawaited(refreshSessionIfNeededAfterResume());
  }

  /// Coalesces lifecycle, push and route refreshes into one reconciliation.
  Future<void> refreshSessionIfNeededAfterResume(
      {bool requestPermission = false}) async {
    if (state.status != AuthStatus.authenticated) return;
    final current = _resumeInFlight;
    if (current != null) return current;

    final refresh =
        _refreshSessionInternal(requestPermission: requestPermission);
    _resumeInFlight = refresh;
    try {
      await refresh;
    } finally {
      if (identical(_resumeInFlight, refresh)) _resumeInFlight = null;
    }
  }

  bool _sameTrackingSession(int generation, DeliveryWorkSession session) =>
      mounted &&
      _authGeneration == generation &&
      state.status == AuthStatus.authenticated &&
      state.workSession?.id == session.id &&
      state.user?.id == session.deliverymanId;

  /// The verified work session opens the UI immediately. The Android service
  /// may still be importing old data, starting an isolate, or waiting for a
  /// native plugin. None of those operations may hold the login spinner.
  void _scheduleTrackingStart(DeliveryWorkSession session) {
    if (!mounted ||
        state.status != AuthStatus.authenticated ||
        state.workSession?.id != session.id) return;
    if (_trackingStartInFlight != null) {
      if (_startingTrackingSessionId != session.id ||
          _startingTrackingGeneration != _authGeneration) {
        _queuedTrackingSession = session;
      }
      return;
    }
    _trackingRetryTimer?.cancel();
    final generation = _authGeneration;
    _startingTrackingGeneration = generation;
    _startingTrackingSessionId = session.id;
    final operation = _runTrackingStart(session, generation);
    _trackingStartInFlight = operation;
    unawaited(operation.whenComplete(() {
      if (!identical(_trackingStartInFlight, operation)) return;
      _trackingStartInFlight = null;
      _startingTrackingSessionId = null;
      _startingTrackingGeneration = null;
      final pending = _queuedTrackingSession;
      _queuedTrackingSession = null;
      if (pending != null && mounted) _scheduleTrackingStart(pending);
    }));
  }

  void _retryTracking(DeliveryWorkSession session, int generation) {
    if (!_sameTrackingSession(generation, session)) return;
    _trackingRetryTimer?.cancel();
    _trackingRetryTimer = Timer(const Duration(seconds: 30), () {
      if (_sameTrackingSession(generation, session)) {
        _scheduleTrackingStart(session);
      }
    });
  }

  Future<void> _runTrackingStart(
      DeliveryWorkSession session, int generation) async {
    final watch = Stopwatch()..start();
    var complete = false;
    final watchdog = Timer(const Duration(seconds: 12), () {
      if (!complete && _sameTrackingSession(generation, session)) {
        state = state.copyWith(
          trackingActive: false,
          trackingIssue: 'El seguimiento tarda en iniciarse. Puedes consultar '
              'pedidos, pero no iniciar entregas hasta que quede activo.',
        );
      }
    });
    try {
      debugPrint('TrackingStartup: begin workSession=${session.id}');
      final token = await _repository.getStoredAccessToken();
      if (token == null) throw const SessionEndedException();
      final headers = await _client.versionHeaders();
      if (!_sameTrackingSession(generation, session)) return;
      await _trackingStarter(
        authToken: token,
        baseUrl: ApiConstants.baseUrl,
        workSession: session,
        versionName: headers[deliveryAppVersionHeader]!,
        buildNumber: headers[deliveryAppBuildHeader]!,
        packageName: headers[deliveryAppPackageHeader]!,
      );
      if (!_sameTrackingSession(generation, session)) return;
      final running = await _isTrackingRunning()
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
      if (!_sameTrackingSession(generation, session)) return;
      debugPrint('TrackingStartup: finished in ${watch.elapsedMilliseconds}ms; '
          'running=$running');
      state = state.copyWith(
        trackingActive: running,
        trackingIssue: running
            ? null
            : 'El servicio de ubicación aún no está activo. Reintentando.',
        clearTrackingIssue: running,
      );
      if (!running) _retryTracking(session, generation);
    } catch (error) {
      debugPrint(
          'TrackingStartup: failed after ${watch.elapsedMilliseconds}ms: '
          '${error.runtimeType}');
      if (_sameTrackingSession(generation, session)) {
        state = state.copyWith(
          trackingActive: false,
          trackingIssue: userFacingErrorMessage(error,
              fallback: 'No pudimos iniciar el seguimiento. Reintentando.'),
        );
        _retryTracking(session, generation);
      }
    } finally {
      complete = true;
      watchdog.cancel();
    }
  }

  Future<void> _verifyVersion(int generation) => _versionInFlight ??=
      _loadVersion(generation).whenComplete(() => _versionInFlight = null);

  Future<void> _loadVersion(int generation) async {
    try {
      final policy = await _repository
          .checkDeliveryAppVersion()
          .timeout(const Duration(seconds: 8));
      if (_currentAuthAttempt(generation) && policy.updateRequired)
        await _activateUpdateRequired(policy);
    } catch (error) {
      final update = deliveryAppUpdateFromError(error);
      if (_currentAuthAttempt(generation) && update != null)
        await _activateUpdateRequired(update.policy);
    }
  }

  Future<void> _refreshSessionInternal({bool requestPermission = false}) async {
    final generation = _authGeneration;
    unawaited(_verifyVersion(generation));

    try {
      if (!_currentAuthAttempt(generation)) return;
      final accessToken = await _repository.getStoredAccessToken();
      if (!_currentAuthAttempt(generation)) return;
      if (JwtExpiration.shouldProactivelyRefresh(accessToken)) {
        final outcome = await _client.silentRefreshAccessToken();
        if (!_currentAuthAttempt(generation)) return;
        if (outcome is RefreshAccessSessionEnded) {
          await _endLocalSession();
          return;
        }
        if (outcome is RefreshAccessUpdateRequired) {
          await _activateUpdateRequired(outcome.policy);
          return;
        }
      }

      final reconciliation = await _reconcileWorkSession(
        requestPermission: requestPermission,
        preserveExistingSessionOnIssue: true,
      );
      if (!_currentAuthAttempt(generation)) return;
      final session = reconciliation.session;
      final ready = state.trackingActive &&
          state.workSession?.id == session?.id &&
          reconciliation.issue == null;
      state = state.copyWith(
        workSession: session,
        clearWorkSession: session == null,
        trackingActive: ready,
        trackingIssue: reconciliation.issue ??
            (session == null
                ? 'No hay una jornada activa.'
                : ready
                    ? null
                    : 'Iniciando seguimiento de ubicación...'),
        clearTrackingIssue: ready,
      );
      if (session != null && reconciliation.issue == null && !ready) {
        _scheduleTrackingStart(session);
      }
      unawaited(_registerFcmTokenSafely(requestPermission: requestPermission));
    } catch (e) {
      if (!_currentAuthAttempt(generation)) return;
      final update = deliveryAppUpdateFromError(e);
      if (update != null) {
        await _activateUpdateRequired(update.policy);
        return;
      }
      await _recoverWithoutDiscardingCredentials(e, generation: generation);
    }
  }

  bool _currentAuthAttempt(int generation) =>
      mounted && _authGeneration == generation;

  Future<void> restoreSession() async {
    if (state.status == AuthStatus.loading) return;
    final generation = ++_authGeneration;
    state = const AuthState(status: AuthStatus.loading);
    final watch = Stopwatch()..start();
    unawaited(_verifyVersion(generation));
    try {
      await _checkSession(generation).timeout(sessionRestoreTimeout);
    } on TimeoutException {
      if (!_currentAuthAttempt(generation) ||
          state.status != AuthStatus.loading) return;
      _authGeneration++;
      debugPrint('AuthStartup timeout elapsedMs=${watch.elapsedMilliseconds}');
      state = const AuthState(
        status: AuthStatus.error,
        canRetrySession: true,
        errorMessage: 'La verificación de sesión tardó demasiado. '
            'Reintenta sin borrar los datos de la aplicación.',
      );
    }
  }

  Future<void> _checkSession(int generation) async {
    final localRead = Stopwatch()..start();
    try {
      final user = await _repository.getAuthenticatedUser();
      if (user == null) {
        if (_currentAuthAttempt(generation)) {
          state = const AuthState(status: AuthStatus.unauthenticated);
        }
        return;
      }
      final session = await _workSessions.getStored();
      if (!_currentAuthAttempt(generation)) return;
      state = AuthState(
        status: AuthStatus.authenticated,
        user: user,
        workSession: session,
        trackingIssue: 'Comprobando jornada y seguimiento...',
      );
      debugPrint(
          'AuthStartup localIdentityMs=${localRead.elapsedMilliseconds}');
      unawaited(refreshSessionIfNeededAfterResume());
    } catch (error) {
      if (_currentAuthAttempt(generation)) {
        await _recoverWithoutDiscardingCredentials(error,
            generation: generation);
      }
    }
  }

  Future<void> _recoverWithoutDiscardingCredentials(Object error,
      {int? generation}) async {
    generation ??= _authGeneration;
    final definitive = error is SessionEndedException ||
        (error is DioException &&
            (error.error is SessionEndedException ||
                isSessionReplacedResponse(
                    error.response?.statusCode, error.response?.data)));
    if (definitive) {
      await _endLocalSession();
      return;
    }
    // A failed reconciliation does not revoke authentication. Do not create a
    // new work session locally or extend a cached one beyond its server cutoff.
    final message = userFacingErrorMessage(error,
        fallback: 'No pudimos verificar la jornada. Vuelve a intentarlo.');
    try {
      final user = state.user ?? await _repository.getStoredUser();
      if (!_currentAuthAttempt(generation)) return;
      final stored = state.workSession ?? await _workSessions.getStored();
      if (!_currentAuthAttempt(generation)) return;
      final active = stored != null &&
          stored.isActive &&
          DateTime.now().toUtc().isBefore(stored.autoCloseAt);
      if (!isTransientSessionFailure(error) || !active) {
        await _trackingStopper(recordEvent: false, discardPending: false);
      }
      if (!_currentAuthAttempt(generation)) return;
      state = AuthState(
        status: user == null ? AuthStatus.error : AuthStatus.authenticated,
        user: user,
        workSession: stored,
        trackingActive: false,
        trackingIssue: message,
        errorMessage: user == null ? message : null,
      );
    } catch (_) {
      if (!_currentAuthAttempt(generation)) return;
      // Storage/plugin initialization can itself be transient.
      state = state.copyWith(status: AuthStatus.error, errorMessage: message);
    }
  }

  Future<void> login(String email, String password) async {
    if (state.status == AuthStatus.loading) return;
    final generation = ++_authGeneration;
    _trackingRetryTimer?.cancel();
    state = const AuthState(status: AuthStatus.loading);
    try {
      final user = await _repository
          .login(LoginRequest(email: email, password: password));
      if (!_currentAuthAttempt(generation)) return;
      state = AuthState(
        status: AuthStatus.authenticated,
        user: user,
        trackingIssue: 'Preparando jornada y seguimiento...',
      );
      unawaited(refreshSessionIfNeededAfterResume(requestPermission: true));
    } catch (error) {
      if (!_currentAuthAttempt(generation)) return;
      final update = deliveryAppUpdateFromError(error);
      if (update != null) {
        await _activateUpdateRequired(update.policy);
      } else {
        await _endLocalSession(
            errorMessage: userFacingErrorMessage(error,
                fallback: 'No pudimos iniciar sesión. Inténtalo de nuevo.'));
      }
    }
  }

  Future<_TrackingReconciliation> _reconcileWorkSession({
    required bool requestPermission,
    required bool preserveExistingSessionOnIssue,
  }) async {
    if (kIsWeb) {
      return const _TrackingReconciliation(
          session: null,
          issue: 'Vista web: seguimiento y entregas disponibles en Android.');
    }
    var permission = await _permissionReader();
    if (requestPermission && !permission.canTrackInBackground) {
      permission = await _requestLocationPermissionState();
    }
    final stored = await _workSessions.getStored();
    final storedIsActive = stored != null &&
        stored.isActive &&
        DateTime.now().toUtc().isBefore(stored.autoCloseAt);

    if (!permission.canTrackInBackground) {
      if (preserveExistingSessionOnIssue && storedIsActive) {
        return _TrackingReconciliation(
          session: stored,
          issue: permission.issueMessage,
        );
      }
      if (preserveExistingSessionOnIssue) {
        return _TrackingReconciliation(
          session: null,
          issue: permission.issueMessage,
        );
      }
      throw StateError(permission.issueMessage);
    }

    final session = requestPermission
        ? await _workSessions.startOrResume()
        : await _workSessions.current();
    if (session == null) {
      await _trackingStopper(recordEvent: false, discardPending: false);
      return const _TrackingReconciliation(
          session: null, issue: 'No hay una jornada activa.');
    }
    final owner = await _repository.getStoredUser();
    if (owner == null ||
        owner.id != session.deliverymanId ||
        (owner.branchId != null && owner.branchId != session.branchId)) {
      throw const TrackingServiceException(
          'No se pudo verificar el propietario de la jornada.');
    }
    final token = await _repository.getStoredAccessToken();
    if (token == null) {
      throw StateError(
        'No se encontró la sesión de autenticación para iniciar el rastreo.',
      );
    }

    // Android startup and legacy outbox import are deliberately NOT awaited
    // here: authentication checks and work-session ownership are sufficient
    // to show the home screen; delivery actions still require tracking ready.
    return _TrackingReconciliation(session: session);
  }

  Future<void> _registerFcmTokenSafely({bool requestPermission = false}) async {
    try {
      if (_registerFcm != null) {
        await _registerFcm!();
      } else {
        if (requestPermission && !await FcmService.requestPermission()) return;
        await FcmService.registerToken(_client);
      }
    } catch (_) {
      // El push es complementario: un fallo de Firebase no debe cerrar sesión.
    }
  }

  Future<void> startWorkSession() async {
    await refreshSessionIfNeededAfterResume(requestPermission: true);
  }

  /// No delivery may be started while Android tracking has not been
  /// confirmed for the authenticated, active work session.
  Future<bool> canBeginDelivery() async {
    final session = state.workSession;
    if (state.status != AuthStatus.authenticated ||
        !state.trackingActive ||
        state.trackingIssue != null ||
        session == null ||
        !session.isActive ||
        !DateTime.now().toUtc().isBefore(session.autoCloseAt)) {
      return false;
    }
    try {
      return await _isTrackingRunning()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  Future<void> logout() => _logoutInFlight ??=
      _logoutVerified().whenComplete(() => _logoutInFlight = null);

  Future<void> _logoutVerified() async {
    var generation = _authGeneration;
    String? issue;
    String? sessionId;
    try {
      sessionId = await _repository.getStoredSessionId();
      await _repository.logout(expectedSessionId: sessionId);
    } catch (error) {
      if (_currentAuthAttempt(generation)) {
        state = state.copyWith(errorMessage: userFacingErrorMessage(error));
      }
      return;
    }
    if (!_currentAuthAttempt(generation)) return;
    generation = ++_authGeneration;
    _trackingRetryTimer?.cancel();
    _queuedTrackingSession = null;
    state = const AuthState(status: AuthStatus.loading);
    for (final cleanup in <Future<void> Function()>[
      () => _trackingStopper(recordEvent: true, discardPending: false),
      FcmService.clearTrackingReviewNotices,
      () => FcmService.unregisterToken(_client, expectedSessionId: sessionId),
    ]) {
      if (!_currentAuthAttempt(generation)) {
        return;
      }
      try {
        await cleanup();
      } on DioException {
        continue;
      } catch (error) {
        issue ??= userFacingErrorMessage(error);
      }
    }
    if (_currentAuthAttempt(generation)) {
      state = AuthState(
        status: issue == null ? AuthStatus.unauthenticated : AuthStatus.error,
        errorMessage: issue,
      );
    }
  }

  Future<void> _endLocalSession({String? errorMessage}) async {
    _authGeneration++;
    _trackingRetryTimer?.cancel();
    _queuedTrackingSession = null;
    String? cleanupError;
    // Failure in one local plugin must not skip credential cleanup or
    // leave login stuck in AuthStatus.loading. Pending GPS data remains.
    for (final cleanup in <Future<void> Function()>[
      () => _trackingStopper(recordEvent: false, discardPending: false),
      FcmService.clearTrackingReviewNotices,
      _workSessions.clearLocal,
      _repository.clearLocalSession,
    ]) {
      try {
        await cleanup();
      } catch (_) {
        cleanupError ??= localStorageErrorMessage;
      }
    }
    if (!mounted) return;
    final message = errorMessage ?? cleanupError;
    state = AuthState(
      status: message == null ? AuthStatus.unauthenticated : AuthStatus.error,
      errorMessage: message,
    );
  }

  Future<void> _activateUpdateRequired(
    DeliveryAppVersionPolicy policy,
  ) async {
    _authGeneration++;
    _trackingRetryTimer?.cancel();
    _queuedTrackingSession = null;
    if (_onUpdateRequiredCleanup != null) {
      await _onUpdateRequiredCleanup!();
    } else {
      try {
        await _trackingStopper(recordEvent: false, discardPending: false);
      } catch (_) {}
      try {
        await FcmService.clearTrackingReviewNotices();
      } catch (_) {}
    }
    try {
      await _workSessions.clearLocal();
    } catch (_) {}
    await _repository.clearLocalSession();
    state = AuthState(
      status: AuthStatus.updateRequired,
      updatePolicy: policy,
    );
  }

  Future<void> updateSessionUser(AuthUser user) async {
    await _repository.persistUser(user);
    state = state.copyWith(user: user);
  }

  Future<LocationPermissionState> _requestLocationPermissionState() async {
    var state = await readLocationPermissionState();
    if (state.permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
      state = await readLocationPermissionState();
    }
    if (!state.serviceEnabled) {
      await Geolocator.openLocationSettings();
      state = await readLocationPermissionState();
    }
    if (state.permission != LocationPermission.always ||
        state.accuracy != LocationAccuracyStatus.precise) {
      await Geolocator.openAppSettings();
      state = await readLocationPermissionState();
    }
    return state;
  }

  Future<void> openTrackingSettings() async {
    final state = await readLocationPermissionState();
    if (!state.serviceEnabled) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
  }
}

final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    ref.watch(authRepositoryProvider),
    ref.watch(workSessionRepositoryProvider),
    ref.watch(dioClientProvider),
  );
});
