import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/api/api_exception.dart';
import '../../../core/maps/open_delivery_destination_maps.dart';
import '../../../core/orders/route_order_helpers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/whatsapp/open_whatsapp.dart';
import '../../../core/widgets/compact_action_button.dart';
import '../../../core/widgets/empty_state_widget.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/widgets/order_card.dart';
import '../../orders/data/order_repository.dart';
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
  int? _reprintingOrderId;

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
    final icon =
        isOnTheWay ? Icons.check_circle_outline : Icons.delivery_dining;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: Text('Pedido #${order.id} - ${order.customer?.name ?? ''}'),
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
          await ref
              .read(routeNotifierProvider.notifier)
              .markDelivered(order.id);
          if (mounted) {
            ErrorBanner.showSuccess(
              context,
              'Pedido #${order.id} marcado como entregado',
            );
          }
        } else {
          await ref.read(routeNotifierProvider.notifier).markOnTheWay(order.id);
        }
      } catch (e) {
        if (mounted) ErrorBanner.show(context, e.toString());
      }
    }
  }

  Future<void> _reprintOrder(Order order) async {
    if (_reprintingOrderId != null) return;
    setState(() => _reprintingOrderId = order.id);
    try {
      final result =
          await ref.read(orderRepositoryProvider).enqueueDeliveryPrintJob(
        branchId: order.branchId,
        orderIds: [order.id],
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Impresión recibida por la sucursal · solicitud #${result.jobId}',
          ),
          backgroundColor: AppColors.accentContainer,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e is ApiException
          ? e.message
          : e is DioException && e.error is ApiException
              ? (e.error! as ApiException).message
              : e.toString();
      ErrorBanner.show(context, msg);
    } finally {
      if (mounted) setState(() => _reprintingOrderId = null);
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

  Future<void> _openSingleOrderMap(Order order) async {
    if (!orderHasOpenableMapDestination(order)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Este pedido no tiene direccion ni coordenadas para el mapa.',
            ),
          ),
        );
      }
      return;
    }
    final ok = await openDeliveryDestinationInMaps(order);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir Google Maps.')),
      );
    }
  }

  Future<void> _callCustomer(Order order) async {
    final phone = order.customer?.phone?.trim();
    if (phone == null || phone.isEmpty) return;
    try {
      final ok = await launchUrl(
        Uri(scheme: 'tel', path: phone),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir la llamada.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo abrir la llamada: $e')),
        );
      }
    }
  }

  Future<void> _openCustomerWhatsApp(Order order) async {
    final phone = order.customer?.phone?.trim();
    if (phone == null || phone.isEmpty) return;
    final ok = await openWhatsAppChat(
      phone,
      message: buildDeliveryWhatsAppMessage(order),
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp.')),
      );
    }
  }

  Future<void> _openRouteInMaps(List<Order> orders) async {
    final withCoords = orders
        .where(
          (o) =>
              o.latitude != null &&
              o.longitude != null &&
              o.latitude != 0 &&
              o.longitude != 0,
        )
        .toList();

    if (withCoords.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ningun pedido tiene coordenadas registradas.'),
          ),
        );
      }
      return;
    }

    String fmt(Order o) => '${o.latitude},${o.longitude}';
    final destination = withCoords.last;
    final waypoints = withCoords
        .sublist(0, withCoords.length - 1)
        .take(23)
        .map(fmt)
        .join('|');

    final params = StringBuffer(
        'https://www.google.com/maps/dir/?api=1&travelmode=driving');
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

  bool _hasCustomerPhone(Order order) =>
      order.customer?.phone?.trim().isNotEmpty == true;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(routeNotifierProvider);
    final now = DateTime.now();
    final nextOrder = selectNextRouteOrder(state.orders, now);

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
                  onRetry: () =>
                      ref.read(routeNotifierProvider.notifier).load(),
                ),
              ),
            if (nextOrder != null)
              SliverToBoxAdapter(
                child: _NextDeliveryCard(
                  order: nextOrder,
                  now: now,
                  onOpenMap: () => _openSingleOrderMap(nextOrder),
                  onWhatsApp: _hasCustomerPhone(nextOrder)
                      ? () => _openCustomerWhatsApp(nextOrder)
                      : null,
                  onCall: _hasCustomerPhone(nextOrder)
                      ? () => _callCustomer(nextOrder)
                      : null,
                  onStatus: () => _changeStatus(nextOrder),
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
                  subtitle: 'Los pedidos que aceptes apareceran aqui',
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
                        padding:
                            const EdgeInsets.only(bottom: AppTheme.spacingSm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _RouteReservationBanner(order: order, now: now),
                            OrderCard(
                              order: order,
                              onTap: () => _openOrderDetail(order),
                              trailing: _OrderActions(
                                order: order,
                                onDetail: () => _openOrderDetail(order),
                                onOpenMap: () => _openSingleOrderMap(order),
                                onStatus: () => _changeStatus(order),
                                onReprint: order.status == OrderStatus.onTheWay
                                    ? () => _reprintOrder(order)
                                    : null,
                                reprintLoading: _reprintingOrderId == order.id,
                              ),
                            ),
                          ],
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

class _NextDeliveryCard extends StatelessWidget {
  final Order order;
  final DateTime now;
  final VoidCallback onOpenMap;
  final VoidCallback? onWhatsApp;
  final VoidCallback? onCall;
  final VoidCallback onStatus;

  const _NextDeliveryCard({
    required this.order,
    required this.now,
    required this.onOpenMap,
    required this.onWhatsApp,
    required this.onCall,
    required this.onStatus,
  });

  @override
  Widget build(BuildContext context) {
    final isOnTheWay = order.status == OrderStatus.onTheWay;
    final statusColor =
        isOnTheWay ? AppColors.accentDark : AppColors.statusOnTheWay;
    final statusLabel = isOnTheWay ? 'Entregado' : 'En camino';
    final cashLabel = order.showYaPagoMessage
        ? 'Ya pagó'
        : 'Cobrar ${_currencyFormat.format(order.cashToCollectOnDelivery)}';
    final reservationLabel = reservationLabelForOrder(order, now);
    final address = order.displayAddressLine?.trim();
    final neighborhood = order.displayNeighborhoodLabel?.trim();
    final customerName = order.customer?.name.trim();
    final locationLabel = [
      if (neighborhood != null && neighborhood.isNotEmpty) neighborhood,
      if (address != null && address.isNotEmpty) address,
    ].join(' - ');

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppTheme.spacingMd,
        AppTheme.spacingMd,
        AppTheme.spacingMd,
        0,
      ),
      padding: const EdgeInsets.all(AppTheme.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.cardElevated,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: const Icon(
                  Icons.near_me_outlined,
                  size: 18,
                  color: AppColors.primaryLight,
                ),
              ),
              const SizedBox(width: AppTheme.spacingSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Siguiente entrega',
                      style: TextStyle(
                        color: AppColors.primaryLight,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      customerName != null && customerName.isNotEmpty
                          ? customerName
                          : 'Cliente sin nombre',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppColors.onBackground,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    if (locationLabel.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        locationLabel,
                        style: const TextStyle(
                          color: AppColors.onCard,
                          fontSize: 12,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.spacingSm),
              Text(
                cashLabel,
                style: TextStyle(
                  color: order.showYaPagoMessage
                      ? AppColors.accentLight
                      : AppColors.primaryLight,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          if (reservationLabel != null) ...[
            const SizedBox(height: AppTheme.spacingSm),
            _ReservationChip(
              label: reservationLabel,
              state: reservationStateForOrder(order, now),
            ),
          ],
          const SizedBox(height: AppTheme.spacingMd),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                CompactActionButton(
                  icon: Icons.navigation_outlined,
                  label: 'Ir',
                  color: AppColors.primary,
                  onTap: onOpenMap,
                ),
                const SizedBox(width: 8),
                if (onWhatsApp != null) ...[
                  CompactActionButton(
                    icon: Icons.chat_outlined,
                    label: 'WhatsApp',
                    color: AppColors.accent,
                    onTap: onWhatsApp,
                  ),
                  const SizedBox(width: 8),
                ],
                if (onCall != null) ...[
                  CompactActionButton(
                    icon: Icons.call_outlined,
                    label: 'Llamar',
                    color: AppColors.info,
                    onTap: onCall,
                  ),
                  const SizedBox(width: 8),
                ],
                CompactActionButton(
                  icon: isOnTheWay
                      ? Icons.check_circle_outline
                      : Icons.delivery_dining,
                  label: statusLabel,
                  color: statusColor,
                  onTap: onStatus,
                  filled: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteReservationBanner extends StatelessWidget {
  final Order order;
  final DateTime now;

  const _RouteReservationBanner({required this.order, required this.now});

  @override
  Widget build(BuildContext context) {
    final label = reservationLabelForOrder(order, now);
    if (label == null) return const SizedBox.shrink();
    final state = reservationStateForOrder(order, now);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _ReservationChip(label: label, state: state),
      ),
    );
  }
}

class _ReservationChip extends StatelessWidget {
  final String label;
  final RouteReservationState state;

  const _ReservationChip({required this.label, required this.state});

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      RouteReservationState.overdue => AppColors.error,
      RouteReservationState.soon => AppColors.warning,
      RouteReservationState.scheduled => AppColors.info,
      RouteReservationState.none => AppColors.hint,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_outlined, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
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
    final hasCoords = orders.any(
      (o) =>
          o.latitude != null &&
          o.longitude != null &&
          o.latitude != 0 &&
          o.longitude != 0,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppTheme.spacingMd,
        AppTheme.spacingMd,
        AppTheme.spacingMd,
        0,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingMd,
        vertical: 10,
      ),
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
                    color: AppColors.primaryLight,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  _currencyFormat.format(total),
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
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
                  Icon(
                    Icons.map_outlined,
                    size: 14,
                    color: hasCoords ? AppColors.primaryLight : AppColors.hint,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Armar ruta',
                    style: TextStyle(
                      color:
                          hasCoords ? AppColors.primaryLight : AppColors.hint,
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

class _OrderActions extends StatelessWidget {
  final Order order;
  final VoidCallback onDetail;
  final VoidCallback onOpenMap;
  final VoidCallback onStatus;
  final VoidCallback? onReprint;
  final bool reprintLoading;

  const _OrderActions({
    required this.order,
    required this.onDetail,
    required this.onOpenMap,
    required this.onStatus,
    this.onReprint,
    this.reprintLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final isOnTheWay = order.status == OrderStatus.onTheWay;
    final statusColor =
        isOnTheWay ? AppColors.accentDark : AppColors.statusOnTheWay;
    final statusLabel = isOnTheWay ? 'Listo' : 'Camino';
    final statusIcon =
        isOnTheWay ? Icons.check_circle_outline : Icons.delivery_dining;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          CompactActionButton(
            icon: Icons.receipt_long_outlined,
            label: 'Ver',
            color: AppColors.primary,
            onTap: onDetail,
          ),
          const SizedBox(width: 8),
          CompactActionButton(
            icon: Icons.navigation_outlined,
            label: 'Ir',
            color: AppColors.primary,
            onTap: onOpenMap,
          ),
          const SizedBox(width: 8),
          if (onReprint != null) ...[
            CompactActionButton(
              icon:
                  reprintLoading ? Icons.hourglass_empty : Icons.print_outlined,
              label: reprintLoading ? 'Enviando…' : 'Imprimir',
              color: AppColors.onSurface,
              onTap: reprintLoading ? null : onReprint,
            ),
            const SizedBox(width: 8),
          ],
          CompactActionButton(
            icon: statusIcon,
            label: statusLabel,
            color: statusColor,
            onTap: onStatus,
            filled: true,
          ),
        ],
      ),
    );
  }
}
