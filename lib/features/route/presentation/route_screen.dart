import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/empty_state_widget.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/widgets/order_card.dart';
import '../../../core/widgets/status_badge.dart';
import '../../orders/models/order_models.dart';
import 'route_notifier.dart';

final _currencyFormat =
    NumberFormat.currency(locale: 'es_CO', symbol: '\$', decimalDigits: 0);

class RouteScreen extends ConsumerStatefulWidget {
  const RouteScreen({super.key});

  @override
  ConsumerState<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends ConsumerState<RouteScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(routeNotifierProvider.notifier).load();
    });
  }

  Future<void> _changeStatus(Order order) async {
    final isOnTheWay = order.status == OrderStatus.onTheWay;
    final label = isOnTheWay ? 'Marcar como entregado' : 'Marcar en camino';
    final icon = isOnTheWay ? Icons.check_circle_outline : Icons.delivery_dining;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: Text('Pedido #${order.id} — ${order.customer?.name ?? ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: Icon(icon, size: 18),
            label: const Text('Confirmar'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        if (isOnTheWay) {
          await ref.read(routeNotifierProvider.notifier).markDelivered(order.id);
          if (mounted) {
            ErrorBanner.showSuccess(context, 'Pedido #${order.id} marcado como entregado');
          }
        } else {
          await ref.read(routeNotifierProvider.notifier).markOnTheWay(order.id);
        }
      } catch (e) {
        if (mounted) ErrorBanner.show(context, e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(routeNotifierProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: () => ref.read(routeNotifierProvider.notifier).load(),
        color: AppColors.primary,
        backgroundColor: AppColors.card,
        child: CustomScrollView(
          slivers: [
            if (state.error != null)
              SliverToBoxAdapter(
                child: ErrorBanner(
                  message: state.error!,
                  onRetry: () => ref.read(routeNotifierProvider.notifier).load(),
                ),
              ),
            if (state.orders.isNotEmpty)
              SliverToBoxAdapter(
                child: _RouteSummaryBar(orders: state.orders),
              ),
            if (state.isLoading && state.orders.isEmpty)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              )
            else if (state.orders.isEmpty && !state.isLoading)
              SliverFillRemaining(
                child: EmptyStateWidget(
                  icon: Icons.route_outlined,
                  title: 'Sin pedidos en ruta',
                  subtitle: 'Los pedidos que aceptes aparecerán aquí',
                  onRefresh: () =>
                      ref.read(routeNotifierProvider.notifier).load(),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(AppTheme.spacingMd),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final order = state.orders[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                        child: OrderCard(
                          order: order,
                          trailing: _StatusActionButton(
                            order: order,
                            onTap: () => _changeStatus(order),
                          ),
                        ),
                      );
                    },
                    childCount: state.orders.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RouteSummaryBar extends StatelessWidget {
  final List<Order> orders;
  const _RouteSummaryBar({required this.orders});

  @override
  Widget build(BuildContext context) {
    final total = orders.fold(0.0, (sum, o) => sum + o.total);
    return Container(
      margin: const EdgeInsets.fromLTRB(
          AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingMd, 0),
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingMd, vertical: AppTheme.spacingSm),
      decoration: BoxDecoration(
        color: AppColors.primaryContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.delivery_dining, color: AppColors.primary, size: 18),
          const SizedBox(width: 8),
          Text(
            '${orders.length} pedido${orders.length != 1 ? 's' : ''} en ruta',
            style: const TextStyle(
                color: AppColors.primaryLight, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Text(
            _currencyFormat.format(total),
            style: const TextStyle(
                color: AppColors.primary, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _StatusActionButton extends StatelessWidget {
  final Order order;
  final VoidCallback onTap;

  const _StatusActionButton({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isOnTheWay = order.status == OrderStatus.onTheWay;
    return Row(
      children: [
        StatusBadge(status: order.status),
        const Spacer(),
        SizedBox(
          height: 32,
          child: ElevatedButton.icon(
            onPressed: onTap,
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  isOnTheWay ? AppColors.statusDelivered : AppColors.statusOnTheWay,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            icon: Icon(
              isOnTheWay ? Icons.check_circle_outline : Icons.delivery_dining,
              size: 16,
            ),
            label: Text(isOnTheWay ? 'Entregado' : 'En camino'),
          ),
        ),
      ],
    );
  }
}
