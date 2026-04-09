import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/empty_state_widget.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/widgets/order_card.dart';
import '../../../core/widgets/confirm_password_dialog.dart';
import '../../orders/models/order_models.dart';
import 'available_notifier.dart';

/// Agrupa pedidos por la categoría del primer producto de summaryLines.
Map<String, List<Order>> _groupByCategory(List<Order> orders) {
  final groups = <String, List<Order>>{};
  for (final o in orders) {
    final first = o.summaryLines.isNotEmpty ? o.summaryLines.first : null;
    final category = first?.categoryName?.trim().isNotEmpty == true
        ? first!.categoryName!
        : (first?.productName.trim().isNotEmpty == true
            ? first!.productName
            : 'Sin categoría');
    groups.putIfAbsent(category, () => []).add(o);
  }
  // Ordenar: más pedidos primero
  final sorted = groups.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  return Map.fromEntries(sorted);
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

  Future<void> _confirmAssignment() async {
    if (_selectedIds.isEmpty) return;
    final selectedList = List<int>.from(_selectedIds);

    final confirmed = await ConfirmPasswordDialog.show(
      context,
      title: 'Confirmar asignación',
      subtitle:
          'Se asignarán ${selectedList.length} pedido(s) a tu nombre. Ingresa tu contraseña para continuar.',
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
          // ── Tab bar ───────────────────────────────────────────────
          _OrderTabBar(
            controller: _tabController,
            availableCount: state.orders.length,
            prepCount: state.preparationOrders.length,
          ),

          // ── Contenido ─────────────────────────────────────────────
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // Tab 0: Disponibles
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
                  onRefresh: _refreshAll,
                ),
                // Tab 1: En preparación
                _OrderTabContent(
                  orders: state.preparationOrders,
                  isLoading: state.isLoadingPrep,
                  error: state.errorPrep,
                  emptyIcon: Icons.restaurant_outlined,
                  emptyTitle: 'Sin pedidos en preparación',
                  emptySubtitle: 'Los pedidos que se están preparando\naparecerán aquí',
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

      // FAB: asignar (solo en tab disponibles)
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
// Tab bar personalizado
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
        labelStyle: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w700),
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
// Contenido de cada tab (agrupado por categoría)
// ─────────────────────────────────────────────────────────────────────────────
class _OrderTabContent extends StatelessWidget {
  final List<Order> orders;
  final bool isLoading;
  final String? error;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptySubtitle;
  final Set<int> selectedIds;
  final bool allowSelection;
  final ValueChanged<int> onToggle;
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
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading && orders.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    final groups = _groupByCategory(orders);

    return RefreshIndicator(
      onRefresh: onRefresh,
      color: AppColors.primary,
      backgroundColor: AppColors.card,
      child: CustomScrollView(
        slivers: [
          if (error != null)
            SliverToBoxAdapter(
              child: ErrorBanner(message: error!, onRetry: onRefresh),
            ),
          if (orders.isEmpty && !isLoading)
            SliverFillRemaining(
              child: EmptyStateWidget(
                icon: emptyIcon,
                title: emptyTitle,
                subtitle: emptySubtitle,
                onRefresh: onRefresh,
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.spacingMd, AppTheme.spacingMd,
                  AppTheme.spacingMd, 100),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  for (final entry in groups.entries)
                    _CategoryGroup(
                      categoryName: entry.key,
                      orders: entry.value,
                      selectedIds: selectedIds,
                      allowSelection: allowSelection,
                      onToggle: onToggle,
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
// Grupo expandible por categoría
// ─────────────────────────────────────────────────────────────────────────────
class _CategoryGroup extends StatefulWidget {
  final String categoryName;
  final List<Order> orders;
  final Set<int> selectedIds;
  final bool allowSelection;
  final ValueChanged<int> onToggle;

  const _CategoryGroup({
    required this.categoryName,
    required this.orders,
    required this.selectedIds,
    required this.allowSelection,
    required this.onToggle,
  });

  @override
  State<_CategoryGroup> createState() => _CategoryGroupState();
}

class _CategoryGroupState extends State<_CategoryGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          children: [
            // ── Header del grupo ──────────────────────────────────
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.vertical(
                top: const Radius.circular(AppTheme.radiusMd),
                bottom: _expanded
                    ? Radius.zero
                    : const Radius.circular(AppTheme.radiusMd),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
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
                    const Icon(Icons.category_outlined,
                        size: 16, color: AppColors.primaryLight),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.categoryName,
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
                    const SizedBox(width: 8),
                    AnimatedRotation(
                      turns: _expanded ? 0 : -0.5,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.expand_less,
                          size: 18, color: AppColors.primaryLight),
                    ),
                  ],
                ),
              ),
            ),

            // ── Pedidos del grupo ─────────────────────────────────
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
                          const Divider(height: 1, indent: 14, endIndent: 14),
                        widget.allowSelection
                            ? _SelectableOrderCard(
                                order: order,
                                isSelected:
                                    widget.selectedIds.contains(order.id),
                                onToggle: () => widget.onToggle(order.id),
                              )
                            : Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 4, horizontal: 4),
                                child: OrderCard(order: order),
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
// Tarjeta seleccionable
// ─────────────────────────────────────────────────────────────────────────────
class _SelectableOrderCard extends StatelessWidget {
  final Order order;
  final bool isSelected;
  final VoidCallback onToggle;

  const _SelectableOrderCard({
    required this.order,
    required this.isSelected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: isSelected
              ? AppColors.primary
              : Colors.transparent,
          width: 2,
        ),
      ),
      child: OrderCard(
        order: order,
        onTap: onToggle,
        trailing: Row(
          children: [
            Checkbox(
              value: isSelected,
              onChanged: (_) => onToggle(),
              activeColor: AppColors.primary,
              checkColor: AppColors.onPrimary,
              side: const BorderSide(color: AppColors.hint),
            ),
            const SizedBox(width: 4),
            Text(
              isSelected ? 'Seleccionado' : 'Asignarme',
              style: TextStyle(
                color: isSelected ? AppColors.primaryLight : AppColors.hint,
                fontSize: 12,
                fontWeight:
                    isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
