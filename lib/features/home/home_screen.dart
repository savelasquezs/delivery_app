import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/router/app_router.dart';
import '../../core/api/api_constants.dart';
import '../../core/updates/app_update_prefs.dart';
import '../../core/updates/app_update_provider.dart';
import '../../core/updates/delivery_app_release_manifest.dart';
import '../../core/updates/app_update_widgets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/whatsapp/open_whatsapp.dart';
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

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  int? _dismissedRemoteBuild;
  int? _shownUpdatePromptBuild;
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final d = await getDismissedUpdateRemoteBuild();
      if (mounted) setState(() => _dismissedRemoteBuild = d);
      if (!mounted) return;
      // Un frame más para que el árbol y `ref` queden listos antes de SignalR.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _connectSignalR();
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(appUpdateCheckProvider);
      unawaited(_onResumed());
    }
  }

  /// Renueva el access si hace falta y reconecta SignalR con token fresco (storage).
  Future<void> _onResumed() async {
    await ref
        .read(authNotifierProvider.notifier)
        .refreshSessionIfNeededAfterResume();
    if (!mounted) return;
    await _restartTrackingIfNeeded();
    if (!mounted) return;
    await _connectSignalR(forceReconnect: true);
  }

  /// Re-starts location tracking when the app resumes from background,
  /// in case the service was killed by the OS.
  Future<void> _restartTrackingIfNeeded() async {
    if (ref.read(authNotifierProvider).user == null) return;
    await ref.read(routeNotifierProvider.notifier).load();
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

      // Tras invalidar el ruteo, volver a cargar para que `_syncTracking` arranque
      // o detenga el foreground GPS sin exigir abrir la pestaña "En ruta".
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await ref.read(routeNotifierProvider.notifier).load();
      });
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

  Future<void> _openUpdate(Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No se pudo abrir el enlace')),
    );
  }

  Future<void> _onDismissUpdate(AppUpdateCheckResult result) async {
    await setDismissedUpdateRemoteBuild(result.manifest.buildNumber);
    if (mounted) {
      setState(() => _dismissedRemoteBuild = result.manifest.buildNumber);
    }
  }

  bool _shouldShowUpdatePrompt(AppUpdateCheckResult? result) {
    if (result == null) return false;
    final remoteBuild = result.manifest.buildNumber;
    if (_shownUpdatePromptBuild == remoteBuild) return false;
    return _dismissedRemoteBuild != remoteBuild;
  }

  Future<void> _showUpdatePrompt(AppUpdateCheckResult result) async {
    setState(() => _shownUpdatePromptBuild = result.manifest.buildNumber);
    await showAppUpdateDialog(
      context: context,
      result: result,
      onDownload: () => _openUpdate(result.updateUri),
      onDismiss: () => _onDismissUpdate(result),
    );
  }

  Widget _buildUpdateBanner() {
    final async = ref.watch(appUpdateCheckProvider);
    return async.when(
      data: (result) {
        if (result == null) return const SizedBox.shrink();
        final dismissed = _dismissedRemoteBuild;
        if (dismissed != null && dismissed == result.manifest.buildNumber) {
          return const SizedBox.shrink();
        }
        final forced = result.kind == AppUpdateKind.forced;
        final msg = result.manifest.message?.trim();
        return Material(
          color: forced
              ? AppColors.error.withValues(alpha: 0.12)
              : AppColors.primaryContainer,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: forced ? AppColors.warning : AppColors.divider,
                  width: 1,
                ),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingMd,
              AppTheme.spacingSm,
              AppTheme.spacingMd,
              AppTheme.spacingSm,
            ),
            child: SafeArea(
              top: false,
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        forced
                            ? Icons.warning_amber_rounded
                            : Icons.system_update,
                        size: 22,
                        color:
                            forced ? AppColors.warning : AppColors.primaryLight,
                      ),
                      const SizedBox(width: AppTheme.spacingSm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              forced
                                  ? 'Actualización necesaria'
                                  : 'Hay una nueva versión',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(
                                    color: AppColors.onBackground,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            if (msg != null && msg.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                msg,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: AppColors.onSurface,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTheme.spacingSm),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => _onDismissUpdate(result),
                        child: const Text('Más tarde'),
                      ),
                      const SizedBox(width: AppTheme.spacingXs),
                      FilledButton(
                        onPressed: () => _openUpdate(result.updateUri),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.onPrimary,
                        ),
                        child: Text(
                          kPlayDistribution ? 'Actualizar en Play Store' : 'Descargar',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Future<void> _openBranchWhatsApp(AuthUser? user) async {
    final raw = user?.branchWhatsAppTarget;
    if (raw == null) return;
    final ok = await openWhatsAppChat(raw);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp')),
      );
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
    ref.listen<AsyncValue<AppUpdateCheckResult?>>(
      appUpdateCheckProvider,
      (_, next) {
        next.whenData((result) {
          if (!mounted || !_shouldShowUpdatePrompt(result)) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_shouldShowUpdatePrompt(result)) return;
            unawaited(_showUpdatePrompt(result!));
          });
        });
      },
    );

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
          _buildUpdateBanner(),
          _TrackingStatusBanner(authState: authState),
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: _screens,
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

class _TrackingStatusBanner extends StatelessWidget {
  const _TrackingStatusBanner({required this.authState});

  final AuthState authState;

  @override
  Widget build(BuildContext context) {
    final session = authState.workSession;
    if (session == null) return const SizedBox.shrink();
    final tracking = authState.trackingActive;
    final closeTime = session.tracking.autoCloseTime.length >= 5
        ? session.tracking.autoCloseTime.substring(0, 5)
        : session.tracking.autoCloseTime;
    final color = tracking ? AppColors.success : AppColors.warning;

    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingMd,
        vertical: AppTheme.spacingXs,
      ),
      child: Row(
        children: [
          Icon(
            tracking ? Icons.location_on : Icons.location_off,
            size: 16,
            color: color,
          ),
          const SizedBox(width: AppTheme.spacingXs),
          Expanded(
            child: Text(
              tracking
                  ? 'Ubicación monitoreada · cierre $closeTime (Colombia)'
                  : 'Jornada activa · revisa el GPS y los permisos de ubicación',
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
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
