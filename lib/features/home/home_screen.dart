import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_constants.dart';
import '../../core/router/app_router.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_logo.dart';
import '../auth/data/auth_models.dart';
import '../auth/presentation/auth_notifier.dart';
import '../available/presentation/available_notifier.dart';
import '../available/presentation/available_screen.dart';
import '../route/presentation/route_notifier.dart';
import '../route/presentation/route_screen.dart';
import '../history/presentation/history_notifier.dart';
import '../history/presentation/history_screen.dart';
import '../analytics/presentation/analytics_notifier.dart';
import '../analytics/presentation/analytics_screen.dart';
import '../profile/data/profile_image_url.dart';
import '../realtime/order_hub_service.dart';
import '../tracking/location_tracking_service.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  HubConnectionStatus _hubStatus = HubConnectionStatus.disconnected;
  OrderHubService? _hubService;
  bool _signalRListenersAttached = false;

  static const _screens = [
    AvailableScreen(),
    RouteScreen(),
    HistoryScreen(),
    AnalyticsScreen(),
  ];

  static const _tabs = [
    _TabItem(icon: Icons.inbox_outlined, activeIcon: Icons.inbox, label: 'Disponibles'),
    _TabItem(icon: Icons.delivery_dining_outlined, activeIcon: Icons.delivery_dining, label: 'En ruta'),
    _TabItem(icon: Icons.history_outlined, activeIcon: Icons.history, label: 'Historial'),
    _TabItem(icon: Icons.bar_chart_outlined, activeIcon: Icons.bar_chart, label: 'Métricas'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _connectSignalR();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _connectSignalR();
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onResumed());
    }
  }

  /// Renueva el access si hace falta y reconecta SignalR con token fresco (storage).
  Future<void> _onResumed() async {
    await ref.read(authNotifierProvider.notifier).refreshSessionIfNeededAfterResume();
    if (!mounted) return;
    await _restartTrackingIfNeeded();
    if (!mounted) return;
    await _connectSignalR(forceReconnect: true);
  }

  /// Re-starts location tracking when the app resumes from background,
  /// in case the service was killed by the OS.
  Future<void> _restartTrackingIfNeeded() async {
    final routeState = ref.read(routeNotifierProvider);
    if (routeState.orders.isEmpty) return;

    final storage = ref.read(secureStorageProvider);
    final token = await storage.getAuthToken();
    if (token == null) return;

    await LocationTrackingService.startTracking(
      authToken: token,
      baseUrl: ApiConstants.baseUrl,
    );
  }

  Future<void> _connectSignalR({bool forceReconnect = false}) async {
    final user = ref.read(authNotifierProvider).user;
    if (user == null) return;

    // Guardamos la referencia para poder usarla en dispose() sin tocar ref
    _hubService = ref.read(orderHubServiceProvider);
    if (!_signalRListenersAttached) {
      _hubService!.addStatusListener(_onHubStatusChange);
      _hubService!.addEventListener(_onHubEvent);
      _signalRListenersAttached = true;
    }
    // El grupo SignalR lo define el JWT (`branch_id`); el parámetro es solo por compatibilidad.
    await _hubService!.connect(
      user.branchId ?? 0,
      forceReconnect: forceReconnect,
    );
  }

  void _onHubStatusChange(HubConnectionStatus status) {
    if (mounted) setState(() => _hubStatus = status);
  }

  void _onHubEvent(String event, List<Object?>? args) {
    if (!mounted) return;
    if (event == 'OrderReady' ||
        event == 'OrderAssigned' ||
        event == 'OrderAssignedToDelivery' ||
        event == 'OrderModified' ||
        event == 'OrderStatusChanged' ||
        event == 'OrderCancelled') {
      ref.invalidate(availableNotifierProvider);
      ref.invalidate(routeNotifierProvider);
      ref.invalidate(historyNotifierProvider);
    }
  }

  /// IndexedStack no vuelve a ejecutar `initState` de cada pestaña al cambiar.
  void _onTabChanged(int index) {
    setState(() => _currentIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (index) {
        case 0:
          ref.read(availableNotifierProvider.notifier).loadAll();
          break;
        case 1:
          ref.read(routeNotifierProvider.notifier).load();
          break;
        case 2:
          ref.read(historyNotifierProvider.notifier).load();
          break;
        case 3:
          ref.read(analyticsNotifierProvider.notifier).load();
          break;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_signalRListenersAttached && _hubService != null) {
      _hubService!.removeStatusListener(_onHubStatusChange);
      _hubService!.removeEventListener(_onHubEvent);
      _signalRListenersAttached = false;
    }
    super.dispose();
  }

  void _showProfileMenu() {
    final user = ref.read(authNotifierProvider).user;
    final navContext = context;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLg)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: AppTheme.spacingLg),
              const AppLogo(size: 56),
              const SizedBox(height: AppTheme.spacingMd),
              Text(
                user?.name ?? '',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                user?.email ?? '',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (user?.branchName != null) ...[
                const SizedBox(height: AppTheme.spacingXs),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    user!.branchName!,
                    style: const TextStyle(
                        color: AppColors.primaryLight, fontSize: 12),
                  ),
                ),
              ],
              const SizedBox(height: AppTheme.spacingLg),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.person_outline, color: AppColors.primaryLight),
                title: const Text('Mi perfil'),
                onTap: () {
                  Navigator.pop(ctx);
                  navContext.push(routeProfile);
                },
              ),
              ListTile(
                leading: const Icon(Icons.logout, color: AppColors.error),
                title: const Text('Cerrar sesión',
                    style: TextStyle(color: AppColors.error)),
                onTap: () {
                  Navigator.pop(ctx);
                  ref.read(authNotifierProvider.notifier).logout();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _currentTitle => _tabs[_currentIndex].label;

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(
      authNotifierProvider,
      (prev, next) {
        if (!mounted || next.user == null) return;
        final prevUserMissing = prev == null || prev.user == null;
        final becameAuthenticated = next.status == AuthStatus.authenticated &&
            (prev == null || prev.status != AuthStatus.authenticated);
        if (!prevUserMissing && !becameAuthenticated) return;
        _connectSignalR();
      },
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Row(
          children: [
            const AppLogo(size: 28),
            const SizedBox(width: AppTheme.spacingSm),
            Text(_currentTitle),
          ],
        ),
        actions: [
          _HubStatusIndicator(status: _hubStatus),
          const SizedBox(width: AppTheme.spacingSm),
          IconButton(
            padding: EdgeInsets.zero,
            splashRadius: 22,
            onPressed: _showProfileMenu,
            icon: _ProfileAppBarAvatar(user: ref.watch(authNotifierProvider).user),
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: _onTabChanged,
          items: _tabs
              .map((tab) => BottomNavigationBarItem(
                    icon: Icon(tab.icon),
                    activeIcon: Icon(tab.activeIcon),
                    label: tab.label,
                  ))
              .toList(),
        ),
      ),
    );
  }
}

class _ProfileAppBarAvatar extends StatelessWidget {
  const _ProfileAppBarAvatar({required this.user});

  final AuthUser? user;

  @override
  Widget build(BuildContext context) {
    final url = resolveProfileImageUrl(user?.profileImageUrl);
    final initials = _initialsFromName(user?.name ?? user?.email ?? '');

    final child = url != null && url.isNotEmpty
        ? ClipOval(
            child: CachedNetworkImage(
              imageUrl: url,
              width: 36,
              height: 36,
              fit: BoxFit.cover,
              placeholder: (_, __) => const SizedBox(
                width: 36,
                height: 36,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              errorWidget: (_, __, ___) => _fallbackAvatar(initials),
            ),
          )
        : _fallbackAvatar(initials);

    return SizedBox(
      width: 36,
      height: 36,
      child: child,
    );
  }

  Widget _fallbackAvatar(String initials) {
    final letter = initials.isNotEmpty ? initials : '?';
    return CircleAvatar(
      radius: 18,
      backgroundColor: AppColors.primaryContainer,
      foregroundColor: AppColors.primaryLight,
      child: letter.length <= 2
          ? Text(letter, style: const TextStyle(fontWeight: FontWeight.w600))
          : const Icon(Icons.person_outline, size: 22),
    );
  }

  static String _initialsFromName(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '';
    if (parts.length == 1) {
      final p = parts.first;
      return p.length >= 2 ? p.substring(0, 2).toUpperCase() : p.toUpperCase();
    }
    return (parts.first[0] + parts.elementAt(1)[0]).toUpperCase();
  }
}

class _TabItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _TabItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

class _HubStatusIndicator extends StatelessWidget {
  final HubConnectionStatus status;
  const _HubStatusIndicator({required this.status});

  @override
  Widget build(BuildContext context) {
    final isConnected = status == HubConnectionStatus.connected;
    final isConnecting = status == HubConnectionStatus.connecting;

    return Tooltip(
      message: isConnected
          ? 'Conectado en tiempo real'
          : isConnecting
              ? 'Conectando...'
              : 'Sin conexión en tiempo real',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
        child: isConnecting
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppColors.warning),
              )
            : Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isConnected ? AppColors.success : AppColors.error,
                  shape: BoxShape.circle,
                ),
              ),
      ),
    );
  }
}

