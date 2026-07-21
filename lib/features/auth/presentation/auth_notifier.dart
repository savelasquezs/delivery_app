import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/api/api_constants.dart';
import '../../../core/api/dio_client.dart';
import '../../../core/api/refresh_access_result.dart';
import '../../../core/auth/auth_session_bridge.dart';
import '../../../core/auth/jwt_expiration.dart';
import '../../notifications/fcm_service.dart';
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
  final String? errorMessage;

  const AuthState({
    this.status = AuthStatus.initial,
    this.user,
    this.workSession,
    this.trackingActive = false,
    this.errorMessage,
  });

  AuthState copyWith({
    AuthStatus? status,
    AuthUser? user,
    DeliveryWorkSession? workSession,
    bool? trackingActive,
    String? errorMessage,
  }) =>
      AuthState(
        status: status ?? this.status,
        user: user ?? this.user,
        workSession: workSession ?? this.workSession,
        trackingActive: trackingActive ?? this.trackingActive,
        errorMessage: errorMessage,
      );
}

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthRepository _repository;
  final WorkSessionRepository _workSessions;
  final DioClient _client;

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

  void onSessionInvalidatedByApi() {
    unawaited(_endLocalSession());
  }

  void onWorkSessionChangedByPush() {
    unawaited(refreshSessionIfNeededAfterResume());
  }

  Future<void> refreshSessionIfNeededAfterResume() async {
    if (state.status != AuthStatus.authenticated) return;
    try {
      final accessToken = await _repository.getStoredAccessToken();
      if (JwtExpiration.shouldProactivelyRefresh(accessToken)) {
        final outcome = await _client.silentRefreshAccessToken();
        if (outcome is RefreshAccessSessionEnded) {
          await _endLocalSession();
          return;
        }
      }
      final session = await _startWorkSessionTracking(requestPermission: false);
      state = state.copyWith(
        workSession: session,
        trackingActive: await LocationTrackingService.isRunning,
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
      final session = await _startWorkSessionTracking(requestPermission: false);
      state = AuthState(
        status: AuthStatus.authenticated,
        user: user,
        workSession: session,
        trackingActive: await LocationTrackingService.isRunning,
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
      final session = await _startWorkSessionTracking(requestPermission: true);
      state = AuthState(
        status: AuthStatus.authenticated,
        user: user,
        workSession: session,
        trackingActive: await LocationTrackingService.isRunning,
      );

      try {
        final notificationsGranted = await FcmService.requestPermission();
        if (notificationsGranted) {
          await _registerFcmTokenSafely();
        }
      } catch (_) {}
    } catch (e) {
      await _endLocalSession(errorMessage: e.toString());
    }
  }

  Future<DeliveryWorkSession> _startWorkSessionTracking({
    required bool requestPermission,
  }) async {
    final session = await _workSessions.startOrResume();
    final canTrack = requestPermission
        ? await _requestLocationPermissions()
        : await _hasLocationPermission();
    if (canTrack) {
      final token = await _repository.getStoredAccessToken();
      if (token != null) {
        await LocationTrackingService.startTracking(
          authToken: token,
          baseUrl: ApiConstants.baseUrl,
          workSessionId: session.id,
          autoCloseAtUtc: session.autoCloseAt,
          lightIntervalSeconds: session.tracking.lightIntervalSeconds,
          activeIntervalSeconds: session.tracking.activeIntervalSeconds,
        );
      }
    }
    return session;
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
    await LocationTrackingService.stopTracking();
    await _workSessions.clearLocal();
    await _repository.logout();
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
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse) {
        permission = await Geolocator.requestPermission();
      }
      return await Geolocator.isLocationServiceEnabled() &&
          permission != LocationPermission.denied &&
          permission != LocationPermission.deniedForever;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _hasLocationPermission() async {
    try {
      final permission = await Geolocator.checkPermission();
      return await Geolocator.isLocationServiceEnabled() &&
          permission != LocationPermission.denied &&
          permission != LocationPermission.deniedForever;
    } catch (_) {
      return false;
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
