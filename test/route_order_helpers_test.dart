import 'package:delivery_app/core/orders/route_order_helpers.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:flutter_test/flutter_test.dart';

Order _order({
  required int id,
  DateTime? reservedFor,
  String? deliveryManName,
}) {
  return Order(
    id: id,
    status: OrderStatus.onTheWay,
    type: 'delivery',
    createdAt: DateTime.utc(2026, 1, 1, 12),
    total: 1000,
    items: const [],
    branchId: 1,
    reservedFor: reservedFor,
    deliveryManName: deliveryManName,
  );
}

void main() {
  group('reservationStateForOrder', () {
    final now = DateTime.utc(2026, 6, 13, 18);

    test('sin reservedFor no es reserva', () {
      expect(reservationStateForOrder(_order(id: 1), now),
          RouteReservationState.none);
    });

    test('clasifica vencida, proxima y programada', () {
      expect(
        reservationStateForOrder(
          _order(id: 1, reservedFor: now.subtract(const Duration(minutes: 1))),
          now,
        ),
        RouteReservationState.overdue,
      );
      expect(
        reservationStateForOrder(
          _order(id: 2, reservedFor: now.add(const Duration(minutes: 45))),
          now,
        ),
        RouteReservationState.soon,
      );
      expect(
        reservationStateForOrder(
          _order(id: 3, reservedFor: now.add(const Duration(minutes: 46))),
          now,
        ),
        RouteReservationState.scheduled,
      );
    });
  });

  group('selectNextRouteOrder', () {
    final now = DateTime.utc(2026, 6, 13, 18);

    test('reserva vencida tiene prioridad sobre pedido normal', () {
      final normal = _order(id: 1);
      final overdue = _order(
        id: 2,
        reservedFor: now.subtract(const Duration(minutes: 5)),
      );

      expect(selectNextRouteOrder([normal, overdue], now), overdue);
    });

    test('reserva proxima tiene prioridad sobre reserva futura', () {
      final scheduled = _order(
        id: 1,
        reservedFor: now.add(const Duration(hours: 2)),
      );
      final soon = _order(
        id: 2,
        reservedFor: now.add(const Duration(minutes: 20)),
      );

      expect(selectNextRouteOrder([scheduled, soon], now), soon);
    });

    test('sin reservas usa el primer pedido de la ruta', () {
      final first = _order(id: 1);
      final second = _order(id: 2);

      expect(selectNextRouteOrder([first, second], now), first);
    });
  });

  group('prioritizeRouteOrdersForDisplay', () {
    final now = DateTime.utc(2026, 6, 13, 18);

    test('mueve solo el pedido prioritario al inicio', () {
      final firstNormal = _order(id: 1);
      final urgentReservation = _order(
        id: 2,
        reservedFor: now.add(const Duration(minutes: 15)),
      );
      final secondNormal = _order(id: 3);

      final result = prioritizeRouteOrdersForDisplay(
        [firstNormal, urgentReservation, secondNormal],
        now,
      );

      expect(result.map((order) => order.id), [2, 1, 3]);
    });

    test('sin reservas conserva el orden original', () {
      final result = prioritizeRouteOrdersForDisplay(
        [_order(id: 3), _order(id: 1), _order(id: 2)],
        now,
      );

      expect(result.map((order) => order.id), [3, 1, 2]);
    });

    test('cada pedido aparece una sola vez', () {
      final first = _order(id: 1);
      final urgentReservation = _order(
        id: 2,
        reservedFor: now.subtract(const Duration(minutes: 5)),
      );

      final result = prioritizeRouteOrdersForDisplay(
        [first, urgentReservation, first, urgentReservation],
        now,
      );

      expect(result.map((order) => order.id), [2, 1]);
    });
  });

  group('buildDeliveryWhatsAppMessage', () {
    test('usa nombre de domiciliario si existe', () {
      expect(
        buildDeliveryWhatsAppMessage(_order(id: 1, deliveryManName: 'Juan')),
        'Hola, hablas con Juan de Señor Arroz. Te hablo porque ya voy en camino.',
      );
    });

    test('usa fallback sin nombre de domiciliario', () {
      expect(
        buildDeliveryWhatsAppMessage(_order(id: 1)),
        'Hola, hablas con el domiciliario de Señor Arroz. Te hablo porque ya voy en camino.',
      );
    });
  });
}
