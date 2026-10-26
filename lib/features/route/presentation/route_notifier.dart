import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';
import '../../auth/presentation/auth_notifier.dart';
import '../../tracking/location_tracking_service.dart';
import '../../../core/errors/user_facing_error.dart';
import '../../../core/orders/route_order_helpers.dart';

enum RouteOrderChange { none, added, updated, removed }

typedef RouteTrackingSync = Future<void> Function(
    int revision, int? routeId, String owner);

class RouteState {
  final Map<String, dynamic>? lastClosure;
  final int revision;
  final int? routeId;
  final String phase;
  final List<Map<String, Object?>> pending;
  final List<Order> orders;
  final bool isLoading;
  final String? error;

  const RouteState({
    this.lastClosure,
    this.revision = -1,
    this.routeId,
    this.phase = 'idle',
    this.pending = const [],
    this.orders = const [],
    this.isLoading = false,
    this.error,
  });

  RouteState copyWith({
    int? revision,
    int? routeId,
    String? phase,
    List<Map<String, Object?>>? pending,
    List<Order>? orders,
    bool? isLoading,
    String? error,
  }) =>
      RouteState(
        lastClosure: lastClosure,
        revision: revision ?? this.revision,
        routeId: routeId ?? this.routeId,
        phase: phase ?? this.phase,
        pending: pending ?? this.pending,
        orders: orders ?? this.orders,
        isLoading: isLoading ?? this.isLoading,
        error: error,
      );
}

class RouteNotifier extends StateNotifier<RouteState> {
  final OrderRepository _repository;
  final int _deliverymanId;
  final RouteTrackingSync? _trackingSync;
  final Future<bool> Function()? _canBeginDelivery;
  Future<void>? _loadInFlight;
  Timer? _syncTimer;
  int _contextRevision = -1;
  bool _reloadAfterInFlight = false;

  RouteNotifier(this._repository, this._deliverymanId,
      {Future<bool> Function()? canBeginDelivery,
      RouteTrackingSync? syncTracking})
      : _trackingSync = syncTracking,
        _canBeginDelivery = canBeginDelivery,
        super(const RouteState()) {
    _syncTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => unawaited(_syncPending()));
  }

  Future<void> load({bool silently = false, bool ensureFresh = false}) {
    final current = _loadInFlight;
    if (current != null) {
      if (ensureFresh) _reloadAfterInFlight = true;
      return current;
    }
    final operation = _loadUntilFresh(silently: silently);
    _loadInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_loadInFlight, operation)) _loadInFlight = null;
    });
  }

  Future<void> _loadUntilFresh({required bool silently}) async {
    do {
      _reloadAfterInFlight = false;
      await _load(silently: silently);
      silently = true;
    } while (_reloadAfterInFlight && mounted);
  }

  Future<void> _load({required bool silently}) async {
    if (!mounted) return;
    final operations = _repository.operations;
    if (!silently && state.revision < 0)
      state = state.copyWith(isLoading: true);
    try {
      final cached = await operations.cachedContext();
      if (cached != null) await _applyContext(cached);
      await operations.sync();
      await _applyContext(await operations.refresh());
    } catch (error) {
      if (mounted)
        state = state.copyWith(
            isLoading: false,
            error: userFacingErrorMessage(error,
                fallback: 'Sin conexión. Mostrando la última ruta conocida.'));
    }
  }

  Future<void> _syncPending() async {
    try {
      if ((await _repository.operations.pending()).isEmpty) return;
      await _repository.operations.sync();
      final cached = await _repository.operations.cachedContext();
      if (cached != null) await _applyContext(cached);
    } catch (_) {}
  }

  Future<void> _applyContext(Map<String, dynamic> context) async {
    if (!mounted) return;
    final owner = await _repository.operations.owner();
    final revision = (context['revision'] as num?)?.toInt() ?? 0;
    if (revision < _contextRevision) return;
    final pending = await _repository.operations.pending();
    if (!mounted || revision < _contextRevision) return;
    _contextRevision = revision;
    final delivered = <int>{};
    final corrections = <int, Map>{};
    for (final row in pending) {
      final value = jsonDecode(row['payload'] as String) as Map;
      if (value['kind'] == 'deliver') delivered.add(value['orderId'] as int);
      if (value['kind'] == 'address')
        corrections[value['orderId'] as int] = value['changes'] as Map;
    }
    final orders = (context['orders'] as List? ?? [])
        .map((raw) {
          final json = Map<String, dynamic>.from(raw as Map);
          final changes = corrections[json['id']];
          if (changes != null) {
            for (final key in changes.keys)
              json[key == 'address'
                  ? 'addressDescription'
                  : key == 'additionalInfo'
                      ? 'addressAdditionalInfo'
                      : key as String] = changes[key];
            if (changes.containsKey('neighborhoodId')) {
              final matches = (context['neighborhoods'] as List? ?? []).where((n) => n['id'] == changes['neighborhoodId']);
              json['neighborhoodName'] = matches.isEmpty ? null : matches.first['name'];
            }
          }
          return Order.fromJson(json);
        })
        .where((order) =>
            order.deliveryManId == _deliverymanId &&
            order.status == OrderStatus.onTheWay &&
            !delivered.contains(order.id))
        .toList();
    state = RouteState(
        lastClosure: context['lastClosure'] == null
            ? null
            : Map<String, dynamic>.from(context['lastClosure'] as Map),
        revision: revision,
        orders: orders,
        routeId: context['routeId'] as int?,
        phase: context['phase'] as String? ?? 'idle',
        pending: pending);
    if (_trackingSync != null) {
      await _trackingSync!(revision, state.routeId, owner);
    } else {
      unawaited(LocationTrackingService.applyRouteContext(revision, state.routeId,
          baseUrl: _repository.operations.client.dio.options.baseUrl,
          expectedOwner: owner).catchError((Object error) {
            debugPrint('Route tracking update deferred: ${error.runtimeType}');
          }));
    }
  }

  Future<void> correctAddress(Order order, Map<String, dynamic> changes) async {
    await _repository.operations.record(order, 'address', changes: changes);
    final cached = await _repository.operations.cachedContext();
    if (cached != null) await _applyContext(cached);
    unawaited(load(silently: true));
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }

  Future<RouteOrderChange> applyRealtimeOrder(Order order) async {
    final changes = await applyRealtimeOrders([order]);
    return changes.isEmpty ? RouteOrderChange.none : changes.single;
  }

  Future<List<RouteOrderChange>> applyRealtimeOrders(
      Iterable<Order> incoming) async {
    if (!mounted) return const [];
    final before = {for (final order in state.orders) order.id: order};
    await load(silently: true, ensureFresh: true);
    if (!mounted) return const [];
    final after = {for (final order in state.orders) order.id: order};
    return incoming.map((event) {
      final old = before[event.id], current = after[event.id];
      if (old == null && current != null) return RouteOrderChange.added;
      if (old != null && current == null) return RouteOrderChange.removed;
      if (old != null &&
          current != null &&
          !routeOrdersHaveSameContent([old], [current]))
        return RouteOrderChange.updated;
      return RouteOrderChange.none;
    }).toList();
  }

  Future<void> markDelivered(Order order) async {
    await _repository.operations.record(order, 'deliver');
    final context = await _repository.operations.cachedContext();
    if (context != null) await _applyContext(context);
    unawaited(load(silently: true));
  }

  Future<void> markOnTheWay(int orderId) async {
    if (_canBeginDelivery != null && !await _canBeginDelivery!()) {
      throw StateError(
        'No se puede iniciar el domicilio hasta confirmar el seguimiento de ubicación.',
      );
    }
    await _repository.updateOrderStatus(orderId, OrderStatus.onTheWay);
    await load();
  }


}

final routeNotifierProvider =
    StateNotifierProvider.autoDispose<RouteNotifier, RouteState>((ref) {
  final deliverymanId = ref.watch(
    authNotifierProvider.select((auth) => auth.user?.id ?? 0),
  );
  return RouteNotifier(
    ref.watch(orderRepositoryProvider),
    deliverymanId,
    canBeginDelivery: () =>
        ref.read(authNotifierProvider.notifier).canBeginDelivery(),
  );
});
