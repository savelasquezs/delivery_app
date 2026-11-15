import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('API anterior y pedidos sin cliente conservan compatibilidad', () {
    final guest = Order.fromJson({'id': 1});
    expect(guest.customer, isNull);
    final phoneOnly = Order.fromJson({'id': 2, 'customerPhone': '3001234567'});
    expect(phoneOnly.customer?.phone, '3001234567');
    expect(phoneOnly.customer?.whatsAppUsername, isNull);
  });

  test('JSON anidado admite usuario sin teléfono ni id', () {
    final order = Order.fromJson({
      'id': 1,
      'customer': {
        'whatsAppUsername': '@cliente_arroz',
      }
    });
    expect(order.customer?.whatsAppUsername, '@cliente_arroz');
    expect(order.customer?.phone, isNull);
  });
  test('OrderDto plano admite cliente con username sin teléfono', () {
    final order = Order.fromJson({
      'id': 9831,
      'status': 'ready',
      'type': 'delivery',
      'createdAt': '2026-11-14T18:03:00Z',
      'total': 12000,
      'branchId': 1,
      'customerId': 17,
      'customerName': 'Cliente',
      'customerPhone': null,
      'customerWhatsAppUsername': '@cliente_arroz',
    });
    expect(order.customer?.phone, isNull);
    expect(order.customer?.whatsAppUsername, '@cliente_arroz');
  });

  test('preserva teléfono y username si ambos vienen en el JSON', () {
    final order = Order.fromJson({
      'id': 9832,
      'status': 'ready',
      'createdAt': '2026-11-14T18:03:00Z',
      'total': 12000,
      'branchId': 1,
      'customer': {
        'id': 17,
        'name': 'Cliente',
        'phone': '3001234567',
      },
      'customerWhatsAppUsername': '@cliente_arroz',
    });
    expect(order.customer?.phone, '3001234567');
    expect(order.customer?.whatsAppUsername, '@cliente_arroz');
  });
}
