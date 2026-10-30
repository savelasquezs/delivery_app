import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:delivery_app/core/api/refresh_access_result.dart';
import 'package:delivery_app/core/api/dio_client.dart';
import 'package:delivery_app/core/version/delivery_app_version.dart';
import 'package:delivery_app/features/auth/data/auth_repository.dart';
import 'package:delivery_app/features/tracking/work_session_repository.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:delivery_app/core/auth/session_refresh.dart';
import 'package:delivery_app/core/auth/token_session.dart';
import 'package:delivery_app/core/storage/secure_storage.dart';
import 'package:delivery_app/features/tracking/tracking_http_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

String jwt(DateTime expiry) =>
    'header.${base64Url.encode(utf8.encode(jsonEncode({
              'exp': expiry.millisecondsSinceEpoch ~/ 1000
            }))).replaceAll('=', '')}.signature';

class MemoryState {
  TokenSession? session;
  String? workSessionData = 'session-a';
  Future<void> tail = Future.value();
  MemoryState(this.session);
}

class MemoryStorage extends SecureStorage {
  final MemoryState state;
  final bool locked;
  MemoryStorage(this.state, {this.locked = false});
  @override
  Future<T> withSessionLock<T>(Future<T> Function(SecureStorage) body) async {
    if (locked) return body(this);
    final before = state.tail;
    final done = Completer<void>();
    state.tail = done.future;
    await before;
    try {
      return await body(MemoryStorage(state, locked: true));
    } finally {
      done.complete();
    }
  }

  @override
  Future<TokenSession?> readSession() async => state.session;
  @override
  Future<void> writeSession(TokenSession value) => withSessionLock((_) async {
        state.session = value;
      });
  @override
  Future<String?> getWorkSessionData() async => state.workSessionData;
  @override
  Future<void> saveWorkSessionData(String value) async =>
      state.workSessionData = value;
  @override
  Future<void> deleteWorkSessionData() async => state.workSessionData = null;
  @override
  Future<void> clearAll() => withSessionLock((_) async {
        state.session = null;
      });
}

class MemoryPauses implements UploadPauseStore {
  final values = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String id) async => values[id];
  @override
  Future<void> write(String id, Map<String, dynamic> value) async {
    values[id] = value;
  }

  @override
  Future<void> clear(String id) async {
    values.remove(id);
  }
}

class FakeAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  int calls = 0;
  FakeAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody reply(int code,
        [Object body = const {}, Map<String, List<String>> extra = const {}]) =>
    ResponseBody.fromString(jsonEncode(body), code, headers: {
      'content-type': ['application/json'],
      ...extra
    });

Dio http(FakeAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://example.test/api'))
      ..httpClientAdapter = adapter;

void main() {
  late DateTime clock;
  late MemoryState state;
  late MemoryStorage storage;
  late String fresh;
  DioClient client(FakeAdapter adapter) {
    dotenv.testLoad(fileInput: 'API_BASE_URL=https://example.test/api');
    final result = DioClient(
        storage,
        DeliveryAppVersionInfoLoader(
            load: () async => PackageInfo(
                appName: 'Delivery',
                packageName: 'delivery',
                version: '1',
                buildNumber: '1')));
    result.dio.httpClientAdapter = adapter;
    return result;
  }

  test(
      'unconfirmed remote logout preserves local credentials without refreshing',
      () async {
    final adapter = FakeAdapter((_) => reply(503));
    await expectLater(
        AuthRepository(client(adapter), storage)
            .logout(expectedSessionId: 'login-a'),
        throwsA(isA<DioException>()));
    expect(state.session?.id, 'login-a');
    expect(adapter.calls, 1);
  });
  test(
      'pending-delivery rejection preserves authentication and work-session cache',
      () async {
    final adapter = FakeAdapter((_) =>
        reply(400, {'message': 'Entrega o reasigna tus pedidos pendientes.'}));
    await expectLater(
        AuthRepository(client(adapter), storage)
            .logout(expectedSessionId: 'login-a'),
        throwsA(isA<DioException>()));
    expect(state.session?.id, 'login-a');
    await expectLater(
        WorkSessionRepository(client(adapter), storage)
            .closeCurrent(expectedSessionId: 'login-a'),
        throwsA(isA<DioException>()));
    expect(state.workSessionData, 'session-a');
  });
  test('confirmed logout clears credentials', () async {
    final adapter = FakeAdapter((_) => reply(200));
    await AuthRepository(client(adapter), storage)
        .logout(expectedSessionId: 'login-a');
    expect(state.session, isNull);
  });
  test('late logout and work-session close preserve a replacement account',
      () async {
    for (final logout in [true, false]) {
      final entered = Completer<void>(), response = Completer<ResponseBody>();
      final adapter = FakeAdapter((_) {
        entered.complete();
        return response.future;
      });
      final dio = client(adapter);
      state.session = TokenSession(
          id: 'login-a', accessToken: fresh, refreshToken: 'refresh-a');
      state.workSessionData = 'session-b';
      final request = logout
          ? AuthRepository(dio, storage).logout(expectedSessionId: 'login-a')
          : WorkSessionRepository(dio, storage)
              .closeCurrent(expectedSessionId: 'login-a');
      await entered.future;
      state.session = TokenSession(
          id: 'login-b', accessToken: fresh, refreshToken: 'refresh-b');
      response.complete(reply(200));
      await request;
      expect(state.session!.id, 'login-b');
      expect(state.workSessionData, 'session-b');
    }
  });
  test('remote cleanup deadline cancels an unresponsive transport', () async {
    final response = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => response.future);
    final watch = Stopwatch()..start();
    await client(adapter).closeSessionResource('/auth/logout',
        sessionId: 'login-a', timeout: const Duration(milliseconds: 30));
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(adapter.calls, 1);
    response.complete(reply(200));
  });
  setUp(() {
    clock = DateTime.now().toUtc();
    fresh = jwt(clock.add(const Duration(hours: 2)));
    state = MemoryState(TokenSession(
        id: 'login-a',
        accessToken: jwt(clock.subtract(const Duration(minutes: 1))),
        refreshToken: 'refresh-a'));
    storage = MemoryStorage(state);
  });

  SessionRefresher refresher(FakeAdapter adapter, {MemoryStorage? store}) =>
      SessionRefresher(
        storage: store ?? storage,
        baseUrl: 'https://example.test/api',
        versionHeaders: () async => {'X-Delivery-App-Build': '11'},
        dio: http(adapter),
        now: () => clock,
      );

  test('background refresh sends old bearer, version headers and rotating pair',
      () async {
    final previous = state.session!.accessToken;
    final adapter = FakeAdapter((request) {
      expect(request.path, '/auth/refresh');
      expect(request.headers['Authorization'], 'Bearer $previous');
      expect(request.headers['X-Delivery-App-Build'], '11');
      expect(request.data, {'refreshToken': 'refresh-a'});
      return reply(200, {'token': fresh, 'refreshToken': 'refresh-b'});
    });
    expect(await refresher(adapter).ensureAccess(expectedSessionId: 'login-a'),
        isA<RefreshAccessSuccess>());
    expect(state.session!.accessToken, fresh);
    expect(state.session!.refreshToken, 'refresh-b');
    expect(state.session!.id, 'login-a');
  });

  test('two independent clients perform only one concurrent refresh', () async {
    final adapter = FakeAdapter((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return reply(200, {'token': fresh, 'refreshToken': 'refresh-b'});
    });
    final results = await Future.wait([
      refresher(adapter).ensureAccess(),
      refresher(adapter, store: MemoryStorage(state)).ensureAccess(),
    ]);
    expect(adapter.calls, 1);
    expect(results, everyElement(isA<RefreshAccessSuccess>()));
  });

  test('logout queued during refresh cannot be resurrected by late completion',
      () async {
    final entered = Completer<void>();
    final finish = Completer<void>();
    final adapter = FakeAdapter((_) async {
      entered.complete();
      await finish.future;
      return reply(200, {'token': fresh, 'refreshToken': 'refresh-b'});
    });
    final pending = refresher(adapter).ensureAccess();
    await entered.future;
    final logout = MemoryStorage(state).clearAll();
    finish.complete();
    await pending;
    await logout;
    expect(state.session, isNull);
  });

  test('newer login is never refreshed or deleted for an old tracking task',
      () async {
    state.session = TokenSession(
        id: 'login-b', accessToken: fresh, refreshToken: 'refresh-b');
    final adapter = FakeAdapter((_) => reply(401));
    final result =
        await refresher(adapter).ensureAccess(expectedSessionId: 'login-a');
    expect(result, isA<RefreshAccessSessionChanged>());
    expect(adapter.calls, 0);
    expect(state.session!.id, 'login-b');
  });

  test('503 refresh preserves credentials and shares cooldown across clients',
      () async {
    final old = state.session!;
    final adapter = FakeAdapter((_) => reply(503));
    expect(await refresher(adapter).ensureAccess(),
        isA<RefreshAccessTransientFailure>());
    expect(await refresher(adapter, store: MemoryStorage(state)).ensureAccess(),
        isA<RefreshAccessTransientFailure>());
    expect(adapter.calls, 1);
    expect(state.session!.accessToken, old.accessToken);
    expect(state.session!.refreshToken, old.refreshToken);
    clock = clock.add(const Duration(seconds: 16));
    await refresher(adapter).ensureAccess();
    expect(adapter.calls, 2);
  });

  test('refresh rejection ends session, generic bad requests do not', () async {
    final adapter =
        FakeAdapter((_) => reply(400, {'message': 'Invalid header'}));
    expect(await refresher(adapter).ensureAccess(),
        isA<RefreshAccessTransientFailure>());
    expect(state.session, isNotNull);
    clock = clock.add(const Duration(seconds: 16));
    expect(await refresher(FakeAdapter((_) => reply(401))).ensureAccess(),
        isA<RefreshAccessSessionEnded>());
    expect(state.session, isNull);
  });

  test('incomplete rotating pair never overwrites stored tokens', () async {
    final old = state.session!;
    final adapter = FakeAdapter((_) => reply(200, {'token': fresh}));
    expect(await refresher(adapter).ensureAccess(),
        isA<RefreshAccessTransientFailure>());
    expect(state.session!.accessToken, old.accessToken);
    expect(state.session!.refreshToken, old.refreshToken);
  });

  TrackingHttpClient tracking(
          FakeAdapter send, FakeAdapter refresh, MemoryPauses pauses) =>
      TrackingHttpClient(
        baseUrl: 'https://example.test/api',
        sessionId: 'login-a',
        dio: http(send),
        auth: refresher(refresh),
        pauses: pauses,
        versionHeaders: () async => {},
        isCurrent: () async => true,
        now: () => clock,
      );

  test('1000 rejected points cause two sends and one refresh, not a storm',
      () async {
    state.session = TokenSession(
        id: 'login-a', accessToken: fresh, refreshToken: 'refresh-a');
    final refreshed = jwt(clock.add(const Duration(hours: 3)));
    final refresh = FakeAdapter(
        (_) => reply(200, {'token': refreshed, 'refreshToken': 'refresh-b'}));
    final send = FakeAdapter((_) => reply(401));
    final pauses = MemoryPauses();
    final client = tracking(send, refresh, pauses);
    for (var i = 0; i < 1000; i++) {
      await expectLater(
          client.post('/deliverymen/location', data: {'clientPointId': '$i'}),
          throwsA(isA<DioException>()));
    }
    expect(send.calls, 2);
    expect(refresh.calls, 1);
    expect(state.session, isNotNull);
  });

  test('fresh credentials retry a location once and remove local-only metadata',
      () async {
    state.session = TokenSession(
        id: 'login-a', accessToken: fresh, refreshToken: 'refresh-a');
    final refreshed = jwt(clock.add(const Duration(hours: 3)));
    final seen = <String>[];
    final send = FakeAdapter((request) {
      seen.add(request.headers['Authorization'] as String);
      expect(request.data, {'clientPointId': 'point-a'});
      return reply(seen.length == 1 ? 401 : 200);
    });
    final refresh = FakeAdapter(
        (_) => reply(200, {'token': refreshed, 'refreshToken': 'refresh-b'}));
    await tracking(send, refresh, MemoryPauses()).post('/deliverymen/location',
        data: {'clientPointId': 'point-a', '_authSessionId': 'login-a'});
    expect(seen, ['Bearer $fresh', 'Bearer $refreshed']);
  });

  test('location and device-event clients respect the same Retry-After',
      () async {
    state.session = TokenSession(
        id: 'login-a', accessToken: fresh, refreshToken: 'refresh-a');
    final send = FakeAdapter((_) => reply(429, {}, {
          'retry-after': ['120']
        }));
    final refresh = FakeAdapter((_) => reply(500));
    final pauses = MemoryPauses();
    await expectLater(
        tracking(send, refresh, pauses).post('/deliverymen/location', data: {}),
        throwsA(isA<DioException>()));
    clock = clock.add(const Duration(seconds: 60));
    await expectLater(
        tracking(send, refresh, pauses)
            .post('/deliverymen/device-event', data: {}),
        throwsA(isA<DioException>()));
    expect(send.calls, 1);
    expect(refresh.calls, 0);
  });

  test('session replacement does not attempt to refresh a revoked session',
      () async {
    state.session = TokenSession(
        id: 'login-a', accessToken: fresh, refreshToken: 'refresh-a');
    final send = FakeAdapter((_) => reply(401, {'code': 'SESSION_REPLACED'}));
    final refresh = FakeAdapter((_) => reply(200));
    await expectLater(
        tracking(send, refresh, MemoryPauses())
            .post('/deliverymen/location', data: {}),
        throwsA(isA<DioException>()));
    expect(send.calls, 1);
    expect(refresh.calls, 0);
    expect(state.session, isNull);
  });

  test('backoff respects seconds, HTTP date, cap and positive jitter', () {
    expect(retryDelay(1, now: clock), const Duration(seconds: 15));
    expect(retryDelay(20, now: clock), const Duration(seconds: 300));
    expect(retryDelay(1, now: clock, retryAfter: '120'),
        const Duration(seconds: 120));
    final date = HttpDate.format(clock.add(const Duration(minutes: 3)));
    expect(retryDelay(1, now: clock, retryAfter: date).inSeconds,
        inInclusiveRange(179, 180));
    expect(retryDelay(1, now: clock, jitter: 0.2), const Duration(seconds: 18));
  });

  test('authentication pause is not mislabeled as loss of mobile coverage', () {
    final options = RequestOptions(path: '/deliverymen/location');
    final paused = DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
        error: const TrackingDeferred());
    expect(isLocationTransportFailure(paused), isFalse);
    expect(
        isLocationTransportFailure(DioException(
            requestOptions: options, type: DioExceptionType.connectionTimeout)),
        isTrue);
    for (final status in [408, 429, 500, 502, 503]) {
      expect(
          isTransientSessionFailure(DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: status))),
          isTrue);
    }
    expect(
        isTransientSessionFailure(DioException(
            requestOptions: options,
            response: Response(requestOptions: options, statusCode: 401),
            error: const SessionRefreshUnavailable())),
        isTrue);
  });
}
