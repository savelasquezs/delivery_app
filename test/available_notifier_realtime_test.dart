import 'dart:async';
import 'package:dio/dio.dart';

import 'package:delivery_app/features/available/data/branch_presence_verifier.dart';
import 'package:delivery_app/features/available/presentation/available_notifier.dart';
import 'package:delivery_app/features/orders/data/order_repository.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:delivery_app/features/routing/delivery_routing_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _OrderRepository extends Fake implements OrderRepository {
  _OrderRepository(this.read);
  final Future<List<Order>> Function(CancelToken? cancellation) read;

  @override
  Future<List<Order>> getAvailableOrders({int? branchId, CancelToken? cancelToken}) => read(cancelToken);
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
      _OrderRepository((_) {
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

  test('an invalidated HTTP result is aborted and exactly one fresh GET wins',
      () async {
    final slow = Completer<List<Order>>();
    final tokens = <CancelToken>[];
    var requests = 0;
    final notifier = AvailableNotifier(
      _OrderRepository((token) {
        tokens.add(token!);
        requests++;
        return requests == 1 ? slow.future : Future.value([_ready(22)]);
      }),
      _PresenceVerifier(), _RoutingRepository(), null, null, null, 50,
    );
    addTearDown(notifier.dispose);

    final pending = notifier.load(silently: true);
    notifier.removeOrders([21]); // A realtime assignment makes the old GET stale.
    expect(tokens.single.isCancelled, isTrue);
    slow.complete([_ready(21), _ready(22)]); // Even if the mock ignores abort.
    await pending;
    expect(requests, 2);
    expect(notifier.state.orders.map((order) => order.id), [22]);
    expect(tokens.last.isCancelled, isFalse);
  });

  test('cancelling a visible first GET does not leave a spinner or stale error',
      () async {
    var requests = 0;
    final notifier = AvailableNotifier(
      _OrderRepository((token) {
        requests++;
        if (requests == 1) {
          // Simulate Dio completing the cancelled request exceptionally.
          return token!.whenCancel.then<List<Order>>((error) => throw error);
        }
        return Future.value([_ready(22)]);
      }),
      _PresenceVerifier(), _RoutingRepository(), null, null, null, 50,
    );
    addTearDown(notifier.dispose);

    final pending = notifier.load();
    expect(notifier.state.isLoading, isTrue);
    notifier.removeOrders([21]);
    await pending;
    expect(requests, 2);
    expect(notifier.state.isLoading, isFalse);
    expect(notifier.state.error, isNull);
    expect(notifier.state.orders.map((order) => order.id), [22]);
  });
}
