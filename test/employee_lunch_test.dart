import 'package:delivery_app/core/api/dio_client.dart';
import 'package:delivery_app/features/lunch/employee_lunch.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _LunchClient implements DioClient {
  bool active = false;
  bool loseResponse = false;
  bool offline = false;
  int writes = 0;
  Map<String, dynamic>? lastBody;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<T> get<T>(String path,
      {Map<String, dynamic>? queryParameters,
      T Function(dynamic)? fromJson, Options? options, CancelToken? cancelToken}) async {
    if (offline) throw StateError('Sin conexión');
    return fromJson!({
      'serverTimeUtc': '2026-10-19T17:00:00Z',
      'activeLunch':
          active ? {'id': 7, 'startedAt': '2026-10-19T16:15:00Z'} : null,
    });
  }

  @override
  Future<T> post<T>(String path,
      {dynamic data, T Function(dynamic)? fromJson, Options? options}) async {
    writes++;
    lastBody = Map<String, dynamic>.from(data as Map);
    active = path.endsWith('/start');
    if (loseResponse) throw StateError('Se perdió la respuesta');
    return null as T;
  }
}

void main() {
  Future<(EmployeeLunchNotifier, ProviderContainer)> setup(
      _LunchClient client) async {
    final notifier = EmployeeLunchNotifier(client);
    final container = ProviderContainer(
        overrides: [employeeLunchProvider.overrideWith((ref) => notifier)]);
    final listener = container.listen(employeeLunchProvider, (_, __) {});
    addTearDown(() {
      listener.close();
      container.dispose();
    });
    await notifier.refresh();
    return (notifier, container);
  }

  test('recupera el almuerzo activo desde el servidor al abrir', () async {
    final (_, container) = await setup(_LunchClient()..active = true);
    final state = container.read(employeeLunchProvider).requireValue;
    expect(state.lunchId, 7);
    expect(state.startedAt, DateTime.utc(2026, 10, 19, 16, 15));
  });
  test(
      'reconcilia una salida guardada sin repetir la escritura cuando se pierde la respuesta',
      () async {
    final client = _LunchClient()..loseResponse = true;
    final (notifier, container) = await setup(client);
    await expectLater(notifier.change('password'), throwsStateError);
    expect(container.read(employeeLunchProvider).requireValue.active, isTrue);
    expect(client.writes, 1);
  });
  test('finaliza el intervalo identificado sin enviar otra identidad',
      () async {
    final client = _LunchClient()..active = true;
    final (notifier, container) = await setup(client);
    await notifier.change('password');
    expect(client.lastBody, {'password': 'password', 'lunchId': 7});
    expect(container.read(employeeLunchProvider).requireValue.active, isFalse);
  });
  test('conserva el almuerzo conocido y bloquea cambios si falla la consulta',
      () async {
    final client = _LunchClient()..active = true;
    final (notifier, container) = await setup(client);
    client.offline = true;
    await notifier.refresh();
    final state = container.read(employeeLunchProvider);
    expect(state.hasError, isTrue);
    expect(state.valueOrNull?.active, isTrue);
    await notifier.change('password');
    expect(client.writes, 0);
  });
}
