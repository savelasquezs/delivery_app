import 'package:flutter/material.dart';
import 'delivery_routing_models.dart';
import 'helpers/route_editor_helpers.dart';

class RouteTimingSummary extends StatelessWidget {
  final DeliveryRouteProposal proposal;

  const RouteTimingSummary({super.key, required this.proposal});

  String _line(String label, int meters, int seconds, DateTime? arrival,
      {required bool approximate}) {
    final prefix = approximate ? '~' : '';
    final time = arrival == null
        ? ''
        : ' (${routeArrivalLabel(arrival, proposal.expectedDepartureAtUtc)})';
    return '$label: $prefix${routeDistanceLabel(meters)} · '
        '${routeDurationLabel(seconds)}$time';
  }

  @override
  Widget build(BuildContext context) {
    final totalDistance = proposal.roundTripDistanceMeters;
    final totalSeconds = proposal.roundTripElapsedSeconds;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_line('Última entrega', proposal.distanceMeters,
          proposal.deliveryElapsedSeconds, proposal.deliveryCompletedAtUtc,
          approximate: proposal.usesApproximateMetrics)),
      const SizedBox(height: 4),
      Text(totalDistance == null || totalSeconds == null
          ? 'Regreso sucursal: estimación no disponible.'
          : _line('Regreso sucursal (total)', totalDistance, totalSeconds,
              proposal.returnedToBranchAtUtc,
              approximate: proposal.usesApproximateMetrics ||
                  proposal.usesApproximateReturnMetrics)),
      const SizedBox(height: 4),
      const Text('Desde la salida, incluidas las paradas de entrega.',
          style: TextStyle(fontSize: 12)),
    ]);
  }
}
