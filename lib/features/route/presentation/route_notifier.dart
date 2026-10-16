import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';
import '../../auth/presentation/auth_notifier.dart';
import '../../tracking/location_tracking_service.dart';
import '../../../core/errors/user_facing_error.dart';
import '../../../core/orders/route_order_helpers.dart';

enum RouteOrderChange { none, added, updated, removed }

typedef RouteOrdersLoader = Future<PagedOrders> Function();
typedef RouteTrackingSync = Future<void> Function(List<Order> orders);

class RouteState {
  final List<Order> orders;
  final bool isLoading;
  final String? error;

  const RouteState({
    this.orders = const [],
    this.isLoading = false,
    this.error,
  });

  RouteState copyWith({
    List<Order>? orders,
    bool? isLoading,
    String? error,
  }) =>
      RouteState(
        orders: orders ?? this.orders,
        isLoading: isLoading ?? this.isLoading,
        error: error,
      );
}

class RouteNotifier extends StateNotifier<RouteState> {
  final OrderRepository? _repository;
  final int _deliverymanId;
  final RouteOrdersLoader? _ordersLoader;
  final RouteTrackingSync? _trackingSync;
  final Future<bool> Function()? _canBeginDelivery;
  Future<void>? _loadInFlight;
  int _ordersRevision = 0;

  RouteNotifier(this._repository, this._deliverymanId,
      {Future<bool> Function()? canBeginDelivery})
      : _ordersLoader = null,
        _trackingSync = null,
        _canBeginDelivery = canBeginDelivery,
        super(const RouteState());

  RouteNotifier.withLoader({
    required int deliverymanId,
    required RouteOrdersLoader loadOrders,
    RouteTrackingSync? syncTracking,
    Future<bool> Function()? canBeginDelivery,
  })  : _repository = null,
        _deliverymanId = deliverymanId,
        _ordersLoader = loadOrders,
        _trackingSync = syncTracking,
        _canBeginDelivery = canBeginDelivery,
        super(const RouteState());

  bool containsOrder(int orderId) =>
      state.orders.any((order) => order.id == orderId);

  Future<void> load({bool silently = false}) {
    final current = _loadInFlight;
    if (current != null) return current;
    final operation = _load(silently: silently);
    _loadInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_loadInFlight, operation)) _loadInFlight = null;
    });
  }

  Future<void> _load({required bool silently}) async {
    if (!mounted) return;
    final readRevision = _ordersRevision;
    if (!silently) {
      state = state.copyWith(isLoading: true, error: null);
    }
    try {
      final result = await _fetchOrders();
      if (!mounted) return;
      if (readRevision != _ordersRevision) {
        if (state.isLoading) state = state.copyWith(isLoading: false);
        return; // A newer local/SignalR mutation wins over stale HTTP data.
      }
      final unchanged = routeOrdersHaveSameContent(state.orders, result.items);
      if (!unchanged || state.isLoading || state.error != null) {
        state = state.copyWith(
          orders: unchanged ? state.orders : result.items,
          isLoading: false,
          error: null,
        );
      }
      await _syncTracking(result.items);
    } catch (e) {
      if (!mounted) return;
      if (silently) return;
      state = state.copyWith(
        isLoading: false,
        error: userFacingErrorMessage(
          e,
          fallback: 'No pudimos cargar tu ruta.',
        ),
      );
    }
  }

  Future<RouteOrderChange> applyRealtimeOrder(Order order) async {
    final changes = await applyRealtimeOrders([order]);
    return changes.isEmpty ? RouteOrderChange.none : changes.single;
  }

  /// Apply a batch atomically: one state update and one GPS mode sync.
  Future<List<RouteOrderChange>> applyRealtimeOrders(Iterable<Order> incoming) async {
    if (!mounted) return const [];
    final next = [...state.orders];
    final changes = <RouteOrderChange>[];

    for (final order in incoming) {
      final index = next.indexWhere((item) => item.id == order.id);
      final belongsToMe = order.status == OrderStatus.onTheWay &&
          order.deliveryManId == _deliverymanId;
      if (!belongsToMe) {
        if (index >= 0) {
          next.removeAt(index);
          changes.add(RouteOrderChange.removed);
        }
      } else if (index < 0) {
        next.add(order);
        changes.add(RouteOrderChange.added);
      } else if (!routeOrderHasSameContent(next[index], order)) {
        next[index] = order;
        changes.add(RouteOrderChange.updated);
      }
    }

    if (changes.isEmpty) return changes;
    _ordersRevision++;
    state = state.copyWith(orders: next, isLoading: false, error: null);
    await _syncTracking(next);
    return changes;
  }

  /// Starts or stops location tracking based on whether there are onTheWay orders.
  Future<void> _syncTracking(List<Order> orders) async {
    final trackingSync = _trackingSync;
    if (trackingSync != null) {
      await trackingSync(orders);
      return;
    }
    final hasActiveOrders = orders.isNotEmpty;
    if (hasActiveOrders) {
      int? routeId;
      for (final order in orders) {
        if (order.deliveryRouteId != null) {
          routeId = order.deliveryRouteId;
          break;
        }
      }
      await LocationTrackingService.setActiveDeliveryMode(routeId: routeId);
    }
    // Sin pedidos OnTheWay la ruta puede seguir activa durante el regreso a
    // sucursal. El backend ordena volver a modo liviano al confirmar la llegada.
  }

  Future<void> markDelivered(int orderId) async {
    await _repository!.updateOrderStatus(orderId, OrderStatus.delivered);
    await load(); // load() already calls _syncTracking
  }

  Future<void> markOnTheWay(int orderId) async {
    if (_canBeginDelivery != null && !await _canBeginDelivery!()) {
      throw StateError(
        'No se puede iniciar el domicilio hasta confirmar el seguimiento de ubicación.',
      );
    }
    await _repository!.updateOrderStatus(orderId, OrderStatus.onTheWay);
    await load();
  }

  /// Actualización optimista tras editar dirección (misma firma que el front).
  void applyAddressPatch({
    required int orderId,
    String? addressDescription,
    String? addressAdditionalInfo,
    double? latitude,
    double? longitude,
    int? neighborhoodId,
    String? neighborhoodName,
  }) {
    if (!mounted) return;
    final next = state.orders.map((o) {
      if (o.id != orderId) return o;
      return o.copyWithAddressFields(
        addressDescription: addressDescription,
        addressAdditionalInfo: addressAdditionalInfo,
        latitude: latitude,
        longitude: longitude,
        neighborhoodId: neighborhoodId,
        neighborhoodName: neighborhoodName,
      );
    }).toList();
    state = state.copyWith(orders: next);
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<PagedOrders> _fetchOrders() {
    final ordersLoader = _ordersLoader;
    if (ordersLoader != null) return ordersLoader();
    final today = _todayString();
    return _repository!.getAssignedOrders(
      deliverymanId: _deliverymanId,
      fromDate: today,
      toDate: today,
      status: 'OnTheWay',
      type: 'Delivery',
      pageSize: 100,
    );
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
