import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Order conserva deliveryRouteId para asociar puntos offline', () {
    final order = Order.fromJson({
      'id': 12,
      'status': 'on_the_way',
      'type': 'delivery',
      'createdAt': '2026-07-20T18:00:00Z',
      'total': 25000,
      'branchId': 7,
      'deliveryRouteId': 44,
      'orderDetails': <dynamic>[],
    });

    expect(order.deliveryRouteId, 44);
    expect(
        order
            .copyWithAddressFields(addressDescription: 'Calle 2')
            .deliveryRouteId,
        44);
  });
}
