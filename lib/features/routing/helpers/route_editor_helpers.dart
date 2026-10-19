import '../../orders/models/order_models.dart';
import '../delivery_routing_models.dart';

typedef RouteEditorOrder = ({
  int id,
  String address,
  String? neighborhood,
  int? proposalId,
  int? routeSequence,
});

Map<int, RouteEditorOrder> routeEditorChoices(
    DeliveryRoutingPlan plan, Iterable<Order> availableOrders) {
  final choices = <int, RouteEditorOrder>{};
  for (final proposal in plan.proposals) {
    for (final stop in proposal.stops.where((stop) => stop.isReady)) {
      choices[stop.orderId] = (
        id: stop.orderId,
        address: stop.address.trim(),
        neighborhood: stop.neighborhood,
        proposalId: proposal.id,
        routeSequence: proposal.sequence,
      );
    }
  }
  for (final stop in plan.unroutedOrders.where((stop) => stop.isReady)) {
    choices.putIfAbsent(
        stop.orderId,
        () => (
              id: stop.orderId,
              address: stop.address.trim(),
              neighborhood: stop.neighborhood,
              proposalId: null,
              routeSequence: null,
            ));
  }
  for (final order in availableOrders) {
    if (order.status != OrderStatus.ready ||
        order.deliveryManId != null ||
        order.deliveryRouteId != null) {
      choices.remove(order.id);
      continue;
    }
    final previous = choices[order.id];
    choices[order.id] = (
      id: order.id,
      address: order.displayAddressLine ?? previous?.address ?? '',
      neighborhood: order.displayNeighborhoodLabel ?? previous?.neighborhood,
      proposalId: previous?.proposalId,
      routeSequence: previous?.routeSequence,
    );
  }
  return choices;
}

String routeEditorAddress(RouteEditorOrder order) =>
    order.address.isEmpty ? 'Dirección no disponible' : order.address;

String routeEditorOrderDetails(RouteEditorOrder order) => [
      if (order.neighborhood?.trim().isNotEmpty == true)
        order.neighborhood!.trim(),
      'Pedido #${order.id}',
    ].join(' · ');

String routeDurationLabel(int seconds) {
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final remaining = minutes % 60;
  return remaining == 0 ? '$hours h' : '$hours h y $remaining min';
}

String routeDistanceLabel(int meters) =>
    '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';

String routeArrivalLabel(DateTime atUtc, DateTime? departureUtc) {
  final local = atUtc.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'p. m.' : 'a. m.';
  final departure = departureUtc?.toLocal();
  final days = departure == null
      ? 0
      : DateTime.utc(local.year, local.month, local.day)
          .difference(
              DateTime.utc(departure.year, departure.month, departure.day))
          .inDays;
  final nextDay = days <= 0 ? '' : ' · +$days ${days == 1 ? 'día' : 'días'}';
  return '$hour:$minute $period aprox.$nextDay';
}
