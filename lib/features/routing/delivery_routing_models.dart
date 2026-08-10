class DeliveryRoutingStop {
  final int orderId;
  final int? sequence;
  final String address;
  final String? neighborhood;
  final DateTime estimatedReadyAtUtc;
  final bool isReady;
  final String? unroutedReason;

  const DeliveryRoutingStop({
    required this.orderId,
    required this.sequence,
    required this.address,
    required this.neighborhood,
    required this.estimatedReadyAtUtc,
    required this.isReady,
    required this.unroutedReason,
  });

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
      );
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

  const DeliveryRouteProposal({
    required this.id,
    required this.sequence,
    required this.recommendation,
    required this.durationSeconds,
    required this.distanceMeters,
    required this.isClaimable,
    required this.claimableReadyOrderIds,
    required this.stops,
    required this.warning,
  });

  factory DeliveryRouteProposal.fromJson(Map<String, dynamic> json) =>
      DeliveryRouteProposal(
        id: json['id'] as int,
        sequence: json['sequence'] as int,
        recommendation: json['recommendation'] as String? ?? '',
        durationSeconds: (json['validatedDrivingDurationSeconds'] ??
            json['approximateDrivingDurationSeconds'] ??
            0) as int,
        distanceMeters: (json['validatedDistanceMeters'] ??
            json['approximateDistanceMeters'] ??
            0) as int,
        isClaimable: json['isClaimable'] as bool? ?? false,
        claimableReadyOrderIds:
            (json['claimableReadyOrderIds'] as List? ?? const [])
                .map((value) => value as int)
                .toList(),
        stops: (json['stops'] as List? ?? const [])
            .map((value) => DeliveryRoutingStop.fromJson(
                Map<String, dynamic>.from(value as Map)))
            .toList(),
        warning: json['planningWarnings'] as String?,
      );
}

class DeliveryRoutingPlan {
  final int id;
  final int version;
  final int availableNow;
  final int availableSoon;
  final List<DeliveryRouteProposal> proposals;
  final List<DeliveryRoutingStop> unroutedOrders;
  final String? warning;

  const DeliveryRoutingPlan({
    required this.id,
    required this.version,
    required this.availableNow,
    required this.availableSoon,
    required this.proposals,
    required this.unroutedOrders,
    required this.warning,
  });

  factory DeliveryRoutingPlan.fromJson(Map<String, dynamic> json) {
    final capacity = Map<String, dynamic>.from(json['capacity'] as Map? ?? {});
    return DeliveryRoutingPlan(
      id: json['id'] as int,
      version: json['version'] as int,
      availableNow: capacity['availableNow'] as int? ?? 0,
      availableSoon: capacity['availableSoon'] as int? ?? 0,
      proposals: (json['proposals'] as List? ?? const [])
          .map((value) => DeliveryRouteProposal.fromJson(
              Map<String, dynamic>.from(value as Map)))
          .toList(),
      unroutedOrders: (json['unroutedOrders'] as List? ?? const [])
          .map((value) => DeliveryRoutingStop.fromJson(
              Map<String, dynamic>.from(value as Map)))
          .toList(),
      warning: json['warnings'] as String?,
    );
  }
}
