import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';
import '../../auth/presentation/auth_notifier.dart';

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
  }) => RouteState(
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
    state = state.copyWith(isLoading: true, error: null);
    try {
      final today = _todayString();
      final result = await _repository.getAssignedOrders(
        deliverymanId: _deliverymanId,
        fromDate: today,
        toDate: today,
        status: 'OnTheWay',
        pageSize: 100,
      );
      state = state.copyWith(orders: result.items, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> markDelivered(int orderId) async {
    await _repository.updateOrderStatus(orderId, OrderStatus.delivered);
    await load();
  }

  Future<void> markOnTheWay(int orderId) async {
    await _repository.updateOrderStatus(orderId, OrderStatus.onTheWay);
    await load();
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
