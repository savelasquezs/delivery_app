import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/auth_notifier.dart';
import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/delivery_app_update_required_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/documents/presentation/business_documents_screen.dart';

const _routeLogin = '/login';
const _routeStarting = '/starting';
const routeUpdateRequired = '/update-required';
const _routeHome = '/';
const routeForgotPassword = '/forgot-password';
const routeProfile = '/profile';
const routeBusinessDocuments = '/documents';
final rootNavigatorKey = GlobalKey<NavigatorState>();

String? deliveryAuthRedirect(AuthStatus status, String location) {
  final isAuthenticated = status == AuthStatus.authenticated;
  final isLoading =
      status == AuthStatus.initial || status == AuthStatus.loading;
  final isLoginRoute = location == _routeLogin;
  final isStartingRoute = location == _routeStarting;
  final isUpdateRoute = location == routeUpdateRequired;
  final isPublicAuthRoute = isLoginRoute || location == routeForgotPassword;

  if (isLoading) return isStartingRoute ? null : _routeStarting;
  if (status == AuthStatus.updateRequired) {
    return isUpdateRoute ? null : routeUpdateRequired;
  }
  if (isUpdateRoute || isStartingRoute) {
    return isAuthenticated ? _routeHome : _routeLogin;
  }
  if (!isAuthenticated && !isPublicAuthRoute) return _routeLogin;
  if (isAuthenticated && isLoginRoute) return _routeHome;
  return null;
}

/// Evita recrear [GoRouter] en cada `AuthStatus.loading` (p. ej. al pulsar login):
/// una nueva instancia con `initialLocation: /` montaba Home y disparaba APIs sin token.
class _RouterRefresh extends ChangeNotifier {
  void notifyAuthChanged() => notifyListeners();
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh();
  ref.onDispose(refresh.dispose);

  ref.listen<AuthState>(authNotifierProvider, (prev, next) {
    if (next.status == AuthStatus.loading) {
      final p = prev?.status;
      if (p == AuthStatus.unauthenticated || p == AuthStatus.initial) {
        return;
      }
    }
    refresh.notifyAuthChanged();
  });

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    refreshListenable: refresh,
    initialLocation: _routeStarting,
    redirect: (context, state) {
      final authState = ref.read(authNotifierProvider);
      return deliveryAuthRedirect(
        authState.status,
        state.matchedLocation,
      );
    },
    routes: [
      GoRoute(
        path: _routeStarting,
        builder: (_, __) => const Scaffold(
          backgroundColor: Color(0xFF121212),
          body: Center(child: CircularProgressIndicator()),
        ),
      ),
      GoRoute(
        path: routeUpdateRequired,
        builder: (_, __) => const DeliveryAppUpdateRequiredScreen(),
      ),
      GoRoute(
        path: _routeHome,
        builder: (_, __) => const HomeScreen(),
      ),
      GoRoute(
        path: routeProfile,
        builder: (_, __) => const ProfileScreen(),
      ),
      GoRoute(
        path: routeBusinessDocuments,
        builder: (_, __) => const BusinessDocumentsScreen(),
      ),
      GoRoute(
        path: _routeLogin,
        builder: (_, __) => const LoginScreen(),
      ),
      GoRoute(
        path: routeForgotPassword,
        builder: (_, __) => const ForgotPasswordScreen(),
      ),
    ],
    errorBuilder: (_, __) => const Scaffold(
      backgroundColor: Color(0xFF121212),
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No encontramos esta página. Vuelve al inicio e inténtalo de nuevo.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white),
          ),
        ),
      ),
    ),
  );
});
