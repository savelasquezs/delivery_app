import 'dart:async';
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

  const AvailableState({this.orders = const [], this.preparationOrders = const [],
    this.isLoading = false, this.isLoadingPrep = false, this.error, this.errorPrep,
    this.branchPresence = const BranchPresenceResult(status: BranchPresenceStatus.initial),
    this.routingPlan, this.isLoadingRouting = false, this.errorRouting});

  AvailableState copyWith({List<Order>? orders, List<Order>? preparationOrders,
    bool? isLoading, bool? isLoadingPrep, String? error, String? errorPrep,
    BranchPresenceResult? branchPresence, DeliveryRoutingPlan? routingPlan,
    bool? isLoadingRouting, String? errorRouting, bool clearErrorRouting = false,
    bool clearError = false, bool clearErrorPrep = false}) => AvailableState(
      orders: orders ?? this.orders, preparationOrders: preparationOrders ?? this.preparationOrders,
      isLoading: isLoading ?? this.isLoading, isLoadingPrep: isLoadingPrep ?? this.isLoadingPrep,
      error: clearError ? null : (error ?? this.error), errorPrep: clearErrorPrep ? null : (errorPrep ?? this.errorPrep),
      branchPresence: branchPresence ?? this.branchPresence, routingPlan: routingPlan ?? this.routingPlan,
      isLoadingRouting: isLoadingRouting ?? this.isLoadingRouting,
      errorRouting: clearErrorRouting ? null : (errorRouting ?? this.errorRouting));
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
  int _ordersRevision = 0;
  int _routingRevision = 0;
  bool _reloadAvailableAfterInFlight = false;
  bool _reloadRoutingAfterInFlight = false;
  Timer? _planExpiry;

  AvailableNotifier(this._repository, this._branchPresenceVerifier, this._routingRepository,
    this._user, this._branchLatitude, this._branchLongitude, this._allowedDistanceMeters,
    {Future<bool> Function()? canBeginDelivery})
      : _canBeginDelivery = canBeginDelivery, super(const AvailableState());

  @override
  void dispose() { _planExpiry?.cancel(); super.dispose(); }

  Future<void> load({int? branchId, bool silently = false, bool ensureFresh = false}) {
    final current = _availableLoadInFlight;
    if (current != null) {
      if (ensureFresh) _reloadAvailableAfterInFlight = true;
      return current;
    }
    final operation = _loadUntilFresh(branchId: branchId, silently: silently);
    _availableLoadInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_availableLoadInFlight, operation)) _availableLoadInFlight = null;
    });
  }

  Future<void> _loadUntilFresh({int? branchId, required bool silently}) async {
    do {
      _reloadAvailableAfterInFlight = false;
      await _load(branchId: branchId, silently: silently);
      silently = true;
    } while (_reloadAvailableAfterInFlight && mounted);
  }

  Future<void> _load({int? branchId, required bool silently}) async {
    final revision = _ordersRevision;
    if (!mounted) return;
    if (!silently) state = state.copyWith(isLoading: true, clearError: true);
    try {
      final orders = await _repository.getAvailableOrders(branchId: branchId);
      if (!mounted) return;
      if (revision != _ordersRevision || _reloadAvailableAfterInFlight) {
        _reloadAvailableAfterInFlight = true;
        if (state.isLoading) state = state.copyWith(isLoading: false);
        return;
      }
      final unchanged = routeOrdersHaveSameContent(state.orders, orders);
      if (!unchanged || state.isLoading || state.error != null) {
        state = state.copyWith(orders: unchanged ? state.orders : orders, isLoading: false, clearError: true);
      }
    } catch (error) {
      if (!mounted || silently) return;
      state = state.copyWith(isLoading: false,
        error: userFacingErrorMessage(error, fallback: 'No pudimos cargar los pedidos disponibles.'));
    }
  }

  Future<void> loadPreparation({bool silently = false}) {
    final current = _preparationLoadInFlight;
    if (current != null) return current;
    final operation = _loadPreparation(silently: silently);
    _preparationLoadInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_preparationLoadInFlight, operation)) _preparationLoadInFlight = null;
    });
  }

  Future<void> _loadPreparation({required bool silently}) async {
    if (!mounted) return;
    if (!silently) {
      state = state.copyWith(preparationOrders: const [], isLoadingPrep: true, clearErrorPrep: true,
        branchPresence: const BranchPresenceResult(status: BranchPresenceStatus.checking));
    }
    try {
      if (_user == null) {
        state = state.copyWith(isLoadingPrep: false,
          branchPresence: const BranchPresenceResult(status: BranchPresenceStatus.locationUnavailable));
        return;
      }
      final presence = await _branchPresenceVerifier.verify(branchLatitude: _branchLatitude,
        branchLongitude: _branchLongitude, allowedDistanceMeters: _allowedDistanceMeters);
      if (!mounted) return;
      if (!presence.isInside) {
        state = state.copyWith(preparationOrders: const [], isLoadingPrep: false, branchPresence: presence);
        return;
      }
      final orders = await _repository.getPreparationAndTakenOrders(latitude: presence.latitude!, longitude: presence.longitude!);
      if (!mounted) return;
      final unchanged = routeOrdersHaveSameContent(state.preparationOrders, orders);
      if (!unchanged || state.isLoadingPrep || state.errorPrep != null || state.branchPresence != presence) {
        state = state.copyWith(preparationOrders: unchanged ? state.preparationOrders : orders,
          isLoadingPrep: false, branchPresence: presence, clearErrorPrep: true);
      }
    } catch (error) {
      if (!mounted || silently) return;
      state = state.copyWith(isLoadingPrep: false,
        errorPrep: userFacingErrorMessage(error, fallback: 'No pudimos cargar los pedidos en preparación.'));
    }
  }

  Future<void> loadAll({int? branchId, bool silently = false}) async {
    await Future.wait([load(branchId: branchId, silently: silently),
      loadPreparation(silently: silently), loadRouting(silently: silently)]);
  }

  Future<void> loadRouting({bool silently = false, bool ensureFresh = false}) {
    final current = _routingLoadInFlight;
    if (current != null) {
      if (ensureFresh) _reloadRoutingAfterInFlight = true;
      return current;
    }
    final operation = _loadRoutingUntilFresh(silently: silently);
    _routingLoadInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_routingLoadInFlight, operation)) _routingLoadInFlight = null;
    });
  }

  Future<void> _loadRoutingUntilFresh({required bool silently}) async {
    do {
      _reloadRoutingAfterInFlight = false;
      await _loadRouting(silently: silently);
      silently = true;
    } while (_reloadRoutingAfterInFlight && mounted);
  }

  Future<void> _loadRouting({required bool silently}) async {
    if (!mounted) return;
    final revision = _routingRevision;
    if (!silently) state = state.copyWith(isLoadingRouting: true, clearErrorRouting: true);
    try {
      final plan = await _routingRepository.getPlan();
      if (!mounted) return;
      if (revision != _routingRevision || _reloadRoutingAfterInFlight) {
        _reloadRoutingAfterInFlight = true;
        state = state.copyWith(isLoadingRouting: false);
        return;
      }
      state = state.copyWith(routingPlan: plan, isLoadingRouting: false, clearErrorRouting: true);
      _planExpiry?.cancel();
      final generated = plan.generatedAtUtc;
      if (generated != null && !plan.isStale) {
        final seconds = generated.add(const Duration(minutes: 2))
            .difference(DateTime.now().toUtc()).inSeconds.clamp(0, 120).toInt();
        // A single local expiry callback, not HTTP polling.
        _planExpiry = Timer(Duration(seconds: seconds), () {
          if (mounted && identical(state.routingPlan, plan)) {
            invalidateRouting('Venció la vigencia de esta recomendación.');
          }
        });
      }
    } catch (error) {
      if (!mounted) return;
      final message = userFacingErrorMessage(error, fallback: 'No pudimos preparar la ruta sugerida.');
      state = state.copyWith(isLoadingRouting: false, errorRouting: message,
        routingPlan: state.routingPlan?.asStale(message));
    }
  }

  void invalidateRouting(String reason, {Set<int> removeOrders = const {}}) {
    if (!mounted) return;
    _routingRevision++;
    if (_routingLoadInFlight != null) _reloadRoutingAfterInFlight = true;
    _planExpiry?.cancel();
    if (state.routingPlan != null) {
      state = state.copyWith(routingPlan: state.routingPlan!.asStale(reason, removeOrders: removeOrders));
    }
  }

  /// Existing HomeScreen event handler calls this; no second SignalR subscription.
  Future<void> reconcileRoutingOrder(Order order) async {
    if (!mounted) return;
    final inPlan = state.routingPlan?.containsOrder(order.id) ?? false;
    if (order.deliveryManId != null || order.status == OrderStatus.onTheWay
        || order.status == OrderStatus.delivered || order.status == OrderStatus.cancelled) {
      removeOrders([order.id]);
    } else if (inPlan) {
      invalidateRouting('La sucursal actualizó un pedido de esta ruta.');
    }
    if (inPlan) await loadRouting(silently: true, ensureFresh: true);
  }

  Future<void> refreshReadyOrders() async {
    _ordersRevision++;
    invalidateRouting('Cambió la disponibilidad de los pedidos.');
    await Future.wait([load(silently: true, ensureFresh: true), loadRouting(silently: true, ensureFresh: true)]);
  }

  void removeOrders(Iterable<int> orderIds) {
    if (!mounted) return;
    final ids = orderIds.toSet();
    if (ids.isEmpty) return;
    _ordersRevision++;
    if (_routingLoadInFlight != null || ids.any((id) => state.routingPlan?.containsOrder(id) ?? false)) {
      invalidateRouting('Un pedido dejó de estar disponible.', removeOrders: ids);
    }
    final orders = state.orders.where((o) => !ids.contains(o.id)).toList();
    final preparing = state.preparationOrders.where((o) => !ids.contains(o.id)).toList();
    if (orders.length != state.orders.length || preparing.length != state.preparationOrders.length) {
      state = state.copyWith(orders: orders, preparationOrders: preparing);
    }
  }

  Future<List<Order>> selfAssign({required List<int> orderIds, int? proposalId, int? expectedPlanVersion}) async {
    if (proposalId != null && (state.routingPlan == null || state.routingPlan!.isStale
        || state.routingPlan!.version != expectedPlanVersion)) {
      throw StateError('El plan cambió. Actualiza las rutas o selecciona los pedidos manualmente.');
    }
    if (_canBeginDelivery != null && !await _canBeginDelivery!()) {
      throw StateError('No puedes tomar pedidos hasta que el seguimiento de ubicación esté activo.');
    }
    final assigned = await _repository.selfAssignOrders(orderIds: orderIds,
      proposalId: proposalId, expectedPlanVersion: expectedPlanVersion);
    removeOrders(assigned.map((o) => o.id));
    return assigned;
  }
}

final availableNotifierProvider = StateNotifierProvider.autoDispose<AvailableNotifier, AvailableState>((ref) {
  final hasUser = ref.watch(authNotifierProvider.select((auth) => auth.user != null));
  final branchLatitude = ref.watch(authNotifierProvider.select(
    (auth) => auth.workSession?.branchLatitude ?? auth.user?.branchLatitude));
  final branchLongitude = ref.watch(authNotifierProvider.select(
    (auth) => auth.workSession?.branchLongitude ?? auth.user?.branchLongitude));
  final allowedDistanceMeters = ref.watch(authNotifierProvider.select(
    (auth) => auth.workSession?.tracking.allowedDistanceMeters ?? 50));
  return AvailableNotifier(ref.watch(orderRepositoryProvider), ref.watch(branchPresenceVerifierProvider),
    ref.watch(deliveryRoutingRepositoryProvider), hasUser ? ref.read(authNotifierProvider).user : null,
    branchLatitude, branchLongitude, allowedDistanceMeters,
    canBeginDelivery: () => ref.read(authNotifierProvider.notifier).canBeginDelivery());
});
