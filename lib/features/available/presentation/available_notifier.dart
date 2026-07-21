import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';
import '../../auth/data/auth_models.dart';
import '../../auth/presentation/auth_notifier.dart';
import '../data/branch_presence_verifier.dart';

class AvailableState {
  final List<Order> orders;
  final List<Order> preparationOrders;
  final bool isLoading;
  final bool isLoadingPrep;
  final String? error;
  final String? errorPrep;
  final BranchPresenceResult branchPresence;

  const AvailableState({
    this.orders = const [],
    this.preparationOrders = const [],
    this.isLoading = false,
    this.isLoadingPrep = false,
    this.error,
    this.errorPrep,
    this.branchPresence = const BranchPresenceResult(
      status: BranchPresenceStatus.initial,
    ),
  });

  AvailableState copyWith({
    List<Order>? orders,
    List<Order>? preparationOrders,
    bool? isLoading,
    bool? isLoadingPrep,
    String? error,
    String? errorPrep,
    BranchPresenceResult? branchPresence,
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
        branchPresence: branchPresence ?? this.branchPresence,
      );
}

class AvailableNotifier extends StateNotifier<AvailableState> {
  final OrderRepository _repository;
  final BranchPresenceVerifier _branchPresenceVerifier;
  final AuthUser? _user;
  final double? _branchLatitude;
  final double? _branchLongitude;
  final int _allowedDistanceMeters;

  AvailableNotifier(
    this._repository,
    this._branchPresenceVerifier,
    this._user,
    this._branchLatitude,
    this._branchLongitude,
    this._allowedDistanceMeters,
  ) : super(const AvailableState());

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

  Future<void> loadPreparation() async {
    if (!mounted) return;
    state = state.copyWith(
      preparationOrders: const [],
      isLoadingPrep: true,
      clearErrorPrep: true,
      branchPresence: const BranchPresenceResult(
        status: BranchPresenceStatus.checking,
      ),
    );
    try {
      final user = _user;
      if (user == null) {
        if (!mounted) return;
        state = state.copyWith(
          isLoadingPrep: false,
          branchPresence: const BranchPresenceResult(
            status: BranchPresenceStatus.locationUnavailable,
          ),
        );
        return;
      }

      final presence = await _branchPresenceVerifier.verify(
        branchLatitude: _branchLatitude,
        branchLongitude: _branchLongitude,
        allowedDistanceMeters: _allowedDistanceMeters,
      );
      if (!mounted) return;
      if (!presence.isInside) {
        state = state.copyWith(
          preparationOrders: const [],
          isLoadingPrep: false,
          branchPresence: presence,
        );
        return;
      }

      final orders = await _repository.getPreparationAndTakenOrders(
        latitude: presence.latitude!,
        longitude: presence.longitude!,
      );
      if (!mounted) return;
      state = state.copyWith(
        preparationOrders: orders,
        isLoadingPrep: false,
        branchPresence: presence,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoadingPrep: false, errorPrep: e.toString());
    }
  }

  Future<void> loadAll({int? branchId}) async {
    await Future.wait([
      load(branchId: branchId),
      loadPreparation(),
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
  final auth = ref.watch(authNotifierProvider);
  return AvailableNotifier(
    ref.watch(orderRepositoryProvider),
    ref.watch(branchPresenceVerifierProvider),
    auth.user,
    auth.workSession?.branchLatitude ?? auth.user?.branchLatitude,
    auth.workSession?.branchLongitude ?? auth.user?.branchLongitude,
    auth.workSession?.tracking.allowedDistanceMeters ?? 50,
  );
});
