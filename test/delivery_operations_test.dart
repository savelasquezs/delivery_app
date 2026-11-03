import 'dart:async';
import 'dart:convert';
import 'package:delivery_app/core/api/dio_client.dart';
import 'package:delivery_app/core/auth/token_session.dart';
import 'package:delivery_app/core/storage/secure_storage.dart';
import 'package:delivery_app/core/version/delivery_app_version.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:delivery_app/features/route/delivery_operations.dart';
import 'package:delivery_app/features/tracking/tracking_outbox.dart';
import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

TokenSession auth(int user) => TokenSession(
    id: 'login-$user',
    refreshToken: 'refresh',
    accessToken: 'header.${base64Url.encode(utf8.encode(jsonEncode({
              'tenant_id': 1,
              'nameid': user
            }))).replaceAll('=', '')}.signature');

class Store extends SecureStorage {
  TokenSession session = auth(9);
  int workSessionId = 4;
  @override
  Future<TokenSession?> readSession() async => session;
  @override
  Future<String?> getWorkSessionData() async => jsonEncode({
        'id': workSessionId,
        'deliverymanId': 9,
        'branchId': 1,
        'autoCloseAt': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .toIso8601String()
      });
}

class Client extends DioClient {
  final sent = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function()? respond;
  Map<String, dynamic>? routeSnapshot;
  Map<String, dynamic>? orderSnapshot;
  final orderSnapshots = <int, Map<String, dynamic>>{};
  final fetchedOrderIds = <int>[];
  Client(SecureStorage storage)
      : super(storage, DeliveryAppVersionInfoLoader());
  @override
  Future<T> get<T>(String path,
      {Map<String, dynamic>? queryParameters,
      T Function(dynamic)? fromJson, Options? options,
      CancelToken? cancelToken}) async {
    if (path == '/deliverymen/me/active-route' && routeSnapshot != null)
      return fromJson!(routeSnapshot);
    if (path.startsWith('/orders/') && path.endsWith('/details')) {
      if (orderSnapshot == null) throw StateError('No server order snapshot available');
      return fromJson!(orderSnapshot);
    }
    if (path.startsWith('/orders/')) {
      final id = int.tryParse(path.split('/').last);
      if (id != null) {
        fetchedOrderIds.add(id);
        final order = orderSnapshots[id];
        if (order == null) {
          throw DioException(
              requestOptions: RequestOptions(path: path),
              type: DioExceptionType.connectionError);
        }
        return fromJson!(order);
      }
    }
    return super.get(path, queryParameters: queryParameters,
        fromJson: fromJson, options: options, cancelToken: cancelToken);
  }
  @override
  Future<T> post<T>(String path,
      {dynamic data, T Function(dynamic)? fromJson, Options? options}) async {
    sent.add(Map<String, dynamic>.from(data as Map));
    if (respond == null)
      throw DioException(
          requestOptions: RequestOptions(path: path),
          type: DioExceptionType.connectionTimeout);
    return fromJson!(await respond!());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('backend nameid identifies the same owner across logins and separates accounts', () {
    final first = auth(9);
    final next = TokenSession(id: 'new-login', accessToken: first.accessToken, refreshToken: 'rotated');
    expect(first.ownerKey('local'), next.ownerKey('local'));
    expect(first.ownerKey('local'), isNot(auth(10).ownerKey('local')));
    expect(first.ownerKey('local'), isNot(first.ownerKey('other-server')));
  });
  late Database db;
  late TrackingOutbox outbox;
  late Store storage;
  late Client client;
  late DeliveryOperations operations;
  final order = Order.fromJson({
    'id': 12,
    'branchId': 1,
    'deliveryManId': 9,
    'deliveryRouteId': 5,
    'status': 'onTheWay',
    'type': 'delivery',
    'createdAt': '2026-10-25T12:00:00Z',
    'total': 30000,
    'managementVersion': 3,
    'addressVersion': 'opaque-address-version'
  });
  setUp(() async {
    dotenv.testLoad(fileInput: 'API_BASE_URL=http://127.0.0.1:5000/api');
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    storage = Store();
    client = Client(storage);
    outbox = TrackingOutbox(open: () async => db);
    operations = DeliveryOperations(client, storage, outbox: outbox);
  });
  tearDown(() => db.close());

  const staleTakeId = 'd20d2000-0000-4000-8000-000000000001';
  void serverRoute({String? lastTakeId}) {
    client.routeSnapshot = {
      'revision': 8,
      'routeId': null,
      'orders': [],
      'lastTakeId': lastTakeId
    };
  }

  Map<String, dynamic> liveOrder(int id,
          {String status = 'ready', int? driver}) =>
      {'id': id, 'status': status, 'deliveryManId': driver, 'branchId': 1};

  Future<void> queuedTake(List<int> ids,
      {bool conflict = false,
      String operationId = staleTakeId,
      int workSessionId = 4,
      String? expectedLastTakeId}) async {
    final key = await operations.owner();
    await outbox.enqueueOperation(key, {
      'operationId': operationId,
      'kind': 'take',
      'selection': {'orderIds': ids},
      'workSessionId': workSessionId,
      'expectedLastTakeId': expectedLastTakeId
    }, {});
    if (conflict) {
      await outbox.finishOperation(key, operationId,
          conflict: 'La asignación anterior fue rechazada.');
    }
  }

  test(
      'offline save is durable before HTTP and retries the exact intent after a timeout',
      () async {
    await operations
        .record(order, 'address', changes: {'additionalInfo': 'Torre 2'});
    expect(client.sent, isEmpty);
    final key = await operations.owner();
    final original = (await outbox.operations(key)).single;
    await operations.sync();
    expect(await outbox.operations(key), hasLength(1));
    expect(jsonDecode(original['payload'] as String)['changes'],
        {'additionalInfo': 'Torre 2'});
    await outbox.finishOperation(key, original['id'] as String, retryAt: 0);
    client.respond = () async => {
          'context': {'revision': 4, 'routeId': 5, 'orders': []}
        };
    await operations.sync();
    expect(client.sent[0], client.sent[1]);
    expect(await outbox.operations(key), isEmpty);
  });

  test(
      'duplicate delivery and a command from another account cannot be recorded',
      () async {
    await operations.record(order, 'deliver');
    await expectLater(operations.record(order, 'deliver'), throwsStateError);
    storage.session = auth(10);
    await expectLater(operations.record(order, 'deliver'), throwsStateError);
    expect(await operations.pending(), isEmpty);
  });

  test(
      'late successful response acknowledges only the original owner after an account switch',
      () async {
    await operations.record(order, 'deliver');
    final originalOwner = await operations.owner();
    final response = Completer<Map<String, dynamic>>();
    client.respond = () => response.future;
    final sending = operations.sync();
    for (var i = 0; client.sent.isEmpty && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(client.sent, hasLength(1));
    storage.session = auth(10);
    response.complete({
      'context': {'revision': 6, 'routeId': null, 'orders': []}
    });
    await sending;
    expect(await outbox.operations(originalOwner), isEmpty);
    expect(await operations.cachedContext(), isNull);
    expect((await outbox.cached(originalOwner, 'route'))!['revision'], 6);
  });
  test(
      'concurrent taps persist one intent and conflicts do not block another order',
      () async {
    final attempts = await Future.wait([
      operations
          .record(order, 'deliver')
          .then((_) => true, onError: (_) => false),
      operations
          .record(order, 'deliver')
          .then((_) => true, onError: (_) => false),
    ]);
    expect(attempts.where((saved) => saved), hasLength(1));
    await operations.record(
        Order.fromJson({...order.rawJson, 'id': 13}), 'deliver');
    client.respond = () async {
      if (client.sent.last['orderId'] == 12) {
        throw DioException(
            requestOptions: RequestOptions(path: '/operations'),
            response: Response(
                requestOptions: RequestOptions(path: '/operations'),
                statusCode: 409));
      }
      return {
        'context': {'revision': 5, 'orders': []}
      };
    };
    await operations.sync();
    final pending = await operations.pending();
    expect(pending, hasLength(1));
    expect(pending.single['state'], 'conflict');
    expect(jsonDecode(pending.single['payload'] as String)['orderId'], 12);
  });
  test('address conflict preserves ordering across orders sharing that address', () async {
    final sharedAddress = Order.fromJson({...order.rawJson, 'addressId': 7});
    await operations.record(sharedAddress, 'address', changes: {'additionalInfo': 'First'});
    await operations.record(Order.fromJson({...sharedAddress.rawJson, 'id': 13}),
        'address', changes: {'additionalInfo': 'Second'});
    await operations.record(Order.fromJson({...order.rawJson, 'id': 14}), 'deliver');
    client.respond = () async {
      if (client.sent.last['kind'] == 'address') {
        throw DioException(requestOptions: RequestOptions(path: '/operations'),
          response: Response(requestOptions: RequestOptions(path: '/operations'), statusCode: 409));
      }
      return {'context': {'revision': 6, 'orders': []}};
    };
    await operations.sync();
    expect(client.sent.map((p) => p['orderId']), [12, 14]);
    expect((await operations.pending()).map((p) => p['state']), ['conflict', 'pending']);
  });

  test('permission denial retains an uncertain intent until it can reconcile', () async {
    await operations.record(order, 'deliver');
    client.respond = () async => throw DioException(requestOptions: RequestOptions(path: '/operations'),
      response: Response(requestOptions: RequestOptions(path: '/operations'), statusCode: 403));
    await operations.sync();
    final key = await operations.owner();
    final row = (await operations.pending()).single;
    expect(row['state'], 'pending');
    await outbox.discardOperationConflict(key, row['id'] as String);
    expect(await operations.pending(), hasLength(1));
    await outbox.finishOperation(key, row['id'] as String, retryAt: 0);
    client.respond = () async => {'context': {'revision': 8, 'orders': []}};
    await operations.sync();
    expect(client.sent.first, client.sent.last);
    expect(await operations.pending(), isEmpty);
  });

  test('409 with delivered server state acknowledges the original delivery once',
      () async {
    await operations.record(order, 'deliver');
    client.orderSnapshot = {...order.rawJson, 'status': 'delivered'};
    client.respond = () async => throw DioException(
      requestOptions: RequestOptions(path: '/operations'),
      response: Response(
          requestOptions: RequestOptions(path: '/operations'), statusCode: 409));
    await operations.sync();
    expect(await operations.pending(), isEmpty);
    expect(client.sent, hasLength(1));
  });

  test('409 with another route is a genuine conflict and retains the delivery',
      () async {
    await operations.record(order, 'deliver');
    client.orderSnapshot = {
      ...order.rawJson,
      'status': 'delivered',
      'deliveryRouteId': 99
    };
    client.respond = () async => throw DioException(
      requestOptions: RequestOptions(path: '/operations'),
      response: Response(
          requestOptions: RequestOptions(path: '/operations'), statusCode: 409));
    await operations.sync();
    expect((await operations.pending()).single['state'], 'conflict');
  });

  test('409 from a lost take response reconciles only matching server take id',
      () async {
    const takeId = 'e3f69d0f-8b3f-45b5-a5d8-7169f073a907';
    final key = await operations.owner();
    await outbox.enqueueOperation(
      key, {'operationId': takeId, 'kind': 'take'}, {});
    client.routeSnapshot = {
      'revision': 8,
      'routeId': 26,
      'orders': [],
      'lastTakeId': takeId,
    };
    client.respond = () async => throw DioException(
      requestOptions: RequestOptions(path: '/operations'),
      response: Response(
          requestOptions: RequestOptions(path: '/operations'), statusCode: 409));
    await operations.sync();
    expect(await operations.pending(), isEmpty);
  });

  test('new route explicitly confirms the exact prior order and address', () async {
    final oldOrder = Order.fromJson({
      ...order.rawJson,
      'addressDescription': 'Calle 91 # 70-25',
      'neighborhoodName': 'Santander'
    });
    client.routeSnapshot = {
      'revision': 4,
      'routeId': 5,
      'orders': [oldOrder.rawJson],
      'neighborhoods': []
    };
    final previous = await operations.pendingBeforeNextRoute();
    expect(previous.map((o) => o.id), [12]);
    final prompt = previousRouteConfirmationMessage(previous);
    expect(prompt, contains('pedido(s)'));
    expect(prompt, contains('#12'));
    expect(prompt, contains('Calle 91 # 70-25'));
    expect(prompt, contains('ENTREGADOS'));

    await expectLater(operations.take({'orderIds': [21]}), throwsStateError);
    expect(await operations.pending(), isEmpty);
    expect(client.sent, isEmpty);

    client.respond = () async => {
      'context': {
        'revision': 5,
        'routeId': 20,
        'lastTakeId': client.sent.last['operationId'],
        'orders': [
          {
            ...order.rawJson,
            'id': 21,
            'status': 'onTheWay',
            'deliveryRouteId': 20,
          }
        ]
      }
    };
    final assigned = await operations.take(
        {'orderIds': [21]}, confirmedPreviousDeliveries: previous);
    expect(client.sent, hasLength(1));
    expect(client.sent.single['confirmedPreviousDeliveries'], [
      {'orderId': 12, 'expectedVersion': 3}
    ]);
    expect(assigned.single.id, 21);
    expect(await operations.pending(), isEmpty);
  });


  test('old selection assigned to another driver no longer blocks', () async {
    serverRoute();
    await queuedTake([9393, 9394], conflict: true);
    client.orderSnapshots[9393] =
        liveOrder(9393, status: 'onTheWay', driver: 26);
    client.orderSnapshots[9394] = liveOrder(9394);

    await operations.pendingBeforeNextRoute();
    expect(await operations.pending(), isEmpty);
    expect(client.fetchedOrderIds, [9393]);
    expect(client.sent, isEmpty);
  });

  test('old take assigned to the same driver is acknowledged, not delivered', () async {
    serverRoute();
    await queuedTake([21], conflict: true);
    client.orderSnapshots[21] =
        liveOrder(21, status: 'onTheWay', driver: 9);

    await operations.pendingBeforeNextRoute();
    expect(await operations.pending(), isEmpty);
    expect(client.sent, isEmpty);
    expect(client.orderSnapshots[21]!['status'], 'onTheWay');
  });

  test('cancelled order invalidates an entire old selection', () async {
    serverRoute();
    await queuedTake([21, 22], conflict: true);
    client.orderSnapshots[21] = liveOrder(21);
    client.orderSnapshots[22] =
        liveOrder(22, status: 'cancelled');

    await operations.pendingBeforeNextRoute();
    expect(await operations.pending(), isEmpty);
    expect(client.fetchedOrderIds, [21, 22]);
  });

  test('a rejected take with available orders can be retried fresh', () async {
    serverRoute();
    await queuedTake([21], conflict: true);
    client.orderSnapshots[21] = liveOrder(21);

    client.respond = () async => {
          'context': {
            'revision': 9,
            'routeId': 88,
            'orders': [],
            'lastTakeId': client.sent.last['operationId']
          }
        };
    await operations.take({'orderIds': [22]});
    expect(client.sent, hasLength(1));
    expect(client.sent.single['selection'], {'orderIds': [22]});
    expect(await operations.pending(), isEmpty);
  });

  test('still available unconfirmed take is never silently dropped', () async {
    serverRoute();
    await queuedTake([21]);
    client.orderSnapshots[21] = liveOrder(21);

    await operations.pendingBeforeNextRoute();
    final pending = await operations.pending();
    expect(pending, hasLength(1));
    expect(pending.single['state'], 'pending');
    expect(client.fetchedOrderIds, [21]);
  });

  test('an old work session cannot block the new shift', () async {
    serverRoute();
    storage.workSessionId = 7;
    await queuedTake([21], conflict: true, workSessionId: 4);

    await operations.pendingBeforeNextRoute();
    expect(await operations.pending(), isEmpty);
    expect(client.fetchedOrderIds, isEmpty);
  });

  test('lastTakeId receipt clears a lost take ACK without order queries', () async {
    serverRoute(lastTakeId: staleTakeId);
    await queuedTake([21], conflict: true);

    await operations.pendingBeforeNextRoute();
    expect(await operations.pending(), isEmpty);
    expect(client.fetchedOrderIds, isEmpty);
  });

  test('a superseded lastTakeId clears an impossible old take', () async {
    serverRoute(lastTakeId: 'a20d2000-0000-4000-8000-000000000002');
    await queuedTake([21], conflict: true,
        expectedLastTakeId: 'a20d2000-0000-4000-8000-000000000003');

    await operations.pendingBeforeNextRoute();
    expect(await operations.pending(), isEmpty);
  });

  test('missing authoritative order data preserves a conflict', () async {
    serverRoute();
    await queuedTake([21], conflict: true);

    await operations.pendingBeforeNextRoute();
    final pending = await operations.pending();
    expect(pending, hasLength(1));
    expect(pending.single['state'], 'conflict');
  });

  test('reconciling take never deletes an unsent delivery', () async {
    serverRoute();
    final key = await operations.owner();
    await operations.record(order, 'deliver');
    final deliveryId = (await operations.pending()).single['id'] as String;
    await outbox.finishOperation(key, deliveryId,
        conflict: 'Pedido modificado.');
    await queuedTake([21], conflict: true);
    client.orderSnapshots[21] =
        liveOrder(21, status: 'onTheWay', driver: 26);

    await operations.pendingBeforeNextRoute();
    final pending = await operations.pending();
    expect(pending, hasLength(1));
    expect(jsonDecode(pending.single['payload'] as String)['kind'], 'deliver');
  });

  test('no success message without a matching server take receipt', () async {
    serverRoute();
    client.respond = () async => {
          'context': {'revision': 9, 'routeId': 99, 'orders': []}
        };

    await expectLater(
        operations.take({'orderIds': [21]}), throwsStateError);
    expect(await operations.pending(), isEmpty);
  });

  test('changed previous order version requires fresh confirmation', () async {
    final oldOrder = Order.fromJson({...order.rawJson, 'managementVersion': 4});
    client.routeSnapshot = {
      'revision': 5,
      'routeId': 5,
      'orders': [oldOrder.rawJson],
    };
    await expectLater(operations.take({'orderIds': [21]},
        confirmedPreviousDeliveries: [order]), throwsStateError);
    expect(client.sent, isEmpty);
    expect(await operations.pending(), isEmpty);
  });

}
