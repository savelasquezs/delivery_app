import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api/api_constants.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_logo.dart';
import '../auth/presentation/auth_notifier.dart';
import '../available/presentation/available_notifier.dart';
import '../available/presentation/available_screen.dart';
import '../route/presentation/route_notifier.dart';
import '../route/presentation/route_screen.dart';
import '../history/presentation/history_screen.dart';
import '../analytics/presentation/analytics_screen.dart';
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
    _connectSignalR();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _restartTrackingIfNeeded();
    }
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

  Future<void> _connectSignalR() async {
    final user = ref.read(authNotifierProvider).user;
    if (user?.branchId == null) return;

    // Guardamos la referencia para poder usarla en dispose() sin tocar ref
    _hubService = ref.read(orderHubServiceProvider);
    _hubService!.addStatusListener(_onHubStatusChange);
    _hubService!.addEventListener(_onHubEvent);
    await _hubService!.connect(user!.branchId!);
  }

  void _onHubStatusChange(HubConnectionStatus status) {
    if (mounted) setState(() => _hubStatus = status);
  }

  void _onHubEvent(String event, List<Object?>? args) {
    if (!mounted) return;
    if (event == 'OrderReady' || event == 'OrderAssignedToDelivery') {
      ref.invalidate(availableNotifierProvider);
    }
    if (event == 'OrderStatusChanged') {
      ref.invalidate(routeNotifierProvider);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hubService?.removeStatusListener(_onHubStatusChange);
    _hubService?.removeEventListener(_onHubEvent);
    super.dispose();
  }

  void _showProfileMenu() {
    final user = ref.read(authNotifierProvider).user;
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
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: _showProfileMenu,
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
          onTap: (index) => setState(() => _currentIndex = index),
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

