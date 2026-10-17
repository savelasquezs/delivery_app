class DeliveryRoutingStop {
  final int orderId;
  final int? sequence;
  final String address;
  final String? neighborhood;
  final DateTime estimatedReadyAtUtc;
  final bool isReady;
  final String? unroutedReason;

  const DeliveryRoutingStop({required this.orderId, required this.sequence,
    required this.address, required this.neighborhood, required this.estimatedReadyAtUtc,
    required this.isReady, required this.unroutedReason});

  factory DeliveryRoutingStop.fromJson(Map<String, dynamic> json) => DeliveryRoutingStop(
    orderId: json['orderId'] as int, sequence: json['stopSequence'] as int?,
    address: json['address'] as String? ?? '', neighborhood: json['neighborhood'] as String?,
    estimatedReadyAtUtc: DateTime.parse(json['estimatedReadyAtUtc'] as String),
    isReady: json['isReady'] as bool? ?? false, unroutedReason: json['unroutedReason'] as String?);

  String get reasonLabel => switch (unroutedReason) {
    'requiresLocation' => 'falta ubicación válida',
    'noCapacity' => 'sin domiciliario disponible',
    'preparingLater' => 'preparación fuera de la ventana de salida',
    'waitingWouldDelayReadyOrders' => 'esperarlo retrasaría pedidos listos',
    'notSelectedByOptimizer' => 'sin combinación factible en este cálculo',
    _ => 'requiere revisión',
  };
}

class DeliveryRouteProposal {
  final int id;
  final int sequence;
  final String recommendation;
  final int durationSeconds;
  final int distanceMeters;
  final bool isClaimable;
  final List<int> claimableReadyOrderIds;
  final List<DeliveryRoutingStop> stops;
  final String? warning;

  const DeliveryRouteProposal({required this.id, required this.sequence,
    required this.recommendation, required this.durationSeconds, required this.distanceMeters,
    required this.isClaimable, required this.claimableReadyOrderIds, required this.stops, required this.warning});

  DeliveryRouteProposal asStale(Set<int> removed) => DeliveryRouteProposal(
    id: id, sequence: sequence, recommendation: recommendation,
    durationSeconds: durationSeconds, distanceMeters: distanceMeters,
    isClaimable: false, claimableReadyOrderIds: const [],
    stops: stops.where((s) => !removed.contains(s.orderId)).toList(), warning: warning);

  factory DeliveryRouteProposal.fromJson(Map<String, dynamic> json) => DeliveryRouteProposal(
    id: json['id'] as int, sequence: json['sequence'] as int,
    recommendation: json['recommendation'] as String? ?? '',
    durationSeconds: (json['validatedDrivingDurationSeconds'] ?? json['approximateDrivingDurationSeconds'] ?? 0) as int,
    distanceMeters: (json['validatedDistanceMeters'] ?? json['approximateDistanceMeters'] ?? 0) as int,
    isClaimable: json['status'] != 'stale' && (json['isClaimable'] as bool? ?? false),
    claimableReadyOrderIds: (json['claimableReadyOrderIds'] as List? ?? const []).cast<int>(),
    stops: (json['stops'] as List? ?? const []).map((value) =>
      DeliveryRoutingStop.fromJson(Map<String, dynamic>.from(value as Map))).toList(),
    warning: json['planningWarnings'] as String?);
}

class DeliveryRoutingPlan {
  final int id;
  final int version;
  final int availableNow;
  final int availableSoon;
  final List<DeliveryRouteProposal> proposals;
  final List<DeliveryRoutingStop> unroutedOrders;
  final String? warning;
  final bool isStale;
  final DateTime? generatedAtUtc;

  const DeliveryRoutingPlan({required this.id, required this.version,
    required this.availableNow, required this.availableSoon,
    required this.proposals, required this.unroutedOrders, required this.warning,
    this.isStale = false, this.generatedAtUtc});

  bool containsOrder(int id) => proposals.any((p) => p.stops.any((s) => s.orderId == id))
      || unroutedOrders.any((s) => s.orderId == id);

  DeliveryRoutingPlan asStale(String reason, {Set<int> removeOrders = const {}}) => DeliveryRoutingPlan(
    id: id, version: version, availableNow: availableNow, availableSoon: availableSoon,
    isStale: true, generatedAtUtc: generatedAtUtc,
    warning: 'Plan desactualizado. $reason\nDesliza para actualizar. La selección manual sigue disponible.',
    proposals: proposals.map((p) => p.asStale(removeOrders)).where((p) => p.stops.isNotEmpty).toList(),
    unroutedOrders: unroutedOrders.where((s) => !removeOrders.contains(s.orderId)).toList());

  factory DeliveryRoutingPlan.fromJson(Map<String, dynamic> json) {
    final capacity = Map<String, dynamic>.from(json['capacity'] as Map? ?? {});
    final unrouted = (json['unroutedOrders'] as List? ?? const []).map((value) =>
        DeliveryRoutingStop.fromJson(Map<String, dynamic>.from(value as Map))).toList();
    // The existing screen already renders plan warnings above the routes.
    // Include explicit exclusion reasons instead of leaving a generic "pendiente".
    final messages = <String>[
      if (json['warnings'] is String && (json['warnings'] as String).isNotEmpty) json['warnings'] as String,
      for (final stop in unrouted) '#${stop.orderId}: ${stop.reasonLabel}.',
    ];
    final plan = DeliveryRoutingPlan(
      id: json['id'] as int, version: json['version'] as int,
      availableNow: capacity['availableNow'] as int? ?? 0,
      availableSoon: capacity['availableSoon'] as int? ?? 0,
      generatedAtUtc: DateTime.tryParse(json['generatedAtUtc']?.toString() ?? '')?.toUtc(),
      proposals: (json['proposals'] as List? ?? const []).map((value) =>
          DeliveryRouteProposal.fromJson(Map<String, dynamic>.from(value as Map))).toList(),
      unroutedOrders: unrouted, warning: messages.isEmpty ? null : messages.join('\n'));
    return json['status'] == 'stale' ? plan.asStale('Los pedidos cambiaron.') : plan;
  }
}
