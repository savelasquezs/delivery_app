import 'dart:async';

import 'package:delivery_app/features/available/data/branch_presence_verifier.dart';
import 'package:delivery_app/features/available/presentation/available_notifier.dart';
import 'package:delivery_app/features/orders/data/order_repository.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:delivery_app/features/routing/delivery_routing_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _OrderRepository extends Fake implements OrderRepository {
  _OrderRepository(this.read);
  final Future<List<Order>> Function() read;

  @override
  Future<List<Order>> getAvailableOrders({int? branchId}) => read();
}

class _PresenceVerifier extends Fake implements BranchPresenceVerifier {}

class _RoutingRepository extends Fake implements DeliveryRoutingRepository {}

Order _ready(int id) => Order(
      id: id,
      status: OrderStatus.ready,
      type: 'delivery',
      createdAt: DateTime.utc(2026, 10, 16),
      total: 10000,
      items: const [],
      branchId: 1,
    );

void main() {
  test('una consulta antigua no resucita pedidos tomados y recupera los demás',
      () async {
    final firstResponse = Completer<List<Order>>();
    var queries = 0;
    final notifier = AvailableNotifier(
      _OrderRepository(() {
        queries++;
        if (queries == 1) return firstResponse.future;
        return Future.value([_ready(22)]);
      }),
      _PresenceVerifier(),
      _RoutingRepository(),
      null,
      null,
      null,
      50,
    );

    final loading = notifier.load(silently: true);
    // Assignment event arrives while the first, now-stale query is pending.
    notifier.removeOrders([21]);
    firstResponse.complete([_ready(21), _ready(22)]);
    await loading;

    expect(queries, 2);
    expect(notifier.state.orders.map((o) => o.id), [22]);
  });
}
