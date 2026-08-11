import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:delivery_app/features/realtime/order_hub_event.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _orderJson({
  int id = 15,
  int deliveryManId = 8,
  String status = 'OnTheWay',
}) {
  return {
    'id': id,
    'status': status,
    'type': 'Delivery',
    'createdAt': '2026-08-10T15:00:00Z',
    'total': 25000,
    'branchId': 1,
    'deliveryManId': deliveryManId,
    'orderDetails': <Map<String, dynamic>>[],
  };
}

void main() {
  group('classifyOrderHubEvent', () {
    test('clasifica cada evento por su alcance', () {
      expect(
        classifyOrderHubEvent(orderReadyHubEvent),
        OrderHubEventKind.ready,
      );
      expect(
        classifyOrderHubEvent(orderAssignedHubEvent),
        OrderHubEventKind.assigned,
      );
      expect(
        classifyOrderHubEvent(orderModifiedHubEvent),
        OrderHubEventKind.modified,
      );
      expect(
        classifyOrderHubEvent(deliveryRoutingPlanChangedHubEvent),
        OrderHubEventKind.routing,
      );
      expect(
        classifyOrderHubEvent(routeProposalClaimedHubEvent),
        OrderHubEventKind.routing,
      );
      expect(classifyOrderHubEvent('Unknown'), OrderHubEventKind.ignored);
    });
  });

  group('orderFromHubEvent', () {
    test('convierte pedidos listos y asignados', () {
      final ready = orderFromHubEvent(orderReadyHubEvent, [_orderJson()]);
      final assigned = orderFromHubEvent(
        orderAssignedHubEvent,
        [_orderJson(id: 16, deliveryManId: 9)],
      );

      expect(ready?.id, 15);
      expect(ready?.status, OrderStatus.onTheWay);
      expect(assigned?.id, 16);
      expect(assigned?.deliveryManId, 9);
    });

    test('extrae el pedido anidado de OrderModified', () {
      final order = orderFromHubEvent(
        orderModifiedHubEvent,
        [
          {
            'order': _orderJson(status: 'Cancelled'),
            'modificationKind': 'status',
            'kitchenChanges': null,
          },
        ],
      );

      expect(order?.id, 15);
      expect(order?.status, OrderStatus.cancelled);
      expect(order?.deliveryManId, 8);
    });

    test('ignora payloads inválidos y eventos sin pedido', () {
      expect(orderFromHubEvent(orderModifiedHubEvent, const []), isNull);
      expect(
          orderFromHubEvent(orderModifiedHubEvent, const ['invalid']), isNull);
      expect(orderFromHubEvent('Unknown', [_orderJson()]), isNull);
    });
  });
}
