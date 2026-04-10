import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/api/dio_client.dart';
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
    _checkSession();
  }

  Future<void> _checkSession() async {
    state = state.copyWith(status: AuthStatus.loading);
    try {
      final hasSession = await _repository.hasValidSession();
      if (hasSession) {
        final user = await _repository.getStoredUser();
        state = state.copyWith(
          status: AuthStatus.authenticated,
          user: user,
        );
      } else {
        state = state.copyWith(status: AuthStatus.unauthenticated);
      }
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
