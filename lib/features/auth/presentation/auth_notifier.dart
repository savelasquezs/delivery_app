import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/api/api_constants.dart';
import '../../../core/api/dio_client.dart';
import '../../../core/api/refresh_access_result.dart';
import '../../../core/auth/auth_session_bridge.dart';
import '../../../core/auth/jwt_expiration.dart';
import '../../notifications/fcm_service.dart';
import '../../tracking/location_tracking_policy.dart';
import '../../tracking/location_tracking_service.dart';
import '../../tracking/work_session_models.dart';
import '../../tracking/work_session_repository.dart';
import '../data/auth_models.dart';
import '../data/auth_repository.dart';

enum AuthStatus { initial, loading, authenticated, unauthenticated, error }

class AuthState {
  final AuthStatus status;
  final AuthUser? user;
  final DeliveryWorkSession? workSession;
  final bool trackingActive;
  final String? trackingIssue;
  final String? errorMessage;

  const AuthState({
    this.status = AuthStatus.initial,
    this.user,
    this.workSession,
    this.trackingActive = false,
    this.trackingIssue,
    this.errorMessage,
  });

  AuthState copyWith({
    AuthStatus? status,
    AuthUser? user,
    DeliveryWorkSession? workSession,
    bool? trackingActive,
    String? trackingIssue,
    bool clearTrackingIssue = false,
    String? errorMessage,
  }) =>
      AuthState(
        status: status ?? this.status,
        user: user ?? this.user,
        workSession: workSession ?? this.workSession,
        trackingActive: trackingActive ?? this.trackingActive,
        trackingIssue:
            clearTrackingIssue ? null : trackingIssue ?? this.trackingIssue,
        errorMessage: errorMessage,
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

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthRepository _repository;
  final WorkSessionRepository _workSessions;
  final DioClient _client;
  Future<void>? _resumeInFlight;

  AuthNotifier(this._repository, this._workSessions, this._client)
      : super(const AuthState()) {
    setAuthSessionInvalidatedHandler(onSessionInvalidatedByApi);
    setWorkSessionChangedByPushHandler(onWorkSessionChangedByPush);
    unawaited(_checkSession());
  }

  @override
  void dispose() {
    setAuthSessionInvalidatedHandler(null);
    setWorkSessionChangedByPushHandler(null);
    super.dispose();
  }

  void onSessionInvalidatedByApi(String? reason) {
    unawaited(_endLocalSession(errorMessage: reason));
  }

  void onWorkSessionChangedByPush() {
    unawaited(refreshSessionIfNeededAfterResume());
  }

  /// Coalesces lifecycle, push and route refreshes into one reconciliation.
  Future<void> refreshSessionIfNeededAfterResume() async {
    if (state.status != AuthStatus.authenticated) return;
    final current = _resumeInFlight;
    if (current != null) return current;

    final refresh = _refreshSessionInternal();
    _resumeInFlight = refresh;
    try {
      await refresh;
    } finally {
      if (identical(_resumeInFlight, refresh)) _resumeInFlight = null;
    }
  }

  Future<void> _refreshSessionInternal() async {
    try {
      final accessToken = await _repository.getStoredAccessToken();
      if (JwtExpiration.shouldProactivelyRefresh(accessToken)) {
        final outcome = await _client.silentRefreshAccessToken();
        if (outcome is RefreshAccessSessionEnded) {
          await _endLocalSession();
          return;
        }
      }

      final reconciliation = await _reconcileWorkSession(
        requestPermission: false,
        preserveExistingSessionOnIssue: true,
      );
      state = state.copyWith(
        workSession: reconciliation.session ?? state.workSession,
        trackingActive: reconciliation.session != null &&
            reconciliation.issue == null &&
            await LocationTrackingService.isRunning,
        trackingIssue: reconciliation.issue,
        clearTrackingIssue: reconciliation.issue == null,
      );
      await _registerFcmTokenSafely();
    } catch (e) {
      await _endLocalSession(errorMessage: e.toString());
    }
  }

  Future<void> _checkSession() async {
    state = state.copyWith(status: AuthStatus.loading);
    try {
      final hasSession = await _repository.hasValidSession();
      if (!hasSession) {
        state = const AuthState(status: AuthStatus.unauthenticated);
        return;
      }
      final accessToken = await _repository.getStoredAccessToken();
      if (JwtExpiration.shouldProactivelyRefresh(accessToken)) {
        final outcome = await _client.silentRefreshAccessToken();
        if (outcome is RefreshAccessSessionEnded) {
          state = const AuthState(status: AuthStatus.unauthenticated);
          return;
        }
      }

      final user = await _repository.getStoredUser();
      if (user == null) {
        state = const AuthState(status: AuthStatus.unauthenticated);
        return;
      }
      final reconciliation = await _reconcileWorkSession(
        requestPermission: false,
        preserveExistingSessionOnIssue: true,
      );
      state = AuthState(
        status: AuthStatus.authenticated,
        user: user,
        workSession: reconciliation.session,
        trackingActive: reconciliation.session != null &&
            reconciliation.issue == null &&
            await LocationTrackingService.isRunning,
        trackingIssue: reconciliation.issue,
      );
      await _registerFcmTokenSafely();
    } catch (e) {
      await _endLocalSession(errorMessage: e.toString());
    }
  }

  Future<void> login(String email, String password) async {
    state = const AuthState(status: AuthStatus.loading);
    try {
      final user = await _repository.login(
        LoginRequest(email: email, password: password),
      );
      if (!await _requestLocationPermissions()) {
        throw StateError(
          'Para iniciar la jornada debes permitir ubicación precisa "Todo el tiempo" en los ajustes de Android.',
        );
      }
      try {
        final notificationsGranted = await FcmService.requestPermission();
        if (notificationsGranted) {
          await _registerFcmTokenSafely();
        }
      } catch (_) {}

      final reconciliation = await _reconcileWorkSession(
        requestPermission: false,
        preserveExistingSessionOnIssue: false,
      );
      if (reconciliation.issue != null || reconciliation.session == null) {
        throw StateError(
          reconciliation.issue ?? 'No se pudo iniciar la jornada.',
        );
      }
      state = AuthState(
        status: AuthStatus.authenticated,
        user: user,
        workSession: reconciliation.session,
        trackingActive: await LocationTrackingService.isRunning,
      );
    } catch (e) {
      await _endLocalSession(errorMessage: e.toString());
    }
  }

  Future<_TrackingReconciliation> _reconcileWorkSession({
    required bool requestPermission,
    required bool preserveExistingSessionOnIssue,
  }) async {
    final permission = requestPermission
        ? await _requestLocationPermissionState()
        : await readLocationPermissionState();
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

    final session = await _workSessions.startOrResume();
    final token = await _repository.getStoredAccessToken();
    if (token == null) {
      throw StateError(
        'No se encontró la sesión de autenticación para iniciar el rastreo.',
      );
    }

    try {
      await LocationTrackingService.startTracking(
        authToken: token,
        baseUrl: ApiConstants.baseUrl,
        workSessionId: session.id,
        autoCloseAtUtc: session.autoCloseAt,
        lightIntervalSeconds: session.tracking.lightIntervalSeconds,
        activeIntervalSeconds: session.tracking.activeIntervalSeconds,
      );
    } on TrackingServiceException catch (error) {
      if (preserveExistingSessionOnIssue) {
        return _TrackingReconciliation(session: session, issue: error.message);
      }
      rethrow;
    }
    return _TrackingReconciliation(session: session);
  }

  Future<void> _registerFcmTokenSafely() async {
    try {
      await FcmService.registerToken(_client);
    } catch (_) {
      // El push es complementario: un fallo de Firebase no debe cerrar sesión.
    }
  }

  Future<void> logout() async {
    await LocationTrackingService.stopTracking();
    await FcmService.clearTrackingReviewNotices();
    try {
      await FcmService.unregisterToken(_client);
    } catch (_) {}
    try {
      await _workSessions.closeCurrent();
    } catch (_) {
      await _workSessions.clearLocal();
    }
    await _repository.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  Future<void> _endLocalSession({String? errorMessage}) async {
    await LocationTrackingService.stopTracking(
      recordEvent: false,
      discardPending: false,
    );
    await FcmService.clearTrackingReviewNotices();
    await _workSessions.clearLocal();
    await _repository.clearLocalSession();
    state = AuthState(
      status:
          errorMessage == null ? AuthStatus.unauthenticated : AuthStatus.error,
      errorMessage: errorMessage,
    );
  }

  Future<void> updateSessionUser(AuthUser user) async {
    await _repository.persistUser(user);
    state = state.copyWith(user: user);
  }

  Future<bool> _requestLocationPermissions() async {
    final state = await _requestLocationPermissionState();
    return state.canTrackInBackground;
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
