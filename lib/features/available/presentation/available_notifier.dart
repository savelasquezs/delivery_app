import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';
import '../../auth/data/auth_models.dart';
import '../../auth/presentation/auth_notifier.dart';
import '../data/branch_presence_verifier.dart';
import '../../routing/delivery_routing_models.dart';
import '../../routing/delivery_routing_repository.dart';
import '../../../core/errors/user_facing_error.dart';
import '../../../core/orders/route_order_helpers.dart';

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
  final Future<bool> Function()? _canBeginDelivery;
  final double? _branchLatitude;
  final double? _branchLongitude;
  final int _allowedDistanceMeters;
  Future<void>? _availableLoadInFlight;
  Future<void>? _preparationLoadInFlight;
  Future<void>? _routingLoadInFlight;

  AvailableNotifier(
    this._repository,
    this._branchPresenceVerifier,
    this._routingRepository,
    this._user,
    this._branchLatitude,
    this._branchLongitude,
    this._allowedDistanceMeters, {
    Future<bool> Function()? canBeginDelivery,
  })  : _canBeginDelivery = canBeginDelivery,
        super(const AvailableState());

  Future<void> load({int? branchId, bool silently = false}) {
    final current = _availableLoadInFlight;
    if (current != null) return current;
    final operation = _load(branchId: branchId, silently: silently);
    _availableLoadInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_availableLoadInFlight, operation)) {
        _availableLoadInFlight = null;
      }
    });
  }

  Future<void> _load({int? branchId, required bool silently}) async {
    if (!mounted) return;
    if (!silently) {
      state = state.copyWith(isLoading: true, clearError: true);
    }
    try {
      final orders = await _repository.getAvailableOrders(branchId: branchId);
      if (!mounted) return;
      final unchanged = routeOrdersHaveSameContent(state.orders, orders);
      if (!unchanged || state.isLoading || state.error != null) {
        state = state.copyWith(
          orders: unchanged ? state.orders : orders,
          isLoading: false,
          clearError: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (silently) return;
      state = state.copyWith(
        isLoading: false,
        error: userFacingErrorMessage(
          e,
          fallback: 'No pudimos cargar los pedidos disponibles.',
        ),
      );
    }
  }

  Future<void> loadPreparation({bool silently = false}) {
    final current = _preparationLoadInFlight;
    if (current != null) return current;
    final operation = _loadPreparation(silently: silently);
    _preparationLoadInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_preparationLoadInFlight, operation)) {
        _preparationLoadInFlight = null;
      }
    });
  }

  Future<void> _loadPreparation({required bool silently}) async {
    if (!mounted) return;
    if (!silently) {
      state = state.copyWith(
        preparationOrders: const [],
        isLoadingPrep: true,
        clearErrorPrep: true,
        branchPresence: const BranchPresenceResult(
          status: BranchPresenceStatus.checking,
        ),
      );
    }
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
      final unchanged = routeOrdersHaveSameContent(
        state.preparationOrders,
        orders,
      );
      if (!unchanged ||
          state.isLoadingPrep ||
          state.errorPrep != null ||
          state.branchPresence != presence) {
        state = state.copyWith(
          preparationOrders: unchanged ? state.preparationOrders : orders,
          isLoadingPrep: false,
          branchPresence: presence,
          clearErrorPrep: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (silently) return;
      state = state.copyWith(
        isLoadingPrep: false,
        errorPrep: userFacingErrorMessage(
          e,
          fallback: 'No pudimos cargar los pedidos en preparación.',
        ),
      );
    }
  }

  Future<void> loadAll({int? branchId, bool silently = false}) async {
    await Future.wait([
      load(branchId: branchId, silently: silently),
      loadPreparation(silently: silently),
      loadRouting(silently: silently),
    ]);
  }

  Future<void> loadRouting({bool silently = false}) {
    final current = _routingLoadInFlight;
    if (current != null) return current;
    final operation = _loadRouting(silently: silently);
    _routingLoadInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_routingLoadInFlight, operation)) {
        _routingLoadInFlight = null;
      }
    });
  }

  Future<void> _loadRouting({required bool silently}) async {
    if (!mounted) return;
    if (!silently) {
      state = state.copyWith(
        isLoadingRouting: true,
        clearErrorRouting: true,
      );
    }
    try {
      final plan = await _routingRepository.getPlan();
      if (!mounted) return;
      state = state.copyWith(
        routingPlan: plan,
        isLoadingRouting: false,
        clearErrorRouting: true,
      );
    } catch (e) {
      if (!mounted) return;
      if (silently) return;
      state = state.copyWith(
        isLoadingRouting: false,
        errorRouting: userFacingErrorMessage(
          e,
          fallback: 'No pudimos preparar la ruta sugerida.',
        ),
      );
    }
  }

  void removeOrder(int orderId) {
    if (!mounted) return;
    final orders = state.orders.where((order) => order.id != orderId).toList();
    final preparationOrders =
        state.preparationOrders.where((order) => order.id != orderId).toList();
    if (orders.length == state.orders.length &&
        preparationOrders.length == state.preparationOrders.length) {
      return;
    }
    state = state.copyWith(
      orders: orders,
      preparationOrders: preparationOrders,
    );
  }

  Future<bool> selfAssign({
    required List<int> orderIds,
    required String password,
    int? proposalId,
    int? expectedPlanVersion,
  }) async {
    if (_canBeginDelivery != null && !await _canBeginDelivery!()) {
      throw StateError(
          'No puedes tomar pedidos hasta que el seguimiento de ubicación esté activo.');
    }
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
  final hasUser = ref.watch(
    authNotifierProvider.select((auth) => auth.user != null),
  );
  final branchLatitude = ref.watch(
    authNotifierProvider.select(
      (auth) => auth.workSession?.branchLatitude ?? auth.user?.branchLatitude,
    ),
  );
  final branchLongitude = ref.watch(
    authNotifierProvider.select(
      (auth) => auth.workSession?.branchLongitude ?? auth.user?.branchLongitude,
    ),
  );
  final allowedDistanceMeters = ref.watch(
    authNotifierProvider.select(
      (auth) => auth.workSession?.tracking.allowedDistanceMeters ?? 50,
    ),
  );
  return AvailableNotifier(
    ref.watch(orderRepositoryProvider),
    ref.watch(branchPresenceVerifierProvider),
    ref.watch(deliveryRoutingRepositoryProvider),
    hasUser ? ref.read(authNotifierProvider).user : null,
    branchLatitude,
    branchLongitude,
    allowedDistanceMeters,
    canBeginDelivery: () =>
        ref.read(authNotifierProvider.notifier).canBeginDelivery(),
  );
});
