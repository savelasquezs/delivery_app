class DeliveryRoutingStop {
  final int orderId;
  final int? sequence;
  final String address;
  final String? neighborhood;
  final DateTime estimatedReadyAtUtc;
  final bool isReady;
  final String? unroutedReason;
  final String preparationConfidence;
  final double readyWithinWindowProbability;
  final DateTime? estimatedArrivalAtUtc;
  final int? deliveryTimeLimitSeconds;
  final int serviceSeconds;

  const DeliveryRoutingStop(
      {required this.orderId,
      required this.sequence,
      required this.address,
      required this.neighborhood,
      required this.estimatedReadyAtUtc,
      required this.isReady,
      required this.unroutedReason,
      this.preparationConfidence = 'unknown',
      this.readyWithinWindowProbability = 0,
      this.estimatedArrivalAtUtc,
      this.deliveryTimeLimitSeconds,
      this.serviceSeconds = 0});

  factory DeliveryRoutingStop.fromJson(Map<String, dynamic> json) =>
      DeliveryRoutingStop(
          orderId: json['orderId'] as int,
          sequence: json['stopSequence'] as int?,
          address: json['address'] as String? ?? '',
          neighborhood: json['neighborhood'] as String?,
          estimatedReadyAtUtc:
              DateTime.parse(json['estimatedReadyAtUtc'] as String),
          isReady: json['isReady'] as bool? ?? false,
          unroutedReason: json['unroutedReason'] as String?,
          preparationConfidence:
              json['preparationConfidence'] as String? ?? 'unknown',
          readyWithinWindowProbability:
              (json['readyWithinWindowProbability'] as num?)?.toDouble() ?? 0,
          deliveryTimeLimitSeconds:
              (json['deliveryTimeLimitSeconds'] as num?)?.toInt(),
          serviceSeconds: (json['serviceSeconds'] as num?)?.toInt() ?? 0,
          estimatedArrivalAtUtc:
              DateTime.tryParse(json['estimatedArrivalAtUtc']?.toString() ?? '')
                  ?.toUtc());

  String? get exceptionLabel => deliveryTimeLimitSeconds == null
      ? null
      : 'Excepción automática por distancia · límite ${(deliveryTimeLimitSeconds! / 60).ceil()} min';

  String get reasonLabel => switch (unroutedReason) {
        'requiresLocation' => 'falta ubicación válida',
        'noCapacity' => 'sin domiciliario disponible',
        'preparingLater' => 'preparación fuera de la ventana de salida',
        'waitingWouldDelayReadyOrders' => 'esperarlo retrasaría pedidos listos',
        'preparationUncertain' =>
          'preparación sin suficiente certeza para esta salida',
        'notSelectedByOptimizer' =>
          'pendiente por costo de recorrido o capacidad de esta salida',
        'deliveryTimeLimit' => 'supera el tiempo máximo desde la sucursal',
        'directionConflict' => 'requiere una salida en otra dirección',
        'additionalDelayOrDurationLimit' =>
          'añadirlo excede la duración o el retraso permitido de esta salida',
        _ => 'requiere revisión',
      };

  String get confidenceLabel => switch (preparationConfidence) {
        'confirmed' => 'confirmada',
        'high' => 'alta',
        'medium' => 'media',
        'low' => 'baja',
        _ => 'sin confirmar',
      };
}

class DeliveryRouteProposal {
  final int id;
  final int sequence;
  final String recommendation;
  final int durationSeconds;
  final int? lastDeliverySeconds;
  final int distanceMeters;
  final bool isClaimable;
  final List<int> claimableReadyOrderIds;
  final List<DeliveryRoutingStop> stops;
  final String? warning;
  final String? selectionFingerprint;
  final DateTime? waitDeadlineAtUtc;
  final bool usesApproximateMetrics;
  final DateTime? expectedDepartureAtUtc;
  final int? returnDrivingDurationSeconds;
  final int? returnDistanceMeters;
  final bool usesApproximateReturnMetrics;

  const DeliveryRouteProposal(
      {required this.id,
      required this.sequence,
      required this.recommendation,
      required this.durationSeconds,
      required this.distanceMeters,
      required this.isClaimable,
      required this.claimableReadyOrderIds,
      required this.stops,
      required this.warning,
      this.selectionFingerprint,
      this.waitDeadlineAtUtc,
      this.lastDeliverySeconds,
      this.usesApproximateMetrics = true,
      this.expectedDepartureAtUtc,
      this.returnDrivingDurationSeconds,
      this.returnDistanceMeters,
      this.usesApproximateReturnMetrics = true});

  int get deliveryElapsedSeconds =>
      durationSeconds +
      stops.fold(0, (total, stop) => total + stop.serviceSeconds);

  int? get roundTripElapsedSeconds => returnDrivingDurationSeconds == null
      ? null
      : deliveryElapsedSeconds + returnDrivingDurationSeconds!;

  int? get roundTripDistanceMeters => returnDistanceMeters == null
      ? null
      : distanceMeters + returnDistanceMeters!;

  DateTime? get deliveryCompletedAtUtc =>
      expectedDepartureAtUtc?.add(Duration(seconds: deliveryElapsedSeconds));

  DateTime? get returnedToBranchAtUtc => roundTripElapsedSeconds == null
      ? null
      : expectedDepartureAtUtc
          ?.add(Duration(seconds: roundTripElapsedSeconds!));

  String get timingLabel {
    final driving =
        '${usesApproximateMetrics ? '~' : ''}${(durationSeconds / 60).ceil()} min de conducción';
    return lastDeliverySeconds == null
        ? driving
        : '~${(lastDeliverySeconds! / 60).ceil()} min hasta última entrega · $driving';
  }

  DeliveryRouteProposal asStale(Set<int> removed) => DeliveryRouteProposal(
      id: id,
      sequence: sequence,
      recommendation: recommendation,
      durationSeconds: durationSeconds,
      lastDeliverySeconds: lastDeliverySeconds,
      distanceMeters: distanceMeters,
      isClaimable: false,
      claimableReadyOrderIds: const [],
      stops: stops.where((s) => !removed.contains(s.orderId)).toList(),
      warning: warning,
      usesApproximateMetrics: usesApproximateMetrics);

  factory DeliveryRouteProposal.fromJson(Map<String, dynamic> json) => DeliveryRouteProposal(
      id: json['id'] as int,
      sequence: json['sequence'] as int,
      recommendation: json['recommendation'] as String? ?? '',
      durationSeconds: (json['validatedDrivingDurationSeconds'] ??
          json['approximateDrivingDurationSeconds'] ??
          0) as int,
      lastDeliverySeconds: (json['lastDeliverySeconds'] as num?)?.toInt(),
      expectedDepartureAtUtc:
          DateTime.tryParse(json['expectedDepartureAtUtc']?.toString() ?? '')
              ?.toUtc(),
      returnDrivingDurationSeconds:
          (json['returnDrivingDurationSeconds'] as num?)?.toInt(),
      returnDistanceMeters: (json['returnDistanceMeters'] as num?)?.toInt(),
      usesApproximateReturnMetrics:
          json['usesApproximateReturnMetrics'] as bool? ?? true,
      distanceMeters: (json['validatedDistanceMeters'] ??
          json['approximateDistanceMeters'] ??
          0) as int,
      isClaimable:
          json['status'] != 'stale' && (json['isClaimable'] as bool? ?? false),
      claimableReadyOrderIds:
          (json['claimableReadyOrderIds'] as List? ?? const []).cast<int>(),
      stops: (json['stops'] as List? ?? const [])
          .map(
              (value) => DeliveryRoutingStop.fromJson(Map<String, dynamic>.from(value as Map)))
          .toList(),
      warning: json['planningWarnings'] as String?,
      usesApproximateMetrics: (json['validatedDrivingDurationSeconds'] as num? ?? 0) <= 0,
      selectionFingerprint: json['selectionFingerprint'] as String?,
      waitDeadlineAtUtc: DateTime.tryParse(json['waitDeadlineAtUtc']?.toString() ?? '')?.toUtc());
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

  const DeliveryRoutingPlan(
      {required this.id,
      required this.version,
      required this.availableNow,
      required this.availableSoon,
      required this.proposals,
      required this.unroutedOrders,
      required this.warning,
      this.isStale = false,
      this.generatedAtUtc});

  bool containsOrder(int id) =>
      proposals.any((p) => p.stops.any((s) => s.orderId == id)) ||
      unroutedOrders.any((s) => s.orderId == id);

  int get proposedOrderCount =>
      proposals.fold(0, (count, p) => count + p.stops.length);
  int get totalOrderCount => proposedOrderCount + unroutedOrders.length;
  int get proposedReadyCount =>
      proposals.expand((p) => p.stops).where((s) => s.isReady).length;
  int get totalReadyCount =>
      proposedReadyCount + unroutedOrders.where((s) => s.isReady).length;

  DeliveryRoutingPlan asStale(String reason,
          {Set<int> removeOrders = const {}}) =>
      DeliveryRoutingPlan(
          id: id,
          version: version,
          availableNow: availableNow,
          availableSoon: availableSoon,
          isStale: true,
          generatedAtUtc: generatedAtUtc,
          warning:
              'Plan desactualizado. $reason\nDesliza para actualizar. La selección manual sigue disponible.',
          proposals: proposals
              .map((p) => p.asStale(removeOrders))
              .where((p) => p.stops.isNotEmpty)
              .toList(),
          unroutedOrders: unroutedOrders
              .where((s) => !removeOrders.contains(s.orderId))
              .toList());

  factory DeliveryRoutingPlan.fromJson(Map<String, dynamic> json) {
    final capacity = Map<String, dynamic>.from(json['capacity'] as Map? ?? {});
    final unrouted = (json['unroutedOrders'] as List? ?? const [])
        .map((value) => DeliveryRoutingStop.fromJson(
            Map<String, dynamic>.from(value as Map)))
        .toList();
    final messages = <String>[
      if (json['warnings'] is String && (json['warnings'] as String).isNotEmpty)
        json['warnings'] as String,
    ];
    final couriers = (capacity['couriers'] as List? ?? const [])
        .whereType<Map>()
        .where((c) =>
            (c['workSessionId'] as num? ?? 0) > 0 &&
            (c['state'] == 'unknown' || c['state'] == 'probableAtBranch'))
        .length;
    if (couriers > 0) {
      messages.add(
          '$couriers domiciliario(s) sin GPS reciente y confiable. La capacidad de rutas puede reducirse.');
    }
    final plan = DeliveryRoutingPlan(
        id: json['id'] as int,
        version: json['version'] as int,
        availableNow: capacity['availableNow'] as int? ?? 0,
        availableSoon: capacity['availableSoon'] as int? ?? 0,
        generatedAtUtc:
            DateTime.tryParse(json['generatedAtUtc']?.toString() ?? '')
                ?.toUtc(),
        proposals: (json['proposals'] as List? ?? const [])
            .map((value) => DeliveryRouteProposal.fromJson(
                Map<String, dynamic>.from(value as Map)))
            .toList(),
        unroutedOrders: unrouted,
        warning: messages.isEmpty ? null : messages.join('\n'));
    return json['status'] == 'stale'
        ? plan.asStale('Los pedidos cambiaron.')
        : plan;
  }
}
