import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/empty_state_widget.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/widgets/order_card.dart';
import '../../orders/models/order_models.dart';
import 'route_notifier.dart';
import 'widgets/delivery_order_detail_sheet.dart';

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

  Future<void> _openOrderDetail(Order order) async {
    await showDeliveryOrderDetailSheet(
      context: context,
      ref: ref,
      initialOrder: order,
      onAddressUpdated: (payload) {
        ref.read(routeNotifierProvider.notifier).applyAddressPatch(
              orderId: payload.orderId,
              addressDescription: payload.addressDescription,
              addressAdditionalInfo: payload.addressAdditionalInfo,
              latitude: payload.lat,
              longitude: payload.lng,
              neighborhoodId: payload.neighborhoodId,
              neighborhoodName: payload.neighborhoodName,
            );
      },
      onAfterDelivered: () => ref.read(routeNotifierProvider.notifier).load(),
    );
  }

  /// Abre Google Maps con todos los pedidos como waypoints (ruta multi-parada).
  Future<void> _openRouteInMaps(List<Order> orders) async {
    final withCoords = orders
        .where((o) =>
            o.latitude != null &&
            o.longitude != null &&
            o.latitude != 0 &&
            o.longitude != 0)
        .toList();

    if (withCoords.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Ningún pedido tiene coordenadas registradas.')),
        );
      }
      return;
    }

    String fmt(Order o) => '${o.latitude},${o.longitude}';
    final destination = withCoords.last;
    // Máximo 23 waypoints intermedios (límite de Google Maps)
    final waypoints = withCoords
        .sublist(0, withCoords.length - 1)
        .take(23)
        .map(fmt)
        .join('|');

    final params = StringBuffer('https://www.google.com/maps/dir/?api=1&travelmode=driving');
    params.write('&destination=${Uri.encodeComponent(fmt(destination))}');
    if (waypoints.isNotEmpty) {
      params.write('&waypoints=${Uri.encodeComponent(waypoints)}');
    }

    try {
      await launchUrl(
        Uri.parse(params.toString()),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo abrir Google Maps: $e')),
        );
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
                child: _RouteSummaryBar(
                  orders: state.orders,
                  onOpenRoute: () => _openRouteInMaps(state.orders),
                ),
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
                          onTap: () => _openOrderDetail(order),
                          trailing: _OrderActions(
                            order: order,
                            onDetail: () => _openOrderDetail(order),
                            onStatus: () => _changeStatus(order),
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
  final VoidCallback onOpenRoute;
  const _RouteSummaryBar({required this.orders, required this.onOpenRoute});

  @override
  Widget build(BuildContext context) {
    final total = orders.fold(0.0, (sum, o) => sum + o.total);
    final hasCoords = orders.any((o) =>
        o.latitude != null && o.longitude != null &&
        o.latitude != 0 && o.longitude != 0);
    return Container(
      margin: const EdgeInsets.fromLTRB(
          AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingMd, 0),
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingMd, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primaryContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.delivery_dining, color: AppColors.primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${orders.length} pedido${orders.length != 1 ? 's' : ''} en ruta',
                  style: const TextStyle(
                      color: AppColors.primaryLight, fontWeight: FontWeight.w600, fontSize: 13),
                ),
                Text(
                  _currencyFormat.format(total),
                  style: const TextStyle(
                      color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ],
            ),
          ),
          // Botón "Armar ruta"
          InkWell(
            onTap: hasCoords ? onOpenRoute : null,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: hasCoords
                    ? AppColors.primary.withValues(alpha: 0.25)
                    : AppColors.disabled.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                border: Border.all(
                  color: hasCoords
                      ? AppColors.primary.withValues(alpha: 0.5)
                      : AppColors.disabled,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.map_outlined,
                      size: 14,
                      color: hasCoords ? AppColors.primaryLight : AppColors.hint),
                  const SizedBox(width: 5),
                  Text(
                    'Armar ruta',
                    style: TextStyle(
                      color: hasCoords ? AppColors.primaryLight : AppColors.hint,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fila compacta de acciones para cada pedido en ruta.
class _OrderActions extends StatelessWidget {
  final Order order;
  final VoidCallback onDetail;
  final VoidCallback onStatus;

  const _OrderActions({
    required this.order,
    required this.onDetail,
    required this.onStatus,
  });

  @override
  Widget build(BuildContext context) {
    final isOnTheWay = order.status == OrderStatus.onTheWay;
    final statusColor =
        isOnTheWay ? AppColors.accentDark : AppColors.statusOnTheWay;
    final statusLabel = isOnTheWay ? 'Entregado' : 'En camino';
    final statusIcon =
        isOnTheWay ? Icons.check_circle_outline : Icons.delivery_dining;

    return Row(
      children: [
        // Ver detalle
        _CompactButton(
          icon: Icons.receipt_long_outlined,
          label: 'Detalle',
          color: AppColors.primary,
          onTap: onDetail,
        ),
        const SizedBox(width: 8),
        // Cambiar estado
        _CompactButton(
          icon: statusIcon,
          label: statusLabel,
          color: statusColor,
          onTap: onStatus,
          filled: true,
        ),
      ],
    );
  }
}

class _CompactButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool filled;

  const _CompactButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: filled
              ? color
              : color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(
            color: filled ? color : color.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14, color: filled ? Colors.white : color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: filled ? Colors.white : color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
