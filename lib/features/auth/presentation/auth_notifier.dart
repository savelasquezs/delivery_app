import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/api/dio_client.dart';
import '../../../core/api/refresh_access_result.dart';
import '../../../core/auth/auth_session_bridge.dart';
import '../../../core/auth/jwt_expiration.dart';
import '../data/auth_models.dart';
import '../data/auth_repository.dart';
import '../../notifications/fcm_service.dart';

enum AuthStatus { initial, loading, authenticated, unauthenticated, error }

class AuthState {
  final AuthStatus status;
  final AuthUser? user;
  final String? errorMessage;

  const AuthState({
    this.status = AuthStatus.initial,
    this.user,
    this.errorMessage,
  });

  AuthState copyWith({
    AuthStatus? status,
    AuthUser? user,
    String? errorMessage,
  }) => AuthState(
        status: status ?? this.status,
        user: user ?? this.user,
        errorMessage: errorMessage,
      );
}

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthRepository _repository;
  final DioClient _client;

  AuthNotifier(this._repository, this._client) : super(const AuthState()) {
    setAuthSessionInvalidatedHandler(onSessionInvalidatedByApi);
    _checkSession();
  }

  @override
  void dispose() {
    setAuthSessionInvalidatedHandler(null);
    super.dispose();
  }

  /// Llamado desde [DioClient] cuando el refresh falla de forma definitiva (sesión limpiada).
  void onSessionInvalidatedByApi() {
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Tras volver al foreground: refresh silencioso si el access está vencido o por vencer.
  Future<void> refreshSessionIfNeededAfterResume() async {
    if (state.status != AuthStatus.authenticated) return;
    try {
      final accessToken = await _repository.getStoredAccessToken();
      if (!JwtExpiration.shouldProactivelyRefresh(accessToken)) return;
      final outcome = await _client.silentRefreshAccessToken();
      if (outcome is RefreshAccessSessionEnded) {
        state = const AuthState(status: AuthStatus.unauthenticated);
      }
    } catch (_) {}
  }

  Future<void> _checkSession() async {
    state = state.copyWith(status: AuthStatus.loading);
    try {
      final hasSession = await _repository.hasValidSession();
      if (!hasSession) {
        state = state.copyWith(status: AuthStatus.unauthenticated);
        return;
      }
      final accessToken = await _repository.getStoredAccessToken();
      if (JwtExpiration.shouldProactivelyRefresh(accessToken)) {
        final outcome = await _client.silentRefreshAccessToken();
        if (outcome is RefreshAccessSessionEnded) {
          state = state.copyWith(status: AuthStatus.unauthenticated);
          return;
        }
      }
      final user = await _repository.getStoredUser();
      state = state.copyWith(
        status: AuthStatus.authenticated,
        user: user,
      );
    } catch (_) {
      state = state.copyWith(status: AuthStatus.unauthenticated);
    }
  }

  Future<void> login(String email, String password) async {
    state = state.copyWith(status: AuthStatus.loading, errorMessage: null);
    try {
      final user = await _repository.login(
        LoginRequest(email: email, password: password),
      );
      state = state.copyWith(
        status: AuthStatus.authenticated,
        user: user,
      );
      // Solicitar permiso y registrar token FCM tras login exitoso
      final granted = await FcmService.requestPermission();
      if (granted) {
        await FcmService.registerToken(_client);
      }
      // Solicitar permisos de ubicación para el tracking GPS
      await _requestLocationPermissions();
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> logout() async {
    // Eliminar token FCM antes de cerrar sesión
    await FcmService.unregisterToken(_client);
    await _repository.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Persiste y actualiza el usuario en memoria (tras perfil, foto, etc.).
  Future<void> updateSessionUser(AuthUser user) async {
    await _repository.persistUser(user);
    state = state.copyWith(user: user);
  }

  /// Requests foreground location permission, then background location (Android 10+).
  Future<void> _requestLocationPermissions() async {
    try {
      var status = await Geolocator.checkPermission();
      if (status == LocationPermission.denied) {
        status = await Geolocator.requestPermission();
      }
      // Request background permission separately (Android 10+ requires it after foreground)
      if (status == LocationPermission.whileInUse) {
        await Geolocator.requestPermission();
      }
    } catch (_) {
      // Permission errors should not block login flow
    }
  }
}

final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    ref.watch(authRepositoryProvider),
    ref.watch(dioClientProvider),
  );
});
