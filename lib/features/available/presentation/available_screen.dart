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
import 'available_notifier.dart';

Future<void> _openOrderDestinationMap(BuildContext context, Order order) async {
  if (!orderHasOpenableMapDestination(order)) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Este pedido no tiene dirección ni coordenadas para el mapa.',
        ),
      ),
    );
    return;
  }
  final ok = await openDeliveryDestinationInMaps(order);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No se pudo abrir Google Maps.')),
    );
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
    _tabController = TabController(length: 2, vsync: this);
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
      final allSelected =
          orderIds.every((id) => _selectedIds.contains(id));
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

  Future<void> _refreshAll() =>
      ref.read(availableNotifierProvider.notifier).loadAll();

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(availableNotifierProvider);
    final isAvailableTab = _tabController.index == 0;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _OrderTabBar(
            controller: _tabController,
            availableCount: state.orders.length,
            prepCount: state.preparationOrders.length,
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
                _OrderTabContent(
                  orders: state.preparationOrders,
                  isLoading: state.isLoadingPrep,
                  error: state.errorPrep,
                  emptyIcon: Icons.restaurant_outlined,
                  emptyTitle: 'Sin pedidos en preparación',
                  emptySubtitle:
                      'Los pedidos que se están preparando\naparecerán aquí',
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

// ─────────────────────────────────────────────────────────────────────────────
// Tab bar
// ─────────────────────────────────────────────────────────────────────────────
class _OrderTabBar extends StatelessWidget {
  final TabController controller;
  final int availableCount;
  final int prepCount;

  const _OrderTabBar({
    required this.controller,
    required this.availableCount,
    required this.prepCount,
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

  const _OrderTabContent({
    required this.orders,
    required this.isLoading,
    required this.error,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptySubtitle,
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

    final groups = groupOrdersByNeighborhood(widget.orders);

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      color: AppColors.primary,
      backgroundColor: AppColors.card,
      child: CustomScrollView(
        slivers: [
          if (widget.error != null)
            SliverToBoxAdapter(
              child: ErrorBanner(
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
              padding: const EdgeInsets.only(left: 4, right: 0, top: 4, bottom: 4),
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
                                color:
                                    AppColors.primary.withValues(alpha: 0.2),
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
                        final ids =
                            widget.orders.map((o) => o.id).toList();
                        final allSelected = ids.isNotEmpty &&
                            ids.every(
                                (id) => widget.selectedIds.contains(id));
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
                          onPressed: () =>
                              widget.onToggleNeighborhood!(ids),
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
                    onPressed: () =>
                        setState(() => _expanded = !_expanded),
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
                          isSelected:
                              widget.selectedIds.contains(order.id),
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
    final borderColor =
        isSelected ? AppColors.primary : _borderColor(tier);
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
        DeliveryUrgencyTier.green =>
          AppColors.success.withValues(alpha: 0.65),
        DeliveryUrgencyTier.orange =>
          AppColors.warning.withValues(alpha: 0.75),
        DeliveryUrgencyTier.orangeRed =>
          const Color(0xFFFF6B35).withValues(alpha: 0.85),
        DeliveryUrgencyTier.red => AppColors.error.withValues(alpha: 0.85),
      };

  Color _fillColor(DeliveryUrgencyTier t) => switch (t) {
        DeliveryUrgencyTier.green =>
          AppColors.accentContainer.withValues(alpha: 0.35),
        DeliveryUrgencyTier.orange =>
          AppColors.warning.withValues(alpha: 0.08),
        DeliveryUrgencyTier.orangeRed =>
          const Color(0xFFFF6B35).withValues(alpha: 0.12),
        DeliveryUrgencyTier.red => AppColors.error.withValues(alpha: 0.12),
      };
}
