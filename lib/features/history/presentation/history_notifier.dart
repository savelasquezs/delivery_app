import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';
import '../../auth/presentation/auth_notifier.dart';
import '../../../core/errors/user_facing_error.dart';

class HistoryState {
  final List<Order> orders;
  final List<BranchSummary> branchSummaries;
  final int totalCount;
  final int currentPage;
  final bool isLoading;
  final bool isLoadingMore;
  final String? error;
  final String fromDate;
  final String toDate;

  const HistoryState({
    this.orders = const [],
    this.branchSummaries = const [],
    this.totalCount = 0,
    this.currentPage = 1,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.error,
    required this.fromDate,
    required this.toDate,
  });

  bool get hasMore => orders.length < totalCount;

  HistoryState copyWith({
    List<Order>? orders,
    List<BranchSummary>? branchSummaries,
    int? totalCount,
    int? currentPage,
    bool? isLoading,
    bool? isLoadingMore,
    String? error,
    String? fromDate,
    String? toDate,
  }) =>
      HistoryState(
        orders: orders ?? this.orders,
        branchSummaries: branchSummaries ?? this.branchSummaries,
        totalCount: totalCount ?? this.totalCount,
        currentPage: currentPage ?? this.currentPage,
        isLoading: isLoading ?? this.isLoading,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        error: error,
        fromDate: fromDate ?? this.fromDate,
        toDate: toDate ?? this.toDate,
      );
}

class HistoryNotifier extends StateNotifier<HistoryState> {
  final OrderRepository _repository;
  final int _deliverymanId;

  HistoryNotifier(this._repository, this._deliverymanId)
      : super(HistoryState(
          fromDate: _todayString(),
          toDate: _todayString(),
        ));

  static String _todayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> load({String? fromDate, String? toDate}) async {
    if (!mounted) return;
    final from = fromDate ?? state.fromDate;
    final to = toDate ?? state.toDate;

    state = state.copyWith(
      isLoading: true,
      error: null,
      currentPage: 1,
      fromDate: from,
      toDate: to,
    );

    try {
      final result = await _repository.getAssignedOrders(
        deliverymanId: _deliverymanId,
        fromDate: from,
        toDate: to,
        status: 'Delivered',
        includeOnsiteActiveInHistory: true,
        pageSize: 20,
      );

      final summaries = await _repository.getAssignedBranchSummary(
        deliverymanId: _deliverymanId,
        fromDate: from,
        toDate: to,
        status: 'Delivered',
        includeOnsiteActiveInHistory: true,
      );

      if (!mounted) return;
      state = state.copyWith(
        orders: result.items,
        branchSummaries: summaries,
        totalCount: result.totalCount,
        isLoading: false,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        error: userFacingErrorMessage(
          e,
          fallback: 'No pudimos cargar tu historial.',
        ),
      );
    }
  }

  Future<void> loadMore() async {
    if (!mounted) return;
    if (!state.hasMore || state.isLoadingMore) return;
    final nextPage = state.currentPage + 1;
    state = state.copyWith(isLoadingMore: true);
    try {
      final result = await _repository.getAssignedOrders(
        deliverymanId: _deliverymanId,
        fromDate: state.fromDate,
        toDate: state.toDate,
        status: 'Delivered',
        includeOnsiteActiveInHistory: true,
        page: nextPage,
        pageSize: 20,
      );
      if (!mounted) return;
      state = state.copyWith(
        orders: [...state.orders, ...result.items],
        currentPage: nextPage,
        isLoadingMore: false,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoadingMore: false,
        error: userFacingErrorMessage(
          e,
          fallback: 'No pudimos cargar más pedidos.',
        ),
      );
    }
  }

  void changeDateRange(String fromDate, String toDate) {
    load(fromDate: fromDate, toDate: toDate);
  }
}

final historyNotifierProvider =
    StateNotifierProvider.autoDispose<HistoryNotifier, HistoryState>((ref) {
  final deliverymanId = ref.watch(
    authNotifierProvider.select((auth) => auth.user?.id ?? 0),
  );
  return HistoryNotifier(
    ref.watch(orderRepositoryProvider),
    deliverymanId,
  );
});
