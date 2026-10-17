import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../features/orders/models/order_models.dart';

const Duration kReservationSoonWindow = Duration(minutes: 45);

bool routeOrdersHaveSameContent(List<Order> current, List<Order> next) {
  if (identical(current, next)) return true;
  if (current.length != next.length) return false;
  for (var i = 0; i < current.length; i++) {
    if (!routeOrderHasSameContent(current[i], next[i])) return false;
  }
  return true;
}

bool routeOrderHasSameContent(Order current, Order next) {
  return current.id == next.id &&
      current.status == next.status &&
      current.type == next.type &&
      current.createdAt == next.createdAt &&
      current.total == next.total &&
      current.deliveryFee == next.deliveryFee &&
      current.notes == next.notes &&
      _sameCustomer(current.customer, next.customer) &&
      _sameAddress(current.address, next.address) &&
      _sameItems(current.items, next.items) &&
      current.branchId == next.branchId &&
      current.branchName == next.branchName &&
      current.deliveryManId == next.deliveryManId &&
      current.deliveryManName == next.deliveryManName &&
      current.deliveryRouteId == next.deliveryRouteId &&
      current.deliveryRouteStopSequence == next.deliveryRouteStopSequence &&
      current.customerId == next.customerId &&
      current.addressId == next.addressId &&
      current.addressDescription == next.addressDescription &&
      current.addressAdditionalInfo == next.addressAdditionalInfo &&
      current.neighborhoodId == next.neighborhoodId &&
      current.neighborhoodName == next.neighborhoodName &&
      current.latitude == next.latitude &&
      current.longitude == next.longitude &&
      current.deliveryRoutePlanningWarnings ==
          next.deliveryRoutePlanningWarnings &&
      _sameSummaryLines(current.summaryLines, next.summaryLines) &&
      current.paidInStoreCash == next.paidInStoreCash &&
      current.paidInStoreCashAmount == next.paidInStoreCashAmount &&
      current.nonCashPaymentsTotal == next.nonCashPaymentsTotal &&
      current.prepareAt == next.prepareAt &&
      current.reservedFor == next.reservedFor &&
      mapEquals(current.statusTimes, next.statusTimes);
}

bool _sameCustomer(OrderCustomer? current, OrderCustomer? next) {
  if (current == null || next == null) return current == next;
  return current.id == next.id &&
      current.name == next.name &&
      current.phone == next.phone;
}

bool _sameAddress(OrderAddress? current, OrderAddress? next) {
  if (current == null || next == null) return current == next;
  return current.id == next.id &&
      current.street == next.street &&
      current.neighborhood == next.neighborhood &&
      current.city == next.city &&
      current.notes == next.notes;
}

bool _sameItems(List<OrderItem> current, List<OrderItem> next) {
  if (current.length != next.length) return false;
  for (var i = 0; i < current.length; i++) {
    final a = current[i];
    final b = next[i];
    if (a.id != b.id ||
        a.productName != b.productName ||
        a.quantity != b.quantity ||
        a.unitPrice != b.unitPrice ||
        a.subtotal != b.subtotal ||
        a.notes != b.notes) {
      return false;
    }
  }
  return true;
}

bool _sameSummaryLines(
  List<OrderLineSummary> current,
  List<OrderLineSummary> next,
) {
  if (current.length != next.length) return false;
  for (var i = 0; i < current.length; i++) {
    final a = current[i];
    final b = next[i];
    if (a.productName != b.productName ||
        a.quantity != b.quantity ||
        a.categoryName != b.categoryName) {
      return false;
    }
  }
  return true;
}

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
    if (a.$2.deliveryRouteId != null &&
        a.$2.deliveryRouteId == b.$2.deliveryRouteId &&
        a.$2.deliveryRouteStopSequence != null &&
        b.$2.deliveryRouteStopSequence != null) {
      return a.$2.deliveryRouteStopSequence!
          .compareTo(b.$2.deliveryRouteStopSequence!);
    }
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
  if (uniqueOrders.isNotEmpty &&
      uniqueOrders.every((o) =>
          o.deliveryRouteId == uniqueOrders.first.deliveryRouteId &&
          o.deliveryRouteStopSequence != null)) {
    uniqueOrders.sort((a, b) =>
        a.deliveryRouteStopSequence!.compareTo(b.deliveryRouteStopSequence!));
    return uniqueOrders;
  }
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
