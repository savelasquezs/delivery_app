import 'dart:async';

import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:delivery_app/features/route/presentation/route_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

Order _order({
  required int id,
  required int deliveryManId,
  OrderStatus status = OrderStatus.onTheWay,
  double total = 1000,
}) {
  return Order(
    id: id,
    status: status,
    type: 'Delivery',
    createdAt: DateTime.utc(2026, 8, 10, 15),
    total: total,
    items: const [],
    branchId: 1,
    deliveryManId: deliveryManId,
  );
}

PagedOrders _page(List<Order> orders) {
  return PagedOrders(
    items: orders,
    totalCount: orders.length,
    page: 1,
    pageSize: 100,
  );
}

RouteNotifier _notifier(RouteOrdersLoader loader) {
  return RouteNotifier.withLoader(
    deliverymanId: 7,
    loadOrders: loader,
    syncTracking: (_) async {},
  );
}

void main() {
  test('la primera carga puede mostrar loader completo', () async {
    final completer = Completer<PagedOrders>();
    final notifier = _notifier(() => completer.future);

    final load = notifier.load();

    expect(notifier.state.isLoading, isTrue);
    expect(notifier.state.orders, isEmpty);
    completer.complete(_page([_order(id: 1, deliveryManId: 7)]));
    await load;
    expect(notifier.state.isLoading, isFalse);
    expect(notifier.state.orders.single.id, 1);
  });

  test('la carga silenciosa conserva tarjetas y no activa loader', () async {
    final completer = Completer<PagedOrders>();
    final notifier = _notifier(() => completer.future);
    await notifier.applyRealtimeOrder(_order(id: 1, deliveryManId: 7));
    final stateBefore = notifier.state;

    final refresh = notifier.load(silently: true);

    expect(notifier.state.isLoading, isFalse);
    expect(notifier.state.orders.map((order) => order.id), [1]);
    completer.complete(_page([_order(id: 1, deliveryManId: 7)]));
    await refresh;
    expect(identical(notifier.state, stateBefore), isTrue);
  });

  test('un fallo silencioso mantiene la ruta sin mostrar error', () async {
    final notifier = _notifier(() async => throw Exception('sin red'));
    await notifier.applyRealtimeOrder(_order(id: 2, deliveryManId: 7));
    final stateBefore = notifier.state;

    await notifier.load(silently: true);

    expect(identical(notifier.state, stateBefore), isTrue);
    expect(notifier.state.orders.single.id, 2);
    expect(notifier.state.error, isNull);
  });

  test('eventos resumed duplicados comparten una sola consulta de ruta',
      () async {
    final completer = Completer<PagedOrders>();
    var calls = 0;
    final notifier = _notifier(() {
      calls++;
      return completer.future;
    });

    final first = notifier.load(silently: true);
    final second = notifier.load(silently: true);

    expect(calls, 1);
    completer.complete(_page(const []));
    await Future.wait([first, second]);
    expect(calls, 1);
  });

  test('solo reconcilia pedidos pertenecientes a la ruta actual', () async {
    final notifier = _notifier(() async => _page(const []));

    final foreignChange = await notifier.applyRealtimeOrder(
      _order(id: 20, deliveryManId: 9),
    );
    final added = await notifier.applyRealtimeOrder(
      _order(id: 21, deliveryManId: 7),
    );
    final unchanged = await notifier.applyRealtimeOrder(
      _order(id: 21, deliveryManId: 7),
    );
    final updated = await notifier.applyRealtimeOrder(
      _order(id: 21, deliveryManId: 7, total: 1500),
    );
    final removed = await notifier.applyRealtimeOrder(
      _order(id: 21, deliveryManId: 9),
    );

    expect(foreignChange, RouteOrderChange.none);
    expect(added, RouteOrderChange.added);
    expect(unchanged, RouteOrderChange.none);
    expect(updated, RouteOrderChange.updated);
    expect(removed, RouteOrderChange.removed);
    expect(notifier.state.orders, isEmpty);
  });
}
