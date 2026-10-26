import 'dart:async';
import '../lunch/employee_lunch.dart';
import '../lunch/employee_lunch_control.dart';
import '../leaves/employee_leaves_screen.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/whatsapp/open_whatsapp.dart';
import '../../core/widgets/app_logo.dart';
import '../../core/widgets/error_banner.dart';
import '../auth/data/auth_models.dart';
import '../auth/presentation/auth_notifier.dart';
import '../available/presentation/available_notifier.dart';
import '../available/presentation/available_screen.dart';
import '../route/presentation/route_notifier.dart';
import '../route/presentation/route_screen.dart';
import '../history/presentation/history_screen.dart';
import '../analytics/presentation/analytics_screen.dart';
import '../orders/models/order_models.dart';
import '../orders/data/order_repository.dart';
import '../profile/data/profile_image_url.dart';
import '../realtime/order_hub_event.dart';
import '../realtime/order_hub_service.dart';
import 'home_resume_policy.dart';
import '../tracking/tracking_status_provider.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  final _visitedTabs = <int>{0};
  bool _initialTabResolved = false;
  HubConnectionStatus _hubStatus = HubConnectionStatus.disconnected;
  OrderHubService? _hubService;
  bool _signalRListenersAttached = false;
  Future<void>? _resumeInFlight;
  Future<void>? _hubConnectInFlight;
  Future<void>? _catchUpInFlight;
  Timer? _hubRetryTimer;
  int _hubRetryAttempts = 0;
  bool _connectedOnce = false;
  bool _missedHubEvents = false;

  static const _screens = [
    AvailableScreen(),
    RouteScreen(),
    HistoryScreen(),
    AnalyticsScreen(),
  ];

  static const _tabs = [
    _TabItem(
        icon: Icons.inbox_outlined,
        activeIcon: Icons.inbox,
        label: 'Disponibles'),
    _TabItem(
        icon: Icons.delivery_dining_outlined,
        activeIcon: Icons.delivery_dining,
        label: 'En ruta'),
    _TabItem(
        icon: Icons.history_outlined,
        activeIcon: Icons.history,
        label: 'Historial'),
    _TabItem(
        icon: Icons.bar_chart_outlined,
        activeIcon: Icons.bar_chart,
        label: 'Métricas'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted)
        unawaited(
            ref.read(routeNotifierProvider.notifier).load(silently: true));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Un frame más para que el árbol y `ref` queden listos antes de SignalR.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _connectSignalR();
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_resumeAfterBackground());
    } else {
      ref.read(availableNotifierProvider.notifier).setRoutingActive(false);
    }
  }

  Future<void> _resumeAfterBackground() {
    final current = _resumeInFlight;
    if (current != null) return current;
    final operation = _onResumed();
    _resumeInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_resumeInFlight, operation)) _resumeInFlight = null;
    });
  }

  Future<void> _onResumed() async {
    await ref.read(employeeLunchProvider.notifier).refresh();
    await ref
        .read(authNotifierProvider.notifier)
        .refreshSessionIfNeededAfterResume();
    if (!mounted) return;
    final auth = ref.read(authNotifierProvider);
    if (!shouldConnectOrderHub(
      authenticated: auth.status == AuthStatus.authenticated,
      workSession: auth.workSession,
    )) {
      await _disconnectSignalR();
      return;
    }
    await _connectSignalR();
    if (!mounted) return;
    unawaited(ref.read(routeNotifierProvider.notifier).load(silently: true));
    unawaited(ref
        .read(availableNotifierProvider.notifier)
        .loadRouting(silently: true, ensureFresh: true));
    final catchUp = _catchUpInFlight;
    if (catchUp != null) {
      await catchUp;
      return;
    }
    switch (homeResumeRefreshForTab(_currentIndex)) {
      case HomeResumeRefresh.available:
        await ref
            .read(availableNotifierProvider.notifier)
            .loadAll(silently: true);
        break;
      case HomeResumeRefresh.route:
        await ref.read(routeNotifierProvider.notifier).load(silently: true);
        break;
      case HomeResumeRefresh.none:
        break;
    }
  }

  Future<void> _connectSignalR() {
    final current = _hubConnectInFlight;
    if (current != null) return current;
    final operation = _connectSignalRInternal();
    _hubConnectInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_hubConnectInFlight, operation)) {
        _hubConnectInFlight = null;
      }
    });
  }

  Future<void> _connectSignalRInternal() async {
    final auth = ref.read(authNotifierProvider);
    final user = auth.user;
    if (user == null ||
        !shouldConnectOrderHub(
          authenticated: auth.status == AuthStatus.authenticated,
          workSession: auth.workSession,
        )) {
      await _disconnectSignalR();
      return;
    }

    // Guardamos la referencia para poder usarla en dispose() sin tocar ref
    _hubService = ref.read(orderHubServiceProvider);
    if (!_signalRListenersAttached) {
      _hubService!.addStatusListener(_onHubStatusChange);
      _hubService!.addEventListener(_onHubEvent);
      _signalRListenersAttached = true;
    }
    // El grupo de sucursal lo determina el JWT autenticado.
    ref.read(availableNotifierProvider.notifier).setRoutingActive(
        WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed);
    await _hubService!.connect();
    final latest = ref.read(authNotifierProvider);
    if (!shouldConnectOrderHub(
      authenticated: latest.status == AuthStatus.authenticated,
      workSession: latest.workSession,
    )) {
      await _disconnectSignalR();
    }
  }

  Future<void> _disconnectSignalR() async {
    if (mounted) {
      ref.read(availableNotifierProvider.notifier).setRoutingActive(false);
    }
    await _hubService?.disconnect();
    if (mounted && _hubStatus != HubConnectionStatus.disconnected) {
      setState(() => _hubStatus = HubConnectionStatus.disconnected);
    }
  }

  void _onHubStatusChange(HubConnectionStatus status) {
    if (!mounted) return;
    if (_hubStatus != status) setState(() => _hubStatus = status);

    if (status == HubConnectionStatus.connected) {
      unawaited(ref.read(employeeLunchProvider.notifier).refresh());
      _hubRetryTimer?.cancel();
      _hubRetryTimer = null;
      _hubRetryAttempts = 0;
      if (_missedHubEvents) {
        _missedHubEvents = false;
        unawaited(_catchUpAfterReconnect());
      }
      _connectedOnce = true;
    } else {
      if (_connectedOnce || status == HubConnectionStatus.error) {
        _missedHubEvents = true;
      }
      if (status == HubConnectionStatus.disconnected ||
          status == HubConnectionStatus.error) {
        _scheduleHubRetry();
      }
    }
  }

  void _scheduleHubRetry() {
    if (_hubRetryTimer?.isActive == true || !mounted) return;
    final auth = ref.read(authNotifierProvider);
    if (!shouldConnectOrderHub(
      authenticated: auth.status == AuthStatus.authenticated,
      workSession: auth.workSession,
    )) {
      return;
    }
    final index = _hubRetryAttempts < 4 ? _hubRetryAttempts : 4;
    final delay = [5, 10, 20, 40, 60][index];
    if (_hubRetryAttempts < 4) _hubRetryAttempts++;
    _hubRetryTimer = Timer(Duration(seconds: delay), () {
      _hubRetryTimer = null;
      if (mounted) unawaited(_connectSignalR());
    });
  }

  Future<void> _catchUpAfterReconnect() {
    final current = _catchUpInFlight;
    if (current != null) return current;
    final operation = Future.wait([
      ref
          .read(availableNotifierProvider.notifier)
          .load(silently: true, ensureFresh: true),
      ref
          .read(availableNotifierProvider.notifier)
          .loadRouting(silently: true, ensureFresh: true),
      ref
          .read(routeNotifierProvider.notifier)
          .load(silently: true, ensureFresh: true),
    ]).then((_) {});
    _catchUpInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_catchUpInFlight, operation)) _catchUpInFlight = null;
    });
  }

  void _onHubEvent(String event, List<Object?>? args) {
    if (!mounted) return;
    if (event == 'EmployeeLunchChanged') {
      unawaited(ref.read(employeeLunchProvider.notifier).refresh());
      unawaited(ref
          .read(availableNotifierProvider.notifier)
          .loadRouting(silently: true, ensureFresh: true));
      return;
    }
    unawaited(_handleHubEvent(event, args));
  }

  Future<void> _handleHubEvent(String event, List<Object?>? args) async {
    if (!mounted) return;
    final available = ref.read(availableNotifierProvider.notifier);
    final kind = classifyOrderHubEvent(event);

    if (kind == OrderHubEventKind.routing) {
      await available
          .routingPlanChanged(routingPlanVersionFromHubEvent(event, args));
      return;
    }
    if (kind == OrderHubEventKind.ignored) return;

    final order = orderFromHubEvent(event, args);
    if (order == null) {
      // Recover once if the event payload cannot be parsed.
      if (kind == OrderHubEventKind.ready ||
          kind == OrderHubEventKind.assigned) {
        await Future.wait([
          available.refreshReadyOrders(),
          ref
              .read(routeNotifierProvider.notifier)
              .load(silently: true, ensureFresh: true),
        ]);
      }
      return;
    }

    if (kind == OrderHubEventKind.ready) {
      await available.refreshReadyOrders();
      return;
    }

    // Update the existing route immediately; plan recovery runs independently.
    // The notifier removes assigned/delivered/cancelled orders from all plan lists.
    unawaited(available.reconcileRoutingOrder(order));
    final change = await ref
        .read(routeNotifierProvider.notifier)
        .applyRealtimeOrder(order);
    if (!mounted || change == RouteOrderChange.none) return;
    _showRouteChangeNotice(order, change);
  }

  void _showRouteChangeNotice(Order order, RouteOrderChange change) {
    final userId = ref.read(authNotifierProvider).user?.id;
    final message = switch (change) {
      RouteOrderChange.added => 'Pedido #${order.id} agregado a tu ruta.',
      RouteOrderChange.updated =>
        'La sucursal actualizó el pedido #${order.id}.',
      RouteOrderChange.removed when order.status == OrderStatus.cancelled =>
        'La sucursal canceló el pedido #${order.id}.',
      RouteOrderChange.removed when order.deliveryManId != userId =>
        'La sucursal reasignó el pedido #${order.id}.',
      RouteOrderChange.removed =>
        'La sucursal actualizó el pedido #${order.id}.',
      RouteOrderChange.none => '',
    };
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.sync_rounded, color: AppColors.info, size: 20),
            const SizedBox(width: AppTheme.spacingSm),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.cardElevated,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// IndexedStack no vuelve a ejecutar `initState` de cada pestaña al cambiar.
  void _onTabChanged(int index) {
    _initialTabResolved = true;
    if (index == _currentIndex) return;
    setState(() {
      _currentIndex = index;
      _visitedTabs.add(index);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hubRetryTimer?.cancel();
    if (_signalRListenersAttached && _hubService != null) {
      _hubService!.removeStatusListener(_onHubStatusChange);
      _hubService!.removeEventListener(_onHubEvent);
      unawaited(_hubService!.disconnect());
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
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLg)),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
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
                leading: const Icon(Icons.description_outlined,
                    color: AppColors.primaryLight),
                title: const Text('Documentos'),
                subtitle: const Text('Reglamentos y políticas'),
                onTap: () {
                  Navigator.pop(ctx);
                  navContext.push(routeBusinessDocuments);
                },
              ),
              ListTile(
                leading: const Icon(Icons.person_outline,
                    color: AppColors.primaryLight),
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
                onTap: () async {
                  final pending = await ref
                      .read(orderRepositoryProvider)
                      .operations
                      .pending();
                  if (!ctx.mounted) return;
                  if (pending.isNotEmpty) {
                    final leave = await showDialog<bool>(
                        context: ctx,
                        builder: (dialog) => AlertDialog(
                                title: const Text('Hay cambios pendientes'),
                                content: Text(
                                    'Hay ${pending.length} acciones sin confirmar. Se conservarán para esta cuenta.'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialog, false),
                                      child: const Text('Volver')),
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialog, true),
                                      child: const Text(
                                          'Cerrar sesión y conservar'))
                                ]));
                    if (leave != true || !ctx.mounted) return;
                  }
                  Navigator.pop(ctx);
                  await ref.read(authNotifierProvider.notifier).logout();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _currentTitle => _tabs[_currentIndex].label;

  Future<void> _openBranchWhatsApp(AuthUser? user) async {
    final raw = user?.branchWhatsAppTarget;
    if (raw == null) return;
    final ok = await openWhatsAppChat(raw);
    if (!mounted) return;
    if (!ok) {
      ErrorBanner.show(context, 'No pudimos abrir WhatsApp.');
    }
  }

  List<Widget> _branchWhatsAppActions(AuthUser? user) {
    if (user == null || user.branchWhatsAppTarget == null) {
      return const [];
    }
    final name = user.branchName;
    return [
      Tooltip(
        message: name != null && name.isNotEmpty
            ? 'WhatsApp: $name'
            : 'WhatsApp sucursal',
        child: IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
          splashRadius: 20,
          onPressed: () => _openBranchWhatsApp(user),
          icon: const FaIcon(
            FontAwesomeIcons.whatsapp,
            size: 22,
            color: Color(0xFF25D366),
          ),
        ),
      ),
      const SizedBox(width: 4),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);
    ref.watch(routeNotifierProvider);
    ref.listen<RouteState>(routeNotifierProvider, (_, next) {
      if (_initialTabResolved || next.revision < 0) return;
      _initialTabResolved = true;
      if (next.routeId != null && mounted) {
        setState(() { _currentIndex = 1; _visitedTabs.add(1); });
      }
    });
    ref.listen<AuthState>(
      authNotifierProvider,
      (prev, next) {
        if (!mounted) return;
        final shouldConnect = shouldConnectOrderHub(
          authenticated: next.status == AuthStatus.authenticated,
          workSession: next.workSession,
        );
        if (!shouldConnect) {
          unawaited(_disconnectSignalR());
          return;
        }
        final wasConnectedEligible = prev != null &&
            shouldConnectOrderHub(
              authenticated: prev.status == AuthStatus.authenticated,
              workSession: prev.workSession,
            );
        if (!wasConnectedEligible) _connectSignalR();
      },
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Row(
          children: [
            const AppLogo(size: 28),
            const SizedBox(width: AppTheme.spacingSm),
            Expanded(
                child: Text(_currentTitle, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          const EmployeeLeaveButton(),
          const EmployeeLunchButton(),
          ..._branchWhatsAppActions(authState.user),
          _HubStatusIndicator(status: _hubStatus),
          const SizedBox(width: AppTheme.spacingSm),
          IconButton(
            padding: EdgeInsets.zero,
            splashRadius: 22,
            onPressed: _showProfileMenu,
            icon: _ProfileAppBarAvatar(user: authState.user),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TrackingStatusBanner(
            authState: authState,
            onOpenSettings: () =>
                ref.read(authNotifierProvider.notifier).openTrackingSettings(),
          ),
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: [
                for (var i = 0; i < _screens.length; i++)
                  TickerMode(
                      enabled: i == _currentIndex,
                      child: _visitedTabs.contains(i)
                          ? _screens[i]
                          : const SizedBox.shrink()),
              ],
            ),
          ),
        ],
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

class _TrackingStatusBanner extends ConsumerWidget {
  const _TrackingStatusBanner(
      {required this.authState, required this.onOpenSettings});
  final AuthState authState;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = authState.workSession;
    if (session == null)
      return Material(
        color: AppColors.warning.withValues(alpha: 0.12),
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              Expanded(
                  child: Text(authState.trackingIssue ??
                      'Preparando jornada y seguimiento...')),
              TextButton(
                  onPressed: () => ref
                      .read(authNotifierProvider.notifier)
                      .startWorkSession(),
                  child: const Text('Iniciar jornada')),
            ])),
      );
    final snapshot =
        ref.watch(trackingSnapshotProvider(session.id)).asData?.value;
    final tracking = session.isActive &&
        DateTime.now().isBefore(session.autoCloseAt) &&
        snapshot?.healthyAt(DateTime.now()) == true;
    final issue = snapshot == null
        ? authState.trackingIssue
        : snapshot.captureIssue ?? snapshot.uploadIssue;
    final settingsIssue = issue != null &&
        (issue.contains('GPS') ||
            issue.contains('permiso') ||
            issue.contains('precisa'));
    final label = issue ??
        snapshot?.labelAt(DateTime.now()) ??
        'Comprobando el último envío de ubicación';
    final color = tracking ? AppColors.success : AppColors.warning;
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingMd, vertical: AppTheme.spacingXs),
      child: Row(children: [
        Icon(tracking ? Icons.location_on : Icons.location_off,
            size: 16, color: color),
        const SizedBox(width: AppTheme.spacingXs),
        Expanded(
            child: Text(label,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w600))),
        if (settingsIssue)
          SizedBox(
              width: 112,
              child: TextButton(
                  onPressed: onOpenSettings,
                  child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [Text('Abrir Ajustes')]))),
      ]),
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
                            child: CircularProgressIndicator(strokeWidth: 2)))),
                errorWidget: (_, __, ___) => _fallbackAvatar(initials)))
        : _fallbackAvatar(initials);
    return SizedBox(width: 36, height: 36, child: child);
  }

  Widget _fallbackAvatar(String initials) {
    final letter = initials.isNotEmpty ? initials : '?';
    return CircleAvatar(
        radius: 18,
        backgroundColor: AppColors.primaryContainer,
        foregroundColor: AppColors.primaryLight,
        child: letter.length <= 2
            ? Text(letter, style: const TextStyle(fontWeight: FontWeight.w600))
            : const Icon(Icons.person_outline, size: 22));
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
  const _TabItem(
      {required this.icon, required this.activeIcon, required this.label});
}

class _HubStatusIndicator extends StatelessWidget {
  final HubConnectionStatus status;
  const _HubStatusIndicator({required this.status});

  @override
  Widget build(BuildContext context) {
    final connected = status == HubConnectionStatus.connected;
    final connecting = status == HubConnectionStatus.connecting;
    final color = connected
        ? AppColors.success
        : connecting
            ? AppColors.warning
            : AppColors.error;
    return Tooltip(
        message: connected
            ? 'Conectado en tiempo real'
            : connecting
                ? 'Conectando...'
                : 'Sin conexión en tiempo real',
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
            child: Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle))));
  }
}
