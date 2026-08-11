import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/maps/open_delivery_destination_maps.dart';
import '../../../core/orders/available_orders_layout.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/empty_state_widget.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/widgets/confirm_password_dialog.dart';
import '../../orders/models/order_models.dart';
import '../data/branch_presence_verifier.dart';
import 'available_notifier.dart';
import '../../routing/delivery_routing_models.dart';

Future<void> _openOrderDestinationMap(BuildContext context, Order order) async {
  if (!orderHasOpenableMapDestination(order)) {
    if (!context.mounted) return;
    ErrorBanner.show(
      context,
      'Este pedido no tiene dirección ni coordenadas para abrir el mapa.',
    );
    return;
  }
  final ok = await openDeliveryDestinationInMaps(order);
  if (!ok && context.mounted) {
    ErrorBanner.show(context, 'No pudimos abrir Google Maps.');
  }
}

class AvailableScreen extends ConsumerStatefulWidget {
  const AvailableScreen({super.key});

  @override
  ConsumerState<AvailableScreen> createState() => _AvailableScreenState();
}

class _AvailableScreenState extends ConsumerState<AvailableScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final Set<int> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(availableNotifierProvider.notifier).loadAll();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _toggleSelection(int orderId) {
    setState(() {
      if (_selectedIds.contains(orderId)) {
        _selectedIds.remove(orderId);
      } else {
        _selectedIds.add(orderId);
      }
    });
  }

  void _toggleNeighborhoodSelection(List<int> orderIds) {
    if (orderIds.isEmpty) return;
    setState(() {
      final allSelected = orderIds.every((id) => _selectedIds.contains(id));
      if (allSelected) {
        for (final id in orderIds) {
          _selectedIds.remove(id);
        }
      } else {
        for (final id in orderIds) {
          _selectedIds.add(id);
        }
      }
    });
  }

  Future<void> _confirmAssignment() async {
    if (_selectedIds.isEmpty) return;
    final selectedList = List<int>.from(_selectedIds);
    final storage = ref.read(secureStorageProvider);
    final savedPassword = await storage.getSelfAssignPassword();
    if (!mounted) return;

    final confirmed = await ConfirmPasswordDialog.show(
      context,
      title: 'Confirmar asignación',
      subtitle:
          'Se asignarán ${selectedList.length} pedido(s) a tu nombre. Ingresa tu contraseña para continuar.',
      initialPassword: savedPassword,
      onPersistPassword: (password, remember) async {
        if (remember) {
          await storage.saveSelfAssignPassword(password);
        } else {
          await storage.deleteSelfAssignPassword();
        }
      },
      onConfirm: (password) async {
        await ref.read(availableNotifierProvider.notifier).selfAssign(
              orderIds: selectedList,
              password: password,
            );
      },
    );

    if (confirmed && mounted) {
      setState(() => _selectedIds.clear());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pedido(s) asignado(s) exitosamente ✓'),
          backgroundColor: AppColors.accentContainer,
        ),
      );
      ref.read(availableNotifierProvider.notifier).load();
    }
  }

  Future<void> _confirmRoutingProposal(DeliveryRouteProposal proposal) async {
    if (proposal.claimableReadyOrderIds.isEmpty) return;
    final plan = ref.read(availableNotifierProvider).routingPlan;
    if (plan == null) return;
    final storage = ref.read(secureStorageProvider);
    final savedPassword = await storage.getSelfAssignPassword();
    if (!mounted) return;
    final confirmed = await ConfirmPasswordDialog.show(
      context,
      title: 'Tomar ruta ${proposal.sequence}',
      subtitle:
          'Se asignarán ${proposal.claimableReadyOrderIds.length} pedido(s) listos en el orden sugerido.',
      initialPassword: savedPassword,
      onPersistPassword: (password, remember) async {
        if (remember) {
          await storage.saveSelfAssignPassword(password);
        } else {
          await storage.deleteSelfAssignPassword();
        }
      },
      onConfirm: (password) =>
          ref.read(availableNotifierProvider.notifier).selfAssign(
                orderIds: proposal.claimableReadyOrderIds,
                password: password,
                proposalId: proposal.id,
                expectedPlanVersion: plan.version,
              ),
    );
    if (confirmed && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Ruta asignada exitosamente ✓'),
        backgroundColor: AppColors.accentContainer,
      ));
      await ref.read(availableNotifierProvider.notifier).loadAll();
    }
  }

  Future<void> _refreshAll() =>
      ref.read(availableNotifierProvider.notifier).loadAll();

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(availableNotifierProvider);
    final isAvailableTab = _tabController.index == 0;
    final preparationEmpty = _preparationEmptyContent(state.branchPresence);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _OrderTabBar(
            controller: _tabController,
            availableCount: state.orders.length,
            prepCount: state.preparationOrders.length,
            routeCount: state.routingPlan?.proposals.length ?? 0,
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _OrderTabContent(
                  orders: state.orders,
                  isLoading: state.isLoading,
                  error: state.error,
                  emptyIcon: Icons.inbox_outlined,
                  emptyTitle: 'Sin pedidos disponibles',
                  emptySubtitle:
                      'Cuando haya pedidos listos para entrega,\naparecerán aquí',
                  selectedIds: _selectedIds,
                  allowSelection: true,
                  onToggle: _toggleSelection,
                  onToggleNeighborhood: _toggleNeighborhoodSelection,
                  onRefresh: _refreshAll,
                ),
                _RoutingTabContent(
                  plan: state.routingPlan,
                  isLoading: state.isLoadingRouting,
                  error: state.errorRouting,
                  onRefresh: () => ref
                      .read(availableNotifierProvider.notifier)
                      .loadRouting(),
                  onClaim: _confirmRoutingProposal,
                ),
                _OrderTabContent(
                  orders: state.preparationOrders,
                  isLoading: state.isLoadingPrep,
                  error: state.errorPrep,
                  emptyIcon: preparationEmpty.icon,
                  emptyTitle: preparationEmpty.title,
                  emptySubtitle: preparationEmpty.subtitle,
                  groupByUrgencyAnchor: true,
                  selectedIds: const {},
                  allowSelection: false,
                  onToggle: (_) {},
                  onRefresh: _refreshAll,
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: (isAvailableTab && _selectedIds.isNotEmpty)
          ? FloatingActionButton.extended(
              onPressed: _confirmAssignment,
              icon: const Icon(Icons.delivery_dining),
              label: Text('Asignarme (${_selectedIds.length})'),
            )
          : null,
    );
  }
}

class _RoutingTabContent extends StatelessWidget {
  final DeliveryRoutingPlan? plan;
  final bool isLoading;
  final String? error;
  final Future<void> Function() onRefresh;
  final ValueChanged<DeliveryRouteProposal> onClaim;

  const _RoutingTabContent({
    required this.plan,
    required this.isLoading,
    required this.error,
    required this.onRefresh,
    required this.onClaim,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading && plan == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null && plan == null) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: ErrorBanner(
              title: 'No pudimos preparar la ruta sugerida',
              message: error!,
            ),
          ),
        ]),
      );
    }
    final current = plan;
    if (current == null) return const SizedBox.shrink();
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Plan v${current.version} · ${current.availableNow} libres · ${current.availableSoon} próximos',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (current.warning != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(current.warning!,
                  style: const TextStyle(color: AppColors.warning)),
            ),
          if (current.proposals.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('No hay rutas sugeridas por ahora.')),
            ),
          for (final proposal in current.proposals)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          'Ruta ${proposal.sequence} · ${_recommendation(proposal.recommendation)}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text('${(proposal.durationSeconds / 60).round()} min'),
                    ]),
                    const SizedBox(height: 8),
                    for (final stop in proposal.stops)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              radius: 12,
                              child: Text('${stop.sequence ?? '-'}',
                                  style: const TextStyle(fontSize: 11)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '#${stop.orderId} · ${stop.neighborhood ?? stop.address}\n${stop.isReady ? 'Listo' : 'En espera'}',
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (proposal.warning != null)
                      Text(proposal.warning!,
                          style: const TextStyle(color: AppColors.warning)),
                    if (proposal.isClaimable)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => onClaim(proposal),
                            icon: const Icon(Icons.delivery_dining),
                            label: Text(
                                'Tomar ${proposal.claimableReadyOrderIds.length} listo(s)'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (current.unroutedOrders.isNotEmpty)
            Card(
              color: AppColors.warning.withValues(alpha: .08),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Sin ruta sugerida',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    for (final stop in current.unroutedOrders)
                      Text(
                          '#${stop.orderId} · ${_reason(stop.unroutedReason)}'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _recommendation(String value) => switch (value) {
        'leaveNow' => 'Salir ahora',
        'wait' => 'Esperar',
        'next' => 'Siguiente salida',
        _ => value,
      };

  static String _reason(String? value) => switch (value) {
        'requiresLocation' => 'falta ubicación',
        'noCapacity' => 'sin domiciliario disponible',
        _ => 'pendiente',
      };
}

class _PreparationEmptyContent {
  final IconData icon;
  final String title;
  final String subtitle;

  const _PreparationEmptyContent(this.icon, this.title, this.subtitle);
}

_PreparationEmptyContent _preparationEmptyContent(
  BranchPresenceResult presence,
) {
  switch (presence.status) {
    case BranchPresenceStatus.outside:
      final distance = presence.distanceMeters?.round();
      return _PreparationEmptyContent(
        Icons.location_off_outlined,
        'Debes estar en la sucursal',
        distance == null
            ? 'Estos pedidos solo se muestran cuando tu ubicación está dentro de la sucursal.'
            : 'Estás aproximadamente a $distance m de la sucursal. Acércate y vuelve a actualizar.',
      );
    case BranchPresenceStatus.branchLocationMissing:
      return const _PreparationEmptyContent(
        Icons.wrong_location_outlined,
        'Ubicación de sucursal pendiente',
        'Un administrador debe configurar las coordenadas de la sucursal.',
      );
    case BranchPresenceStatus.locationServicesDisabled:
      return const _PreparationEmptyContent(
        Icons.gps_off_outlined,
        'Activa la ubicación',
        'El GPS debe estar encendido para verificar que estás en la sucursal.',
      );
    case BranchPresenceStatus.permissionDenied:
      return const _PreparationEmptyContent(
        Icons.location_disabled_outlined,
        'Permiso de ubicación requerido',
        'Autoriza la ubicación y vuelve a actualizar para ver estos pedidos.',
      );
    case BranchPresenceStatus.permissionDeniedForever:
      return const _PreparationEmptyContent(
        Icons.location_disabled_outlined,
        'Habilita la ubicación en ajustes',
        'El permiso está bloqueado. Habilítalo desde los ajustes de la aplicación.',
      );
    case BranchPresenceStatus.locationUnavailable:
      return const _PreparationEmptyContent(
        Icons.gps_not_fixed_outlined,
        'No pudimos verificar tu ubicación',
        'Busca una zona con señal GPS y vuelve a actualizar.',
      );
    case BranchPresenceStatus.initial:
    case BranchPresenceStatus.checking:
      return const _PreparationEmptyContent(
        Icons.my_location_outlined,
        'Verificando ubicación',
        'Espera un momento mientras confirmamos que estás en la sucursal.',
      );
    case BranchPresenceStatus.inside:
      return const _PreparationEmptyContent(
        Icons.restaurant_outlined,
        'Sin pedidos en preparación',
        'Los domicilios en Tomado o En preparación aparecerán aquí, del más al menos urgente.',
      );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab bar
// ─────────────────────────────────────────────────────────────────────────────
class _OrderTabBar extends StatelessWidget {
  final TabController controller;
  final int availableCount;
  final int prepCount;
  final int routeCount;

  const _OrderTabBar({
    required this.controller,
    required this.availableCount,
    required this.prepCount,
    required this.routeCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: TabBar(
        controller: controller,
        labelColor: AppColors.primaryLight,
        unselectedLabelColor: AppColors.hint,
        indicatorColor: AppColors.primary,
        indicatorWeight: 2,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
        tabs: [
          Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Disponibles'),
                if (availableCount > 0) ...[
                  const SizedBox(width: 6),
                  _CountBadge(count: availableCount, color: AppColors.accent),
                ],
              ],
            ),
          ),
          Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Rutas'),
                if (routeCount > 0) ...[
                  const SizedBox(width: 6),
                  _CountBadge(count: routeCount, color: AppColors.primaryLight),
                ],
              ],
            ),
          ),
          Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('En preparación'),
                if (prepCount > 0) ...[
                  const SizedBox(width: 6),
                  _CountBadge(count: prepCount, color: AppColors.warning),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  final Color color;
  const _CountBadge({required this.count, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          '$count',
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w700),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Contenido por tab (grupos por barrio + refresco periódico del semáforo)
// ─────────────────────────────────────────────────────────────────────────────
class _OrderTabContent extends StatefulWidget {
  final List<Order> orders;
  final bool isLoading;
  final String? error;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptySubtitle;
  final Set<int> selectedIds;
  final bool allowSelection;
  final ValueChanged<int> onToggle;
  final void Function(List<int> orderIds)? onToggleNeighborhood;
  final Future<void> Function() onRefresh;

  /// Pestaña «En preparación»: misma ancla de urgencia que el semáforo (más urgente arriba).
  final bool groupByUrgencyAnchor;

  const _OrderTabContent({
    required this.orders,
    required this.isLoading,
    required this.error,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptySubtitle,
    this.groupByUrgencyAnchor = false,
    required this.selectedIds,
    required this.allowSelection,
    required this.onToggle,
    this.onToggleNeighborhood,
    required this.onRefresh,
  });

  @override
  State<_OrderTabContent> createState() => _OrderTabContentState();
}

class _OrderTabContentState extends State<_OrderTabContent> {
  Timer? _urgencyTick;

  @override
  void initState() {
    super.initState();
    _urgencyTick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _urgencyTick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading && widget.orders.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    final groups = groupOrdersByNeighborhood(
      widget.orders,
      compare: widget.groupByUrgencyAnchor
          ? compareOrdersUrgencyAnchorOldestFirst
          : null,
    );

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      color: AppColors.primary,
      backgroundColor: AppColors.card,
      child: CustomScrollView(
        slivers: [
          if (widget.error != null)
            SliverToBoxAdapter(
              child: ErrorBanner(
                title: 'No pudimos cargar estos pedidos',
                message: widget.error!,
                onRetry: widget.onRefresh,
              ),
            ),
          if (widget.orders.isEmpty && !widget.isLoading)
            SliverFillRemaining(
              child: EmptyStateWidget(
                icon: widget.emptyIcon,
                title: widget.emptyTitle,
                subtitle: widget.emptySubtitle,
                onRefresh: widget.onRefresh,
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingMd,
                AppTheme.spacingMd,
                AppTheme.spacingMd,
                100,
              ),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  for (final entry in groups.entries)
                    _NeighborhoodGroup(
                      neighborhoodName: entry.key,
                      orders: entry.value,
                      selectedIds: widget.selectedIds,
                      allowSelection: widget.allowSelection,
                      onToggle: widget.onToggle,
                      onToggleNeighborhood: widget.onToggleNeighborhood,
                    ),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Grupo expandible por barrio
// ─────────────────────────────────────────────────────────────────────────────
class _NeighborhoodGroup extends StatefulWidget {
  final String neighborhoodName;
  final List<Order> orders;
  final Set<int> selectedIds;
  final bool allowSelection;
  final ValueChanged<int> onToggle;
  final void Function(List<int> orderIds)? onToggleNeighborhood;

  const _NeighborhoodGroup({
    required this.neighborhoodName,
    required this.orders,
    required this.selectedIds,
    required this.allowSelection,
    required this.onToggle,
    this.onToggleNeighborhood,
  });

  @override
  State<_NeighborhoodGroup> createState() => _NeighborhoodGroupState();
}

class _NeighborhoodGroupState extends State<_NeighborhoodGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          children: [
            Container(
              padding:
                  const EdgeInsets.only(left: 4, right: 0, top: 4, bottom: 4),
              decoration: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.vertical(
                  top: const Radius.circular(AppTheme.radiusMd),
                  bottom: _expanded
                      ? Radius.zero
                      : const Radius.circular(AppTheme.radiusMd),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _expanded = !_expanded),
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(AppTheme.radiusMd),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.place_outlined,
                                size: 16, color: AppColors.primaryLight),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                widget.neighborhoodName,
                                style: const TextStyle(
                                  color: AppColors.primaryLight,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${widget.orders.length} '
                                '${widget.orders.length == 1 ? 'pedido' : 'pedidos'}',
                                style: const TextStyle(
                                  color: AppColors.primaryLight,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (widget.allowSelection &&
                      widget.onToggleNeighborhood != null) ...[
                    Builder(
                      builder: (context) {
                        final ids = widget.orders.map((o) => o.id).toList();
                        final allSelected = ids.isNotEmpty &&
                            ids.every((id) => widget.selectedIds.contains(id));
                        return IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                          splashRadius: 20,
                          tooltip: allSelected
                              ? 'Quitar todos de este barrio'
                              : 'Seleccionar todos de este barrio',
                          onPressed: () => widget.onToggleNeighborhood!(ids),
                          icon: Icon(
                            Icons.done_all,
                            size: 22,
                            color: allSelected
                                ? AppColors.accentLight
                                : AppColors.primaryLight,
                          ),
                        );
                      },
                    ),
                  ],
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    splashRadius: 20,
                    tooltip: _expanded ? 'Contraer' : 'Expandir',
                    onPressed: () => setState(() => _expanded = !_expanded),
                    icon: AnimatedRotation(
                      turns: _expanded ? 0 : -0.5,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.expand_less,
                          size: 18, color: AppColors.primaryLight),
                    ),
                  ),
                ],
              ),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState: _expanded
                  ? CrossFadeState.showFirst
                  : CrossFadeState.showSecond,
              firstChild: Column(
                children: [
                  const Divider(height: 1),
                  ...widget.orders.map(
                    (order) => Column(
                      children: [
                        if (order != widget.orders.first)
                          const Divider(height: 1, indent: 8, endIndent: 8),
                        _CompactAvailableOrderTile(
                          order: order,
                          now: DateTime.now(),
                          isSelected: widget.selectedIds.contains(order.id),
                          allowSelection: widget.allowSelection,
                          onToggle: () => widget.onToggle(order.id),
                          onOpenMap: () =>
                              _openOrderDestinationMap(context, order),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              secondChild: const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fila compacta: semáforo + # + dirección + mapa
// ─────────────────────────────────────────────────────────────────────────────
class _CompactAvailableOrderTile extends StatelessWidget {
  final Order order;
  final DateTime now;
  final bool isSelected;
  final bool allowSelection;
  final VoidCallback onToggle;
  final VoidCallback onOpenMap;

  const _CompactAvailableOrderTile({
    required this.order,
    required this.now,
    required this.isSelected,
    required this.allowSelection,
    required this.onToggle,
    required this.onOpenMap,
  });

  static const double _stripWidth = 4;

  @override
  Widget build(BuildContext context) {
    final tier = urgencyTierForOrder(order, now);
    final strip = _stripColor(tier);
    final fill = _fillColor(tier);
    final borderColor = isSelected ? AppColors.primary : _borderColor(tier);
    final borderW = isSelected ? 2.5 : 1.0;

    final addr = order.displayAddressLine ?? 'Sin dirección';
    final extra = order.addressAdditionalInfo?.trim();

    Widget textBlock = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '#${order.id}',
            style: const TextStyle(
              color: AppColors.onBackground,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            addr,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.onSurface,
              fontSize: 12,
              height: 1.2,
            ),
          ),
          if (extra != null && extra.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              extra,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.hint.withValues(alpha: 0.95),
                fontSize: 11,
                height: 1.2,
              ),
            ),
          ],
        ],
      ),
    );

    if (allowSelection) {
      textBlock = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onToggle,
          child: textBlock,
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: borderW),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: _stripWidth, color: strip),
            Expanded(child: textBlock),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 36,
                minHeight: 36,
              ),
              splashRadius: 20,
              onPressed: onOpenMap,
              icon: const Icon(
                Icons.map_outlined,
                size: 22,
                color: AppColors.primaryLight,
              ),
              tooltip: 'Ir al mapa',
            ),
          ],
        ),
      ),
    );
  }

  Color _stripColor(DeliveryUrgencyTier t) => switch (t) {
        DeliveryUrgencyTier.green => AppColors.success,
        DeliveryUrgencyTier.orange => AppColors.warning,
        DeliveryUrgencyTier.orangeRed => const Color(0xFFFF6B35),
        DeliveryUrgencyTier.red => AppColors.error,
      };

  Color _borderColor(DeliveryUrgencyTier t) => switch (t) {
        DeliveryUrgencyTier.green => AppColors.success.withValues(alpha: 0.65),
        DeliveryUrgencyTier.orange => AppColors.warning.withValues(alpha: 0.75),
        DeliveryUrgencyTier.orangeRed =>
          const Color(0xFFFF6B35).withValues(alpha: 0.85),
        DeliveryUrgencyTier.red => AppColors.error.withValues(alpha: 0.85),
      };

  Color _fillColor(DeliveryUrgencyTier t) => switch (t) {
        DeliveryUrgencyTier.green =>
          AppColors.accentContainer.withValues(alpha: 0.35),
        DeliveryUrgencyTier.orange => AppColors.warning.withValues(alpha: 0.08),
        DeliveryUrgencyTier.orangeRed =>
          const Color(0xFFFF6B35).withValues(alpha: 0.12),
        DeliveryUrgencyTier.red => AppColors.error.withValues(alpha: 0.12),
      };
}
