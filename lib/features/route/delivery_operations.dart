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

/// Human-readable, explicit confirmation before accepting a new route.
String previousRouteConfirmationMessage(List<Order> orders) {
  final lines = orders.map((order) {
    final address = order.displayAddressLine ?? 'Dirección no registrada';
    final neighborhood = order.displayNeighborhoodLabel;
    return '#${order.id} · $address${neighborhood == null ? '' : ' · $neighborhood'}';
  }).join('\n');
  return 'Tienes ${orders.length} pedido(s) pendientes de la ruta anterior:\n\n'
      '$lines\n\n'
      'Al confirmar se marcarán como ENTREGADOS y se iniciará la nueva ruta '
      'en una sola operación. ¿Confirmas que realmente ya fueron entregados?';
}

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

  /// Always use the server snapshot; never infer a delivery from a cached route.
  Future<List<Order>> pendingBeforeNextRoute() async {
    await sync(); // First acknowledge any previously queued deliveries when possible.
    await _resolveObsoleteTakes(await owner());
    return _pendingFromContext(await refresh());
  }

  static List<Order> _pendingFromContext(Map<String, dynamic> context) {
    final currentRouteId = context['routeId'] as int?;
    if (currentRouteId == null) return const [];
    return (context['orders'] as List? ?? [])
        .map((value) => Order.fromJson(Map<String, dynamic>.from(value as Map)))
        .where((order) =>
            order.deliveryRouteId == currentRouteId &&
            order.status != OrderStatus.delivered &&
            order.status != OrderStatus.cancelled)
        .toList();
  }

  /// A take is online-only. An old intent must not block future work once
  /// the server proves it was applied, superseded or rejected. Never remove
  /// address or delivery changes here.
  Future<void> _resolveObsoleteTakes(String key,
      {bool conflictsOnly = false}) async {
    final takes = (await outbox.operations(key)).where((row) {
      if (conflictsOnly && row['state'] != 'conflict') return false;
      final payload = jsonDecode(row['payload'] as String) as Map;
      return payload['kind'] == 'take';
    }).toList();
    if (takes.isEmpty) return;

    final context = await refresh();
    if (await owner() != key) return;
    final rawSession = await storage.getWorkSessionData();
    final session = rawSession == null ? null : jsonDecode(rawSession) as Map;

    for (final row in takes) {
      if (await owner() != key) return;
      final payload = jsonDecode(row['payload'] as String) as Map;
      final id = row['id'] as String;

      // An ACK may have been lost even though the original take succeeded.
      if (context['lastTakeId'] == payload['operationId']) {
        await outbox.finishOperation(key, id);
        continue;
      }

      // The backend rejects a stale expectedLastTakeId or work session.
      if (payload.containsKey('expectedLastTakeId') &&
              context['lastTakeId'] != payload['expectedLastTakeId'] ||
          session?['id'] is num &&
              payload['workSessionId'] is num &&
              session!['id'] != payload['workSessionId']) {
        await outbox.finishOperation(key, id);
        continue;
      }

      final selection = payload['selection'];
      final ids = selection is Map ? selection['orderIds'] : null;
      if (ids is! List ||
          ids.isEmpty ||
          ids.length > 20 ||
          ids.any((value) => value is! int || value <= 0) ||
          ids.toSet().length != ids.length) {
        continue; // Unknown intent; do not guess what it selected.
      }

      var verified = true;
      var obsolete = false;
      for (final orderId in ids) {
        try {
          // Read current server data, not the available-orders cache.
          final current = await client.get<Map<String, dynamic>>(
              '/orders/$orderId',
              fromJson: (value) => Map<String, dynamic>.from(value as Map));
          if (current['id'] != orderId ||
              current['status'] is! String ||
              !current.containsKey('deliveryManId')) {
            verified = false;
            break;
          }
          if (OrderStatus.fromApi(current['status'] as String) !=
                  OrderStatus.ready ||
              current['deliveryManId'] != null) {
            obsolete = true; // A batch take cannot partially succeed.
            break;
          }
        } on DioException catch (error) {
          if (error.response?.statusCode == 404) {
            obsolete = true; // Order no longer exists in this scope.
          } else {
            verified = false;
          }
          break;
        } catch (_) {
          verified = false; // Connectivity/unknown response: retain intent.
          break;
        }
      }

      // 400/404/409/422 conflicts were rejected by the API. If its
      // authoritative state is readable, let the driver retry with fresh IDs.
      if (verified && (obsolete || row['state'] == 'conflict')) {
        await outbox.finishOperation(key, id);
      }
    }
  }

  Future<List<Order>> take(Map<String, dynamic> selection,
      {List<Order> confirmedPreviousDeliveries = const []}) async {
    final key = await owner();
    await _resolveObsoleteTakes(key);
    final context = await refresh();
    final pending = _pendingFromContext(context);
    final confirmed = {
      for (final order in confirmedPreviousDeliveries) order.id: order.managementVersion
    };
    if (confirmed.length != confirmedPreviousDeliveries.length ||
        confirmed.length != pending.length ||
        pending.any((order) =>
            order.status != OrderStatus.onTheWay ||
            order.managementVersion <= 0 ||
            confirmed[order.id] != order.managementVersion)) {
      throw StateError('La ruta anterior cambió. Revisa sus pedidos antes de confirmar la nueva.');
    }
    final session =
        jsonDecode((await storage.getWorkSessionData()) ?? '{}') as Map;
    final existing = (await outbox.operations(key))
        .where((row) =>
            (jsonDecode(row['payload'] as String) as Map)['kind'] == 'take')
        .toList();
    if (existing.isNotEmpty)
      throw StateError(
          'La asignación anterior aún no tiene respuesta confirmada. '
          'Verifica la conexión antes de volver a intentarlo.');
    final id = const Uuid().v4();
    final request = <String, dynamic>{
      'operationId': id,
      'kind': 'take',
      'recordedAt': DateTime.now().toUtc().toIso8601String(),
      'selection': selection,
      'routeId': context['routeId'],
      'workSessionId': session['id'],
      'expectedLastTakeId': context['lastTakeId'],
      if (confirmedPreviousDeliveries.isNotEmpty)
        'confirmedPreviousDeliveries': [
          for (final order in confirmedPreviousDeliveries)
            {'orderId': order.id, 'expectedVersion': order.managementVersion}
        ],
    };
    await outbox.enqueueOperation(key, request, {});
    await sync();
    final remaining = (await outbox.operations(key))
        .where((row) => row['id'] == id).toList();
    if (remaining.isNotEmpty) {
      throw StateError(remaining.single['state'] == 'conflict'
          ? 'La asignación fue rechazada. Actualiza los pedidos y vuelve a seleccionarlos.'
          : 'Confirmando el resultado de la toma. No vuelvas a asignarte los pedidos.');
    }
    final current = await outbox.cached(key, 'route');
    if (current?['lastTakeId'] != id) {
      throw StateError(
          'El servidor no confirmó esta asignación. Actualiza los pedidos antes de reintentar.');
    }
    return (current?['orders'] as List? ?? [])
        .map((value) => Order.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList();
  }

  Future<void> sync() =>
      _syncing ??= _synchronize().whenComplete(() => _syncing = null);

  /// Only acknowledge a 409 when the authoritative server state proves the
  /// original intent already happened. Uncertain or reassigned work stays in
  /// SQLite for explicit review.
  Future<bool> _alreadyConfirmed(Map<String, dynamic> payload,
      Map<String, Object?> row) async {
    try {
      if (payload['kind'] == 'take') {
        final context = await refresh();
        return context['lastTakeId'] == payload['operationId'];
      }
      if (payload['kind'] != 'deliver') return false;
      final id = payload['orderId'] as int?;
      if (id == null) return false;
      final original = jsonDecode(row['display'] as String) as Map;
      final current = await client.get<Map<String, dynamic>>(
        '/orders/$id/details',
        fromJson: (value) => Map<String, dynamic>.from(value as Map),
      );
      return current['status'].toString().toLowerCase() == 'delivered' &&
          current['deliveryManId'] == original['deliveryManId'] &&
          current['deliveryRouteId'] == payload['routeId'] &&
          current['deliveryRouteId'] == original['deliveryRouteId'];
    } catch (_) {
      return false;
    }
  }

  Future<void> _synchronize() async {
    final auth = await storage.readSession();
    if (auth == null) return;
    final key = auth.ownerKey(client.dio.options.baseUrl);
    // A server-rejected take is safe to reconcile independently of any
    // delivery/address outbox entries. Offline checks preserve the row.
    try {
      await _resolveObsoleteTakes(key, conflictsOnly: true);
    } catch (_) {}
    final blocked = <String>{};
    for (final row in await outbox.operations(key)) {
      if ((await storage.readSession())?.id != auth.id) return;
      final payload = Map<String, dynamic>.from(
          jsonDecode(row['payload'] as String) as Map);
      final orderId = payload['orderId'] as int?;
      final addressId = (jsonDecode(row['display'] as String) as Map)['addressId'];
      final resources = {'order:$orderId',
        if (payload['kind'] == 'address' && addressId != null) 'address:$addressId'};
      if (resources.any(blocked.contains)) continue;
      if (row['state'] == 'conflict') {
        blocked.addAll(resources);
        continue;
      }
      final id = row['id'] as String;
      if (!await outbox.claimOperation(
          key, id, DateTime.now().millisecondsSinceEpoch)) {
        blocked.addAll(resources);
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
        if (status == 409 && await _alreadyConfirmed(payload, row)) {
          await outbox.finishOperation(key, id);
          continue;
        }
        if (status == 400 ||
            status == 404 ||
            status == 409 ||
            status == 422) {
          await outbox.finishOperation(key, id,
              conflict: userFacingErrorMessage(error));
          blocked.addAll(resources);
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
