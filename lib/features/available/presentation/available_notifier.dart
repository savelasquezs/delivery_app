import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';

class AvailableState {
  final List<Order> orders;
  final bool isLoading;
  final String? error;

  const AvailableState({
    this.orders = const [],
    this.isLoading = false,
    this.error,
  });

  AvailableState copyWith({
    List<Order>? orders,
    bool? isLoading,
    String? error,
  }) => AvailableState(
        orders: orders ?? this.orders,
        isLoading: isLoading ?? this.isLoading,
        error: error,
      );
}

class AvailableNotifier extends StateNotifier<AvailableState> {
  final OrderRepository _repository;

  AvailableNotifier(this._repository) : super(const AvailableState());

  Future<void> load({int? branchId}) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final orders = await _repository.getAvailableOrders(branchId: branchId);
      state = state.copyWith(orders: orders, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<bool> selfAssign({
    required List<int> orderIds,
    required String password,
  }) async {
    await _repository.selfAssignOrders(
      orderIds: orderIds,
      password: password,
    );
    return true;
  }
}

final availableNotifierProvider =
    StateNotifierProvider.autoDispose<AvailableNotifier, AvailableState>((ref) {
  return AvailableNotifier(ref.watch(orderRepositoryProvider));
});
