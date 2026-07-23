import 'package:intl/intl.dart';

import '../../features/orders/models/order_models.dart';

const Duration kReservationSoonWindow = Duration(minutes: 45);

enum RouteReservationState { none, overdue, soon, scheduled }

RouteReservationState reservationStateForOrder(
  Order order,
  DateTime now, {
  Duration soonWindow = kReservationSoonWindow,
}) {
  final reservedFor = order.reservedFor;
  if (reservedFor == null) return RouteReservationState.none;
  if (!reservedFor.isAfter(now)) return RouteReservationState.overdue;
  if (!reservedFor.isAfter(now.add(soonWindow))) {
    return RouteReservationState.soon;
  }
  return RouteReservationState.scheduled;
}

String? reservationLabelForOrder(
  Order order,
  DateTime now, {
  Duration soonWindow = kReservationSoonWindow,
}) {
  final reservedFor = order.reservedFor;
  if (reservedFor == null) return null;
  final state = reservationStateForOrder(
    order,
    now,
    soonWindow: soonWindow,
  );
  return switch (state) {
    RouteReservationState.none => null,
    RouteReservationState.overdue => 'Vencida',
    RouteReservationState.soon =>
      'Próxima ${DateFormat('HH:mm').format(reservedFor.toLocal())}',
    RouteReservationState.scheduled =>
      'Reserva ${DateFormat('HH:mm').format(reservedFor.toLocal())}',
  };
}

Order? selectNextRouteOrder(
  List<Order> orders,
  DateTime now, {
  Duration soonWindow = kReservationSoonWindow,
}) {
  if (orders.isEmpty) return null;
  final indexed = orders.indexed.toList();

  int group(Order order) {
    final state = reservationStateForOrder(
      order,
      now,
      soonWindow: soonWindow,
    );
    return switch (state) {
      RouteReservationState.overdue || RouteReservationState.soon => 0,
      RouteReservationState.scheduled => 1,
      RouteReservationState.none => 2,
    };
  }

  indexed.sort((a, b) {
    final groupCompare = group(a.$2).compareTo(group(b.$2));
    if (groupCompare != 0) return groupCompare;

    final aReserved = a.$2.reservedFor;
    final bReserved = b.$2.reservedFor;
    if (aReserved != null && bReserved != null) {
      final reservationCompare = aReserved.compareTo(bReserved);
      if (reservationCompare != 0) return reservationCompare;
    }

    return a.$1.compareTo(b.$1);
  });

  return indexed.first.$2;
}

List<Order> prioritizeRouteOrdersForDisplay(
  List<Order> orders,
  DateTime now, {
  Duration soonWindow = kReservationSoonWindow,
}) {
  if (orders.isEmpty) return const [];

  final uniqueById = <int, Order>{};
  for (final order in orders) {
    uniqueById.putIfAbsent(order.id, () => order);
  }

  final uniqueOrders = uniqueById.values.toList();
  final nextOrder = selectNextRouteOrder(
    uniqueOrders,
    now,
    soonWindow: soonWindow,
  );
  if (nextOrder == null) return const [];

  return [
    nextOrder,
    for (final order in uniqueOrders)
      if (order.id != nextOrder.id) order,
  ];
}

String buildDeliveryWhatsAppMessage(Order order) {
  final rawName = order.deliveryManName?.trim();
  final sender =
      rawName != null && rawName.isNotEmpty ? rawName : 'el domiciliario';
  return 'Hola, hablas con $sender de Señor Arroz. Te hablo porque ya voy en camino.';
}
