import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';
import '../../auth/data/auth_models.dart';
import '../../auth/presentation/auth_notifier.dart';
import '../data/branch_presence_verifier.dart';
import '../../routing/delivery_routing_models.dart';
import '../../routing/delivery_routing_repository.dart';
import '../../../core/errors/user_facing_error.dart';
import '../../../core/api/api_exception.dart';
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

  const AvailableState(
      {this.orders = const [],
      this.preparationOrders = const [],
      this.isLoading = false,
      this.isLoadingPrep = false,
      this.error,
      this.errorPrep,
      this.branchPresence =
          const BranchPresenceResult(status: BranchPresenceStatus.initial),
      this.routingPlan,
      this.isLoadingRouting = false,
      this.errorRouting});

  AvailableState copyWith(
          {List<Order>? orders,
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
          bool clearErrorPrep = false}) =>
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
              clearErrorRouting ? null : (errorRouting ?? this.errorRouting));
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
  CancelToken? _availableRequest;
  Future<void>? _preparationLoadInFlight;
  Future<void>? _routingLoadInFlight;
  int _ordersRevision = 0;
  int _routingRevision = 0;
  bool _reloadAvailableAfterInFlight = false;
  bool _reloadRoutingAfterInFlight = false;
  Timer? _planExpiry;
  Timer? _routingRetry;
  int _routingRetryAttempt = 0;
  int _announcedRoutingVersion = 0;
  bool _routingActive = true;

  AvailableNotifier(
      this._repository,
      this._branchPresenceVerifier,
      this._routingRepository,
      this._user,
      this._branchLatitude,
      this._branchLongitude,
      this._allowedDistanceMeters,
      {Future<bool> Function()? canBeginDelivery})
      : _canBeginDelivery = canBeginDelivery,
        super(const AvailableState());

  @override
  void dispose() {
    _availableRequest?.cancel('Vista de disponibles cerrada');
    _planExpiry?.cancel();
    _routingRetry?.cancel();
    super.dispose();
  }

  Future<void> load(
      {int? branchId, bool silently = false, bool ensureFresh = false}) {
    final current = _availableLoadInFlight;
    if (current != null) {
      if (ensureFresh) _reloadAvailableAfterInFlight = true;
      return current;
    }
    final operation = _loadUntilFresh(branchId: branchId, silently: silently);
    _availableLoadInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_availableLoadInFlight, operation)) {
        _availableLoadInFlight = null;
      }
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
    final request = CancelToken();
    _availableRequest = request;
    if (!silently) state = state.copyWith(isLoading: true, clearError: true);
    try {
      final orders = await _repository.getAvailableOrders(
          branchId: branchId, cancelToken: request);
      if (!mounted) return;
      if (revision != _ordersRevision || _reloadAvailableAfterInFlight) {
        _reloadAvailableAfterInFlight = true;
        if (state.isLoading) state = state.copyWith(isLoading: false);
        return;
      }
      final unchanged = routeOrdersHaveSameContent(state.orders, orders);
      if (!unchanged || state.isLoading || state.error != null) {
        state = state.copyWith(
            orders: unchanged ? state.orders : orders,
            isLoading: false,
            clearError: true);
      }
    } catch (error) {
      if (!mounted || request.isCancelled) return;
      // Silent refreshes preserve the prior list, but a first visible load
      // must not remain stuck showing its loading indicator on a retry error.
      if (silently && !state.isLoading) return;
      state = state.copyWith(
          isLoading: false,
          error: userFacingErrorMessage(error,
              fallback: 'No pudimos cargar los pedidos disponibles.'));
    } finally {
      if (identical(_availableRequest, request)) _availableRequest = null;
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
              status: BranchPresenceStatus.checking));
    }
    try {
      if (_user == null) {
        state = state.copyWith(
            isLoadingPrep: false,
            branchPresence: const BranchPresenceResult(
                status: BranchPresenceStatus.locationUnavailable));
        return;
      }
      final presence = await _branchPresenceVerifier.verify(
          branchLatitude: _branchLatitude,
          branchLongitude: _branchLongitude,
          allowedDistanceMeters: _allowedDistanceMeters);
      if (!mounted) return;
      if (!presence.isInside) {
        state = state.copyWith(
            preparationOrders: const [],
            isLoadingPrep: false,
            branchPresence: presence);
        return;
      }
      final orders = await _repository.getPreparationAndTakenOrders(
          latitude: presence.latitude!, longitude: presence.longitude!);
      if (!mounted) return;
      final unchanged =
          routeOrdersHaveSameContent(state.preparationOrders, orders);
      if (!unchanged ||
          state.isLoadingPrep ||
          state.errorPrep != null ||
          state.branchPresence != presence) {
        state = state.copyWith(
            preparationOrders: unchanged ? state.preparationOrders : orders,
            isLoadingPrep: false,
            branchPresence: presence,
            clearErrorPrep: true);
      }
    } catch (error) {
      if (!mounted || silently) return;
      state = state.copyWith(
          isLoadingPrep: false,
          errorPrep: userFacingErrorMessage(error,
              fallback: 'No pudimos cargar los pedidos en preparación.'));
    }
  }

  Future<void> loadAll({int? branchId, bool silently = false}) async {
    await Future.wait([
      load(branchId: branchId, silently: silently),
      loadPreparation(silently: silently),
      loadRouting(silently: silently)
    ]);
  }

  Future<void> loadRouting({bool silently = false, bool ensureFresh = false}) {
    if (!mounted || !_routingActive) return Future.value();
    if (!silently) {
      _routingRetry?.cancel();
      _routingRetryAttempt = 0;
    }
    final current = _routingLoadInFlight;
    if (current != null) {
      if (ensureFresh) _reloadRoutingAfterInFlight = true;
      return current;
    }
    final operation = _loadRoutingUntilFresh(silently: silently);
    _routingLoadInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_routingLoadInFlight, operation)) {
        _routingLoadInFlight = null;
      }
    });
  }

  Future<void> _loadRoutingUntilFresh({required bool silently}) async {
    var attempts = 0;
    do {
      _reloadRoutingAfterInFlight = false;
      await _loadRouting(silently: silently);
      attempts++;
      silently = true;
    } while (_reloadRoutingAfterInFlight &&
        mounted &&
        _routingActive &&
        attempts < 2);
    if (_reloadRoutingAfterInFlight && mounted) {
      state = state.copyWith(
          isLoadingRouting: false,
          errorRouting:
              'La disponibilidad cambió mientras actualizábamos las rutas.');
      _scheduleRoutingRetry();
    }
  }

  Future<void> routingPlanChanged(int? version) {
    if (!mounted) return Future.value();
    if (version == null) {
      invalidateRouting('Cambió la disponibilidad de las rutas.');
      return loadRouting(silently: true, ensureFresh: true);
    }
    if (version <= _announcedRoutingVersion ||
        version <= (state.routingPlan?.version ?? 0)) {
      return Future.value();
    }
    _announcedRoutingVersion = version;
    _planExpiry?.cancel();
    if (state.routingPlan != null) {
      state = state.copyWith(
          routingPlan: state.routingPlan!
              .asStale('Estamos actualizando las rutas automáticamente.'));
    }
    return loadRouting(silently: true);
  }

  void setRoutingActive(bool active) {
    if (!mounted || active == _routingActive) return;
    _routingActive = active;
    if (!active) {
      _planExpiry?.cancel();
      _routingRetry?.cancel();
    } else {
      _routingRetryAttempt = 0;
      unawaited(loadRouting(silently: true, ensureFresh: true));
    }
  }

  void _scheduleRoutingRetry() {
    if (!mounted ||
        !_routingActive ||
        _routingRetry?.isActive == true ||
        _routingRetryAttempt >= 3) {
      return;
    }
    final delay = Duration(seconds: 1 << _routingRetryAttempt++);
    _routingRetry = Timer(delay, () {
      if (mounted && _routingActive) unawaited(loadRouting(silently: true));
    });
  }

  bool _isTransientRoutingError(Object error) {
    if (error is TimeoutException) return true;
    final status = error is DioException
        ? error.response?.statusCode ??
            (error.error is ApiException
                ? (error.error as ApiException).statusCode
                : null)
        : error is ApiException
            ? error.statusCode
            : null;
    if (status != null) {
      return status == 408 || status == 409 || status == 429 || status >= 500;
    }
    return error is DioException &&
        (error.type == DioExceptionType.connectionError ||
            error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.receiveTimeout ||
            error.type == DioExceptionType.sendTimeout);
  }

  Future<void> _loadRouting({required bool silently}) async {
    if (!mounted) return;
    final revision = _routingRevision;
    if (!silently) {
      state = state.copyWith(isLoadingRouting: true, clearErrorRouting: true);
    }
    try {
      final plan = await _routingRepository.getPlan();
      if (!mounted) return;
      if (revision != _routingRevision || _reloadRoutingAfterInFlight) {
        _reloadRoutingAfterInFlight = true;
        state = state.copyWith(isLoadingRouting: false);
        return;
      }
      if (plan.version < _announcedRoutingVersion ||
          plan.version < (state.routingPlan?.version ?? 0)) {
        _reloadRoutingAfterInFlight = true;
        state = state.copyWith(
            isLoadingRouting: false,
            errorRouting: 'El servidor aún está actualizando las rutas.');
        return;
      }
      final expires = plan.effectiveExpiresAtUtc;
      if (plan.isStale ||
          (expires != null && !expires.isAfter(DateTime.now().toUtc()))) {
        state = state.copyWith(
            isLoadingRouting: false,
            routingPlan: plan.asStale('La recomendación necesita renovarse.'),
            errorRouting: 'No pudimos obtener una recomendación vigente.');
        _scheduleRoutingRetry();
        return;
      }
      _routingRetry?.cancel();
      _routingRetryAttempt = 0;
      state = state.copyWith(
          routingPlan: plan, isLoadingRouting: false, clearErrorRouting: true);
      _planExpiry?.cancel();
      if (expires != null && _routingActive) {
        _planExpiry = Timer(expires.difference(DateTime.now().toUtc()), () {
          if (mounted && _routingActive && identical(state.routingPlan, plan)) {
            invalidateRouting('Venció la vigencia de esta recomendación.');
            unawaited(loadRouting(silently: true));
          }
        });
      }
    } catch (error) {
      if (!mounted) return;
      final message = userFacingErrorMessage(error,
          fallback: 'No pudimos preparar la ruta sugerida.');
      state = state.copyWith(
          isLoadingRouting: false,
          errorRouting: message,
          routingPlan: state.routingPlan?.asStale(message));
      if (_isTransientRoutingError(error)) _scheduleRoutingRetry();
    }
  }

  void invalidateRouting(String reason, {Set<int> removeOrders = const {}}) {
    if (!mounted) return;
    _routingRevision++;
    if (_routingLoadInFlight != null) _reloadRoutingAfterInFlight = true;
    _planExpiry?.cancel();
    if (state.routingPlan != null) {
      state = state.copyWith(
          routingPlan:
              state.routingPlan!.asStale(reason, removeOrders: removeOrders));
    }
  }

  /// Existing HomeScreen event handler calls this; no second SignalR subscription.
  Future<void> reconcileRoutingOrder(Order order) async {
    if (!mounted) return;
    final inPlan = state.routingPlan?.containsOrder(order.id) ?? false;
    if (order.deliveryManId != null ||
        order.status == OrderStatus.onTheWay ||
        order.status == OrderStatus.delivered ||
        order.status == OrderStatus.cancelled) {
      removeOrders([order.id]);
    } else if (inPlan) {
      invalidateRouting('La sucursal actualizó un pedido de esta ruta.');
    }
    if (inPlan) await loadRouting(silently: true, ensureFresh: true);
  }

  Future<void> refreshReadyOrders() async {
    _ordersRevision++;
    _cancelObsoleteAvailableRequest();
    invalidateRouting('Cambió la disponibilidad de los pedidos.');
    await Future.wait([
      load(silently: true, ensureFresh: true),
      loadRouting(silently: true, ensureFresh: true)
    ]);
  }

  void _cancelObsoleteAvailableRequest() {
    if (_availableLoadInFlight == null) return;
    // An in-flight GET is no longer authoritative. Coalesce refresh events
    // into the already-existing second pass, instead of starting parallel GETs.
    _reloadAvailableAfterInFlight = true;
    _availableRequest?.cancel('Cambió la disponibilidad de los pedidos');
  }

  void removeOrders(Iterable<int> orderIds) {
    if (!mounted) return;
    final ids = orderIds.toSet();
    if (ids.isEmpty) return;
    _ordersRevision++;
    _cancelObsoleteAvailableRequest();
    if (_routingLoadInFlight != null ||
        ids.any((id) => state.routingPlan?.containsOrder(id) ?? false)) {
      invalidateRouting('Un pedido dejó de estar disponible.',
          removeOrders: ids);
    }
    final orders = state.orders.where((o) => !ids.contains(o.id)).toList();
    final preparing =
        state.preparationOrders.where((o) => !ids.contains(o.id)).toList();
    if (orders.length != state.orders.length ||
        preparing.length != state.preparationOrders.length) {
      state = state.copyWith(orders: orders, preparationOrders: preparing);
    }
  }

  Future<DeliveryRouteProposal> previewRouting(
      List<int> orderIds, int version) async {
    final plan = state.routingPlan;
    if (plan == null || plan.isStale || plan.version != version) {
      throw StateError('El plan cambió. Actualiza las rutas.');
    }
    final revision = _routingRevision;
    final preview = await _routingRepository.preview(orderIds, version);
    if (!mounted ||
        revision != _routingRevision ||
        state.routingPlan?.version != version) {
      throw StateError(
          'Los pedidos cambiaron durante el cálculo. Actualiza las rutas.');
    }
    return preview;
  }

  Future<List<Order>> selfAssign(
      {required List<int> orderIds,
      int? proposalId,
      int? expectedPlanVersion,
      bool modifiedProposal = false,
      String? selectionFingerprint}) async {
    if (proposalId != null &&
        (state.routingPlan == null ||
            state.routingPlan!.isStale ||
            state.routingPlan!.version != expectedPlanVersion)) {
      throw StateError(
          'El plan cambió. Actualiza las rutas o selecciona los pedidos manualmente.');
    }
    if (_canBeginDelivery != null && !await _canBeginDelivery!()) {
      throw StateError(
          'No puedes tomar pedidos hasta que el seguimiento de ubicación esté activo.');
    }
    try {
      final assigned = await _repository.selfAssignOrders(
          orderIds: orderIds,
          proposalId: proposalId,
          expectedPlanVersion: expectedPlanVersion,
          modifiedProposal: modifiedProposal,
          selectionFingerprint: selectionFingerprint);
      removeOrders(assigned.map((o) => o.id));
      return assigned;
    } on DioException catch (error) {
      if (error.response?.statusCode == 409) {
        invalidateRouting('Otro dispositivo cambió la disponibilidad.');
        unawaited(loadAll());
      }
      rethrow;
    }
  }
}

final availableNotifierProvider =
    StateNotifierProvider.autoDispose<AvailableNotifier, AvailableState>((ref) {
  final hasUser =
      ref.watch(authNotifierProvider.select((auth) => auth.user != null));
  final branchLatitude = ref.watch(authNotifierProvider.select(
      (auth) => auth.workSession?.branchLatitude ?? auth.user?.branchLatitude));
  final branchLongitude = ref.watch(authNotifierProvider.select((auth) =>
      auth.workSession?.branchLongitude ?? auth.user?.branchLongitude));
  final allowedDistanceMeters = ref.watch(authNotifierProvider.select(
      (auth) => auth.workSession?.tracking.allowedDistanceMeters ?? 50));
  return AvailableNotifier(
      ref.watch(orderRepositoryProvider),
      ref.watch(branchPresenceVerifierProvider),
      ref.watch(deliveryRoutingRepositoryProvider),
      hasUser ? ref.read(authNotifierProvider).user : null,
      branchLatitude,
      branchLongitude,
      allowedDistanceMeters,
      canBeginDelivery: () =>
          ref.read(authNotifierProvider.notifier).canBeginDelivery());
});
