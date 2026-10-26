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
  @override
  Future<TokenSession?> readSession() async => session;
  @override
  Future<String?> getWorkSessionData() async => jsonEncode({
        'id': 4,
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
  Client(SecureStorage storage)
      : super(storage, DeliveryAppVersionInfoLoader());
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

}
