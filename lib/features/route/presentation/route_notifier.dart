import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';
import '../../auth/presentation/auth_notifier.dart';
import '../../tracking/location_tracking_service.dart';

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
  final OrderRepository _repository;
  final int _deliverymanId;

  RouteNotifier(this._repository, this._deliverymanId)
      : super(const RouteState());

  Future<void> load() async {
    if (!mounted) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final today = _todayString();
      final result = await _repository.getAssignedOrders(
        deliverymanId: _deliverymanId,
        fromDate: today,
        toDate: today,
        status: 'OnTheWay',
        type: 'Delivery',
        pageSize: 100,
      );
      if (!mounted) return;
      state = state.copyWith(orders: result.items, isLoading: false);
      await _syncTracking(result.items);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Starts or stops location tracking based on whether there are onTheWay orders.
  Future<void> _syncTracking(List<Order> orders) async {
    final hasActiveOrders = orders.isNotEmpty;
    if (hasActiveOrders) {
      await LocationTrackingService.setActiveDeliveryMode();
    } else {
      await LocationTrackingService.setLightMode();
    }
  }

  Future<void> markDelivered(int orderId) async {
    await _repository.updateOrderStatus(orderId, OrderStatus.delivered);
    await load(); // load() already calls _syncTracking
  }

  Future<void> markOnTheWay(int orderId) async {
    await _repository.updateOrderStatus(orderId, OrderStatus.onTheWay);
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
}

final routeNotifierProvider =
    StateNotifierProvider.autoDispose<RouteNotifier, RouteState>((ref) {
  final user = ref.watch(authNotifierProvider).user;
  return RouteNotifier(
    ref.watch(orderRepositoryProvider),
    user?.id ?? 0,
  );
});
