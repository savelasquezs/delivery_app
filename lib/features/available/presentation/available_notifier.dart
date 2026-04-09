import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';

class AvailableState {
  final List<Order> orders;
  final List<Order> preparationOrders;
  final bool isLoading;
  final bool isLoadingPrep;
  final String? error;
  final String? errorPrep;

  const AvailableState({
    this.orders = const [],
    this.preparationOrders = const [],
    this.isLoading = false,
    this.isLoadingPrep = false,
    this.error,
    this.errorPrep,
  });

  AvailableState copyWith({
    List<Order>? orders,
    List<Order>? preparationOrders,
    bool? isLoading,
    bool? isLoadingPrep,
    String? error,
    String? errorPrep,
    bool clearError = false,
    bool clearErrorPrep = false,
  }) =>
      AvailableState(
        orders: orders ?? this.orders,
        preparationOrders: preparationOrders ?? this.preparationOrders,
        isLoading: isLoading ?? this.isLoading,
        isLoadingPrep: isLoadingPrep ?? this.isLoadingPrep,
        error: clearError ? null : (error ?? this.error),
        errorPrep: clearErrorPrep ? null : (errorPrep ?? this.errorPrep),
      );
}

class AvailableNotifier extends StateNotifier<AvailableState> {
  final OrderRepository _repository;

  AvailableNotifier(this._repository) : super(const AvailableState());

  Future<void> load({int? branchId}) async {
    if (!mounted) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final orders = await _repository.getAvailableOrders(branchId: branchId);
      if (!mounted) return;
      state = state.copyWith(orders: orders, isLoading: false);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> loadPreparation({int? branchId}) async {
    if (!mounted) return;
    state = state.copyWith(isLoadingPrep: true, clearErrorPrep: true);
    try {
      final orders =
          await _repository.getPreparationOrders(branchId: branchId);
      if (!mounted) return;
      state = state.copyWith(preparationOrders: orders, isLoadingPrep: false);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoadingPrep: false, errorPrep: e.toString());
    }
  }

  Future<void> loadAll({int? branchId}) async {
    await Future.wait([
      load(branchId: branchId),
      loadPreparation(branchId: branchId),
    ]);
  }

  Future<bool> selfAssign({
    required List<int> orderIds,
    required String password,
  }) async {
    await _repository.selfAssignOrders(
      orderIds: orderIds,
      password: password,
    );
    if (!mounted) return false;
    return true;
  }
}

final availableNotifierProvider =
    StateNotifierProvider.autoDispose<AvailableNotifier, AvailableState>((ref) {
  return AvailableNotifier(ref.watch(orderRepositoryProvider));
});
