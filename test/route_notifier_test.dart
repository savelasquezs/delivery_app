import 'dart:async';
import 'dart:convert';
import 'package:delivery_app/core/api/dio_client.dart';
import 'package:delivery_app/core/storage/secure_storage.dart';
import 'package:delivery_app/features/orders/data/order_repository.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:delivery_app/features/route/delivery_operations.dart';
import 'package:delivery_app/features/route/presentation/route_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> context(int revision, List<int> ids, {int? routeId = 4}) =>
    {
      'revision': revision,
      'routeId': routeId,
      'phase': ids.isEmpty ? 'returning' : 'delivering',
      'neighborhoods': [{'id': 99, 'name': 'Barrio guardado'}],
  'orders': [
        for (final id in ids)
          {
            'id': id,
            'deliveryManId': 7,
            'branchId': 1,
            'status': 'onTheWay',
            'type': 'delivery',
            'total': 1000,
            'createdAt': '2026-10-25T12:00:00Z'
          }
      ],
    };

class Client implements DioClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Operations extends DeliveryOperations {
  Map<String, dynamic>? cached;
  List<Map<String, Object?>> queue = [];
  late Future<Map<String, dynamic>> Function() fetch;
  Operations() : super(Client(), SecureStorage());
  @override
  Future<String> owner() async => 'owner';
  @override
  Future<Map<String, dynamic>?> cachedContext() async => cached;
  @override
  Future<List<Map<String, Object?>>> pending() async => queue;
  @override
  Future<void> sync() async {}
  @override
  Future<Map<String, dynamic>> refresh() => fetch();
}

class Repository implements OrderRepository {
  @override
  final DeliveryOperations operations;
  Repository(this.operations);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Operations operations;
  late RouteNotifier notifier;
  late List<int?> tracked;
  setUp(() {
    operations = Operations();
    tracked = [];
    notifier = RouteNotifier(Repository(operations), 7,
        syncTracking: (_, route, __) async {
          tracked.add(route);
        },
        canBeginDelivery: () async => false);
  });
  tearDown(() => notifier.dispose());

  test(
      'shows cached cards before HTTP completes and preserves them on a network failure',
      () async {
    operations.cached = context(2, [11]);
    final response = Completer<Map<String, dynamic>>();
    operations.fetch = () => response.future;
    final loading = notifier.load();
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state.orders.single.id, 11);
    expect(notifier.state.isLoading, false);
    response.completeError(StateError('offline'));
    await loading;
    expect(notifier.state.orders.single.id, 11);
    expect(notifier.state.error, isNotNull);
  });
  test('duplicate resume events share one request', () async {
    var calls = 0;
    final response = Completer<Map<String, dynamic>>();
    operations.fetch = () {
      calls++;
      return response.future;
    };
    final requests = [notifier.load(), notifier.load()];
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    response.complete(context(1, []));
    await Future.wait(requests);
    expect(calls, 1);
  });
  test('a stale response cannot replace the newer route or its GPS mode',
      () async {
    operations.cached = context(5, [12], routeId: 8);
    operations.fetch = () async => context(3, [11], routeId: 4);
    await notifier.load();
    expect(notifier.state.routeId, 8);
    expect(notifier.state.orders.single.id, 12);
    expect(tracked, [8]);
  });
  test('a realtime hint during HTTP schedules one authoritative catchup',
      () async {
    final response = Completer<Map<String, dynamic>>();
    var calls = 0;
    operations.fetch = () =>
        ++calls == 1 ? response.future : Future.value(context(2, [11, 12]));
    final loading = notifier.load();
    final hint = notifier.applyRealtimeOrders([
      Order.fromJson(context(0, [12])['orders'][0])
    ]);
    response.complete(context(1, [11]));
    await Future.wait([loading, hint]);
    expect(calls, 2);
    expect(notifier.state.orders.map((o) => o.id), [11, 12]);
  });
  test(
      'pending delivery is hidden, its address draft survives, and returning stays active',
      () async {
    operations.queue = [
      {
        'payload': jsonEncode({'kind': 'deliver', 'orderId': 11})
      },
      {
        'payload': jsonEncode({
          'kind': 'address',
          'orderId': 12,
          'changes': {'address': 'Torre 2', 'neighborhoodId': 99}
        })
      },
    ];
    operations.fetch = () async => context(1, [11, 12]);
    await notifier.load();
    expect(notifier.state.orders.single.id, 12);
    expect(notifier.state.orders.single.addressDescription, 'Torre 2');
    expect(notifier.state.orders.single.neighborhoodName, 'Barrio guardado');
    operations.fetch = () async => context(2, []);
    await notifier.load();
    expect(notifier.state.orders, isEmpty);
    expect(notifier.state.phase, 'returning');
    expect(tracked.last, 4);
    expect(notifier.state.pending, hasLength(2));
  });
  test(
      'realtime uses confirmed state and ignores foreign or unchanged payloads',
      () async {
    operations.fetch = () async => context(1, [11]);
    final hint = Order.fromJson(context(0, [11])['orders'][0]);
    expect(await notifier.applyRealtimeOrder(hint), RouteOrderChange.added);
    expect(await notifier.applyRealtimeOrder(hint), RouteOrderChange.none);
    operations.fetch = () async => context(2, []);
    expect(await notifier.applyRealtimeOrder(hint), RouteOrderChange.removed);
    expect(notifier.state.routeId, 4);
  });
  test('delivery cannot start until tracking is confirmed', () async {
    await expectLater(notifier.markOnTheWay(42), throwsStateError);
  });
}
