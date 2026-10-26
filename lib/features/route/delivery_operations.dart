import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../../core/api/dio_client.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/auth/session_refresh.dart';
import '../../core/errors/user_facing_error.dart';
import '../orders/models/order_models.dart';
import '../tracking/tracking_outbox.dart';

class DeliveryOperations {
  final DioClient client;
  final SecureStorage storage;
  final TrackingOutbox outbox;
  Future<void>? _syncing;
  DeliveryOperations(this.client, this.storage, {TrackingOutbox? outbox})
      : outbox = outbox ?? TrackingOutbox.shared;

  Future<String> owner() async {
    final auth = await storage.readSession();
    if (auth == null) throw StateError('Inicia sesión para continuar.');
    return auth.ownerKey(client.dio.options.baseUrl);
  }

  Future<Map<String, dynamic>?> cachedContext() async =>
      outbox.cached(await owner(), 'route');

  Future<Map<String, dynamic>> refresh() async {
    final key = await owner();
    final context = await client.get<Map<String, dynamic>>(
        '/deliverymen/me/active-route',
        fromJson: (value) => Map<String, dynamic>.from(value as Map));
    if (key == await owner()) {
      await outbox.cache(key, 'route', context);
      if (context['neighborhoods'] is List)
        await outbox
            .cache(key, 'neighborhoods', {'items': context['neighborhoods']});
    }
    return (await outbox.cached(key, 'route')) ?? context;
  }

  Future<List<Map<String, Object?>>> pending() async =>
      outbox.operations(await owner());

  Future<void> record(Order order, String kind,
      {Map<String, dynamic>? changes}) async {
    final key = await owner();
    final raw = await storage.getWorkSessionData();
    if (raw == null)
      throw StateError('Confirma la jornada antes de registrar esta acción.');
    final session = jsonDecode(raw) as Map;
    final now = DateTime.now().toUtc();
    final userId = int.parse((jsonDecode(key) as List)[2] as String);
    if (session['deliverymanId'] != userId ||
        order.deliveryManId != userId ||
        session['branchId'] != order.branchId) {
      throw StateError('La acción no pertenece a la sesión actual.');
    }
    if (!now.isBefore(DateTime.parse(session['autoCloseAt'] as String))) {
      throw StateError('La jornada finalizó. Conéctate para verificarla.');
    }
    if (kind == 'address' && order.addressVersion == null) {
      throw StateError(
          'Actualiza la dirección con conexión antes de corregirla.');
    }
    if (key != await owner())
      throw StateError('La sesión cambió. Vuelve a abrir el pedido.');
    await outbox.enqueueOperation(
        key,
        {
          'operationId': const Uuid().v4(),
          'kind': kind,
          'recordedAt': now.toIso8601String(),
          'orderId': order.id,
          'routeId': order.deliveryRouteId,
          'workSessionId': session['id'],
          'expectedVersion': order.managementVersion,
          'addressVersion': order.addressVersion,
          if (changes != null) 'changes': changes,
        },
        order.rawJson);
  }

  Future<List<Order>> take(Map<String, dynamic> selection) async {
    final key = await owner();
    final context = await refresh();
    final session =
        jsonDecode((await storage.getWorkSessionData()) ?? '{}') as Map;
    final existing = (await outbox.operations(key))
        .where((row) =>
            (jsonDecode(row['payload'] as String) as Map)['kind'] == 'take')
        .toList();
    if (existing.isNotEmpty)
      throw StateError(
          'Hay una toma pendiente de confirmar. Sincroniza antes de continuar.');
    final id = const Uuid().v4();
    final request = <String, dynamic>{
      'operationId': id,
      'kind': 'take',
      'recordedAt': DateTime.now().toUtc().toIso8601String(),
      'selection': selection,
      'routeId': context['routeId'],
      'workSessionId': session['id'],
      'expectedLastTakeId': context['lastTakeId']
    };
    await outbox.enqueueOperation(key, request, {});
    await sync();
    if ((await outbox.operations(key)).any((row) => row['id'] == id)) {
      throw StateError(
          'Confirmando el resultado de la toma. No vuelvas a asignarte los pedidos.');
    }
    final current = await outbox.cached(key, 'route');
    return (current?['orders'] as List? ?? [])
        .map((value) => Order.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList();
  }

  Future<void> sync() =>
      _syncing ??= _synchronize().whenComplete(() => _syncing = null);

  Future<void> _synchronize() async {
    final auth = await storage.readSession();
    if (auth == null) return;
    final key = auth.ownerKey(client.dio.options.baseUrl);
    final blocked = <int?>{};
    for (final row in await outbox.operations(key)) {
      if ((await storage.readSession())?.id != auth.id) return;
      final payload = Map<String, dynamic>.from(
          jsonDecode(row['payload'] as String) as Map);
      final orderId = payload['orderId'] as int?;
      if (blocked.contains(orderId)) continue;
      if (row['state'] == 'conflict') {
        blocked.add(orderId);
        continue;
      }
      final id = row['id'] as String;
      if (!await outbox.claimOperation(
          key, id, DateTime.now().millisecondsSinceEpoch)) {
        blocked.add(orderId);
        continue;
      }
      try {
        final response = await client.post<Map<String, dynamic>>(
            '/deliverymen/me/operations',
            data: payload,
            fromJson: (value) => Map<String, dynamic>.from(value as Map),
            options: Options(extra: {'_sessionId': auth.id}));
        await outbox.cache(key, 'route',
            Map<String, dynamic>.from(response['context'] as Map));
        await outbox.finishOperation(key, id);
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (status == 400 ||
            status == 404 ||
            status == 409 ||
            status == 422) {
          await outbox.finishOperation(key, id,
              conflict: userFacingErrorMessage(error));
          blocked.add(orderId);
        } else {
          final now = DateTime.now();
          final delay = retryDelay((row['attempts'] as int? ?? 0) + 1,
              now: now,
              retryAfter: error.response?.headers.value('retry-after'));
          await outbox.finishOperation(key, id,
              retryAt: now.add(delay).millisecondsSinceEpoch);
          return;
        }
      } catch (_) {
        await outbox.finishOperation(key, id,
            retryAt: DateTime.now().millisecondsSinceEpoch + 15000);
        return;
      }
    }
  }
}
