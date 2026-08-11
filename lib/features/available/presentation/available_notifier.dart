import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';
import '../../auth/data/auth_models.dart';
import '../../auth/presentation/auth_notifier.dart';
import '../data/branch_presence_verifier.dart';
import '../../routing/delivery_routing_models.dart';
import '../../routing/delivery_routing_repository.dart';
import '../../../core/errors/user_facing_error.dart';

class AvailableState {
  final List<Order> orders;
  final List<Order> preparationOrders;
  final bool isLoading;
  final bool isLoadingPrep;
  final String? error;
  final String? errorPrep;
  final BranchPresenceResult branchPresence;
  final DeliveryRoutingPlan? routingPlan;
  final bool isLoadingRouting;
  final String? errorRouting;

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
    this.routingPlan,
    this.isLoadingRouting = false,
    this.errorRouting,
  });

  AvailableState copyWith({
    List<Order>? orders,
    List<Order>? preparationOrders,
    bool? isLoading,
    bool? isLoadingPrep,
    String? error,
    String? errorPrep,
    BranchPresenceResult? branchPresence,
    DeliveryRoutingPlan? routingPlan,
    bool? isLoadingRouting,
    String? errorRouting,
    bool clearErrorRouting = false,
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
        routingPlan: routingPlan ?? this.routingPlan,
        isLoadingRouting: isLoadingRouting ?? this.isLoadingRouting,
        errorRouting:
            clearErrorRouting ? null : (errorRouting ?? this.errorRouting),
      );
}

class AvailableNotifier extends StateNotifier<AvailableState> {
  final OrderRepository _repository;
  final BranchPresenceVerifier _branchPresenceVerifier;
  final DeliveryRoutingRepository _routingRepository;
  final AuthUser? _user;
  final double? _branchLatitude;
  final double? _branchLongitude;
  final int _allowedDistanceMeters;

  AvailableNotifier(
    this._repository,
    this._branchPresenceVerifier,
    this._routingRepository,
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
      state = state.copyWith(
        isLoading: false,
        error: userFacingErrorMessage(
          e,
          fallback: 'No pudimos cargar los pedidos disponibles.',
        ),
      );
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
      state = state.copyWith(
        isLoadingPrep: false,
        errorPrep: userFacingErrorMessage(
          e,
          fallback: 'No pudimos cargar los pedidos en preparación.',
        ),
      );
    }
  }

  Future<void> loadAll({int? branchId}) async {
    await Future.wait([
      load(branchId: branchId),
      loadPreparation(),
      loadRouting(),
    ]);
  }

  Future<void> loadRouting() async {
    if (!mounted) return;
    state = state.copyWith(isLoadingRouting: true, clearErrorRouting: true);
    try {
      final plan = await _routingRepository.getPlan();
      if (!mounted) return;
      state = state.copyWith(routingPlan: plan, isLoadingRouting: false);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoadingRouting: false,
        errorRouting: userFacingErrorMessage(
          e,
          fallback: 'No pudimos preparar la ruta sugerida.',
        ),
      );
    }
  }

  Future<bool> selfAssign({
    required List<int> orderIds,
    required String password,
    int? proposalId,
    int? expectedPlanVersion,
  }) async {
    await _repository.selfAssignOrders(
      orderIds: orderIds,
      password: password,
      proposalId: proposalId,
      expectedPlanVersion: expectedPlanVersion,
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
    ref.watch(deliveryRoutingRepositoryProvider),
    auth.user,
    auth.workSession?.branchLatitude ?? auth.user?.branchLatitude,
    auth.workSession?.branchLongitude ?? auth.user?.branchLongitude,
    auth.workSession?.tracking.allowedDistanceMeters ?? 50,
  );
});
