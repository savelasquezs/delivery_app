import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/auth_notifier.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/home/home_screen.dart';

const _routeLogin = '/login';
const _routeHome = '/';

final appRouterProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authNotifierProvider);

  return GoRouter(
    initialLocation: _routeHome,
    redirect: (context, state) {
      final isAuthenticated = authState.status == AuthStatus.authenticated;
      final isLoading = authState.status == AuthStatus.initial ||
          authState.status == AuthStatus.loading;
      final isLoginRoute = state.matchedLocation == _routeLogin;

      if (isLoading) return null;
      if (!isAuthenticated && !isLoginRoute) return _routeLogin;
      if (isAuthenticated && isLoginRoute) return _routeHome;
      return null;
    },
    routes: [
      GoRoute(
        path: _routeHome,
        builder: (_, __) => const HomeScreen(),
      ),
      GoRoute(
        path: _routeLogin,
        builder: (_, __) => const LoginScreen(),
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
