import 'dart:async';
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
import '../../features/leaves/employee_leaves_screen.dart';
import '../../features/leaves/employee_leave_notices.dart';
import '../../features/leaves/employee_leave.dart';

const _routeLogin = '/login';
const _routeStarting = '/starting';
const routeUpdateRequired = '/update-required';
const _routeHome = '/';
const routeForgotPassword = '/forgot-password';
const routeProfile = '/profile';
const routeBusinessDocuments = '/documents';
const routeEmployeeLeaves = '/permisos';
final rootNavigatorKey = GlobalKey<NavigatorState>();

String? deliveryAuthRedirect(AuthStatus status, String location) {
  final isAuthenticated = status == AuthStatus.authenticated;
  final isLoading = status == AuthStatus.initial || status == AuthStatus.loading;
  final isLoginRoute = location == _routeLogin;
  final isStartingRoute = location == _routeStarting;
  final isUpdateRoute = location == routeUpdateRequired;
  final isPublicAuthRoute = isLoginRoute || location == routeForgotPassword;
  if (isLoading) return isStartingRoute ? null : _routeStarting;
  if (status == AuthStatus.updateRequired) return isUpdateRoute ? null : routeUpdateRequired;
  if (isUpdateRoute || isStartingRoute) return isAuthenticated ? _routeHome : _routeLogin;
  if (!isAuthenticated && !isPublicAuthRoute) return _routeLogin;
  if (isAuthenticated && isLoginRoute) return _routeHome;
  return null;
}

/// Mantiene la misma instancia durante login/refresh; no inicia Home sin autenticación.
class _RouterRefresh extends ChangeNotifier {
  void notifyAuthChanged() => notifyListeners();
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh();
  ref.onDispose(refresh.dispose);
  String? pendingPath;
  void captureNotice() {
    final auth = ref.read(authNotifierProvider);
    if (auth.status != AuthStatus.authenticated || auth.user == null) return;
    final notice = EmployeeLeaveNotices.takeFor(auth.user!.id);
    if (notice != null) pendingPath = '$routeEmployeeLeaves/${notice.requestId}';
  }
  ref.listen<AuthState>(authNotifierProvider, (prev, next) {
    if (prev?.user != null && prev?.user?.id != next.user?.id) {
      pendingPath = null; EmployeeLeaveNotices.clear();
    }
    if (next.status == AuthStatus.loading) {
      final previous = prev?.status;
      if (previous == AuthStatus.unauthenticated || previous == AuthStatus.initial) return;
    }
    captureNotice(); refresh.notifyAuthChanged();
  });
  final notices = EmployeeLeaveNotices.opened.listen((_) {
    captureNotice(); refresh.notifyAuthChanged();
  });
  ref.onDispose(() => unawaited(notices.cancel()));
  captureNotice();

  final router = GoRouter(
    navigatorKey: rootNavigatorKey, refreshListenable: refresh, initialLocation: _routeStarting,
    redirect: (context, state) {
      final auth = ref.read(authNotifierProvider);
      captureNotice();
      if (auth.status == AuthStatus.authenticated && pendingPath != null) {
        final target = pendingPath!; pendingPath = null;
        return state.matchedLocation == target ? null : target;
      }
      return deliveryAuthRedirect(auth.status, state.matchedLocation);
    },
    routes: [
      GoRoute(path: _routeStarting, builder: (_, __) => const Scaffold(backgroundColor: Color(0xFF121212), body: Center(child: CircularProgressIndicator()))),
      GoRoute(path: routeUpdateRequired, builder: (_, __) => const DeliveryAppUpdateRequiredScreen()),
      // La jerarquía da regreso a bandeja e Inicio incluso al abrir FCM con la app cerrada.
      GoRoute(path: _routeHome, builder: (_, __) => const HomeScreen(), routes: [
        GoRoute(path: 'permisos', builder: (_, __) => EmployeeLeavesScreen(key: ValueKey(ref.read(authNotifierProvider).user?.id)), routes: [
          GoRoute(path: ':publicId', builder: (_, state) {
            final id = state.pathParameters['publicId'] ?? '';
            if (!isLeaveId(id)) return const Scaffold(body: Center(child: Text('No encontramos esta solicitud.')));
            return EmployeeLeaveDetailScreen(publicId: id.toLowerCase(), key: ValueKey('${ref.read(authNotifierProvider).user?.id}:$id'));
          }),
        ]),
      ]),
      GoRoute(path: routeProfile, builder: (_, __) => const ProfileScreen()),
      GoRoute(path: routeBusinessDocuments, builder: (_, __) => const BusinessDocumentsScreen()),
      GoRoute(path: _routeLogin, builder: (_, __) => const LoginScreen()),
      GoRoute(path: routeForgotPassword, builder: (_, __) => const ForgotPasswordScreen()),
    ],
    errorBuilder: (_, __) => const Scaffold(backgroundColor: Color(0xFF121212), body: Center(child: Padding(
      padding: EdgeInsets.all(24), child: Text('No encontramos esta página. Vuelve al inicio e inténtalo de nuevo.',
        textAlign: TextAlign.center, style: TextStyle(color: Colors.white))))),
  );
  ref.onDispose(router.dispose);
  return router;
});
