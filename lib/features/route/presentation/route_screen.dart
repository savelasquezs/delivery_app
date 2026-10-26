import '../helpers/delivery_actions.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

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
    if (order.status == OrderStatus.onTheWay) {
      await confirmDelivery(context, order, () => ref.read(routeNotifierProvider.notifier).markDelivered(order));
    } else {
      await ref.read(routeNotifierProvider.notifier).markOnTheWay(order.id);
    }
  }

  Future<void> _reprintOrder(Order order) async {
    if (_reprintingOrderId != null) return;
    setState(() => _reprintingOrderId = order.id);
    try { await reprintDelivery(context, ref.read(orderRepositoryProvider), order); }
    finally { if (mounted) setState(() => _reprintingOrderId = null); }
  }

  Future<void> _openOrderDetail(Order order) async {
    await showDeliveryOrderDetailSheet(
      context: context,
      ref: ref,
      initialOrder: order,

    );
    if (!mounted) return;
    await ref.read(routeNotifierProvider.notifier).load(
          silently: true,
          ensureFresh: true,
        );
  }

  Future<void> _openSingleOrderMap(Order order) async {
    if (!orderHasOpenableMapDestination(order)) {
      if (mounted) {
        ErrorBanner.show(
          context,
          'Este pedido no tiene dirección ni coordenadas para abrir el mapa.',
        );
      }
      return;
    }
    final ok = await openDeliveryDestinationInMaps(order);
    if (!ok && mounted) {
      ErrorBanner.show(context, 'No pudimos abrir Google Maps.');
    }
  }

  Future<void> _contactCustomer(Order order, {bool whatsapp = false}) async {
    final phone = order.customer?.phone?.trim();
    if (phone == null || phone.isEmpty) return;
    final opened = whatsapp
        ? await openWhatsAppChat(phone,
            message: buildDeliveryWhatsAppMessage(order))
        : await openPhoneCall(phone);
    if (!opened && mounted)
      ErrorBanner.show(
          context,
          whatsapp
              ? 'No pudimos abrir WhatsApp.'
              : 'No pudimos iniciar la llamada.');
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
        ErrorBanner.show(
          context,
          'Ningún pedido tiene una ubicación registrada para crear la ruta.',
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
        ErrorBanner.show(
          context,
          e,
          fallback: 'No pudimos abrir la ruta en Google Maps.',
        );
      }
    }
  }

  bool _hasCustomerPhone(Order order) =>
      order.customer?.phone?.trim().isNotEmpty == true;

  Future<void> _reviewPending(Map<String, Object?> row) async {
    final payload = jsonDecode(row['payload'] as String) as Map;
    final local = payload['changes'] as Map?;
    final current = payload['orderId'] == null ? Future<Order?>.value(null)
      : ref.read(orderRepositoryProvider).getOrderWithDetails(payload['orderId'] as int);
    const labels = {'address': 'Dirección', 'additionalInfo': 'Información adicional',
      'neighborhoodId': 'Barrio', 'latitude': 'Latitud', 'longitude': 'Longitud'};
    final discard = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
      title: const Text('Revisar acción pendiente'),
      content: SingleChildScrollView(child: FutureBuilder<Order?>(future: current, builder: (_, snapshot) => Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [Text(row['reason'] as String? ?? 'El pedido cambió.'),
          if (local != null) ...[const SizedBox(height: 12), const Text('Corrección guardada en este celular:'),
            for (final entry in local.entries) Text('${labels[entry.key] ?? 'Dato editado'}: ${entry.value ?? '—'}')],
          const SizedBox(height: 12),
          if (snapshot.connectionState == ConnectionState.waiting) const LinearProgressIndicator()
          else if (snapshot.hasError) const Text('No pudimos consultar la información actual de la sucursal.')
          else if (snapshot.data != null) ...[const Text('Última información de la sucursal:'),
            Text('${snapshot.data!.status.displayName} · ${snapshot.data!.displayAddressLine ?? ''}'),
            Text(snapshot.data!.addressAdditionalInfo ?? '')],
          const SizedBox(height: 12), const Text('Descartar elimina solo esta acción local. Puedes conservarla para revisarla después.')],
      ))), actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Conservar')),
        TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Descartar acción local'))],
    ));
    if (discard == true && mounted) {
      final operations = ref.read(orderRepositoryProvider).operations;
      await operations.outbox.discardOperationConflict(
          await operations.owner(), row['id'] as String);
      if (mounted)
        await ref.read(routeNotifierProvider.notifier).load(silently: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(routeNotifierProvider);
    final now = DateTime.now();
    final displayOrders = prioritizeRouteOrdersForDisplay(state.orders, now);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: () => ref.read(routeNotifierProvider.notifier).load(),
        color: AppColors.primary,
        backgroundColor: AppColors.card,
        child: CustomScrollView(
          slivers: [
            if (state.lastClosure != null)
              SliverToBoxAdapter(
                  child: ListTile(
                dense: true,
                leading: const Icon(Icons.task_alt),
                title: Text(
                    'Ruta #${state.lastClosure!['routeId']} cerrada ${state.lastClosure!['source'] == 'return' ? 'al regresar' : 'al tomar la siguiente ruta'}'),
                subtitle: (state.lastClosure!['deliveries'] as num? ?? 0) > 0
                    ? Text(
                        '${state.lastClosure!['deliveries']} entregas confirmadas por cierre operativo')
                    : null,
              )),
            if (state.pending.isNotEmpty)
              SliverToBoxAdapter(
                  child: ExpansionTile(
                initiallyExpanded: true,
                leading: const Icon(Icons.cloud_upload_outlined),
                title:
                    const Text('Entregas y cambios pendientes de sincronizar'),
                children: [
                  for (final row in state.pending)
                    Builder(builder: (context) {
                      final payload =
                          jsonDecode(row['payload'] as String) as Map;
                      final kind = payload['kind'];
                      final conflict = row['state'] == 'conflict';
                      return ListTile(
                        title: Text(kind == 'deliver'
                            ? 'Pedido #${payload['orderId']} · Entregado, pendiente de sincronizar'
                            : kind == 'address'
                                ? 'Pedido #${payload['orderId']} · Dirección pendiente'
                                : 'Confirmando resultado de la toma'),
                        subtitle: conflict
                            ? Text(row['reason'] as String? ??
                                'Revisa los cambios de la sucursal.')
                            : null,
                        trailing: IconButton(
                            tooltip:
                                conflict ? 'Revisar conflicto' : 'Sincronizar',
                            icon: Icon(
                                conflict ? Icons.error_outline : Icons.sync),
                            onPressed: conflict
                                ? () => _reviewPending(row)
                                : () => ref
                                    .read(routeNotifierProvider.notifier)
                                    .load()),
                      );
                    })
                ],
              )),
            if (state.phase == 'returning' && displayOrders.isEmpty)
              const SliverToBoxAdapter(
                  child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Regresando a sucursal',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)))),
            if (state.error != null)
              SliverToBoxAdapter(
                child: state.revision >= 0 ? ListTile(
                  dense: true, leading: const Icon(Icons.cloud_off_outlined),
                  title: const Text('Mostrando la ruta guardada'),
                  subtitle: Text(state.error!, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(tooltip: 'Actualizar ruta', icon: const Icon(Icons.sync),
                    onPressed: () => ref.read(routeNotifierProvider.notifier).load()),
                ) : ErrorBanner(
                  title: 'No pudimos cargar tu ruta',
                  message: state.error!,
                  onRetry: () =>
                      ref.read(routeNotifierProvider.notifier).load(),
                ),
              ),
            if (displayOrders.isNotEmpty)
              SliverToBoxAdapter(
                child: _RouteSummaryBar(
                  orders: displayOrders,
                  onOpenRoute: () => _openRouteInMaps(displayOrders),
                ),
              ),
            if (state.isLoading && displayOrders.isEmpty)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              )
            else if (displayOrders.isEmpty && !state.isLoading)
              SliverFillRemaining(
                child: EmptyStateWidget(
                  icon: Icons.route_outlined,
                  title: state.routeId == null
                      ? 'Sin pedidos en ruta'
                      : 'Ruta activa',
                  subtitle: state.pending.isNotEmpty
                      ? 'Las entregas registradas están pendientes de confirmar.'
                      : state.phase == 'returning'
                          ? 'La ruta finalizará al confirmar el regreso a sucursal.'
                          : 'Los pedidos que aceptes aparecerán aquí',
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
                      final order = displayOrders[index];
                      final isNextDelivery = index == 0;
                      return Padding(
                        padding:
                            const EdgeInsets.only(bottom: AppTheme.spacingSm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _RouteReservationBanner(order: order, now: now),
                            OrderCard(
                              order: order,
                              showFeeAndCashSummary: true,
                              topContent: isNextDelivery
                                  ? const _NextDeliveryMarker()
                                  : null,
                              onTap: () => _openOrderDetail(order),
                              trailing: _OrderActions(
                                order: order,
                                onDetail: () => _openOrderDetail(order),
                                onOpenMap: () => _openSingleOrderMap(order),
                                onWhatsApp: isNextDelivery &&
                                        _hasCustomerPhone(order)
                                    ? () =>
                                        _contactCustomer(order, whatsapp: true)
                                    : null,
                                onCall:
                                    isNextDelivery && _hasCustomerPhone(order)
                                        ? () => _contactCustomer(order)
                                        : null,
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
                    childCount: displayOrders.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NextDeliveryMarker extends StatelessWidget {
  const _NextDeliveryMarker();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.45),
        ),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.near_me_outlined,
            size: 14,
            color: AppColors.primaryLight,
          ),
          SizedBox(width: 5),
          Text(
            'Siguiente entrega',
            style: TextStyle(
              color: AppColors.primaryLight,
              fontSize: 11,
              fontWeight: FontWeight.w800,
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
  final VoidCallback? onWhatsApp;
  final VoidCallback? onCall;
  final VoidCallback onStatus;
  final VoidCallback? onReprint;
  final bool reprintLoading;

  const _OrderActions({
    required this.order,
    required this.onDetail,
    required this.onOpenMap,
    this.onWhatsApp,
    this.onCall,
    required this.onStatus,
    this.onReprint,
    this.reprintLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 6, children: [
      CompactActionButton(icon: Icons.check_circle_outline, label: 'Entregar',
        color: AppColors.accentDark, onTap: onStatus, filled: true),
      CompactActionButton(icon: Icons.receipt_long_outlined, label: 'Ver',
        color: AppColors.primary, onTap: onDetail),
      CompactActionButton(icon: Icons.navigation_outlined, label: 'Ir',
        color: AppColors.primary, onTap: onOpenMap),
      PopupMenuButton<String>(tooltip: 'Más acciones',
        onSelected: (action) {
          switch (action) {
            case 'whatsapp': onWhatsApp?.call(); break;
            case 'call': onCall?.call(); break;
            case 'print': if (!reprintLoading) onReprint?.call(); break;
          }
        }, itemBuilder: (_) => [
          if (onWhatsApp != null) const PopupMenuItem(value: 'whatsapp', child: Text('WhatsApp')),
          if (onCall != null) const PopupMenuItem(value: 'call', child: Text('Llamar')),
          if (onReprint != null) PopupMenuItem(value: 'print', enabled: !reprintLoading,
            child: Text(reprintLoading ? 'Enviando…' : 'Reimprimir ticket')),
        ]),
    ]);
  }
}
