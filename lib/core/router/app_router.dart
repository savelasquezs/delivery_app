import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/auth_notifier.dart';
import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/documents/presentation/business_documents_screen.dart';

const _routeLogin = '/login';
const _routeHome = '/';
const routeForgotPassword = '/forgot-password';
const routeProfile = '/profile';
const routeBusinessDocuments = '/documents';
final rootNavigatorKey = GlobalKey<NavigatorState>();

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
    initialLocation: _routeHome,
    redirect: (context, state) {
      final authState = ref.read(authNotifierProvider);
      final isAuthenticated = authState.status == AuthStatus.authenticated;
      final isLoading = authState.status == AuthStatus.initial ||
          authState.status == AuthStatus.loading;
      final isLoginRoute = state.matchedLocation == _routeLogin;
      final isPublicAuthRoute =
          isLoginRoute || state.matchedLocation == routeForgotPassword;

      if (isLoading) return null;
      if (!isAuthenticated && !isPublicAuthRoute) return _routeLogin;
      if (isAuthenticated && isLoginRoute) return _routeHome;
      return null;
    },
    routes: [
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
    errorBuilder: (_, state) => Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Center(
        child: Text(
          'Página no encontrada: ${state.error}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    ),
  );
});
