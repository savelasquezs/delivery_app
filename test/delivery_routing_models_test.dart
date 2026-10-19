import 'package:delivery_app/features/routing/delivery_routing_models.dart';
import 'package:delivery_app/features/routing/helpers/route_editor_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('totales incluyen todas las paradas y el regreso una sola vez', () {
    final proposal = DeliveryRouteProposal.fromJson({
      'id': 1,
      'sequence': 1,
      'expectedDepartureAtUtc': '2026-10-18T23:50:00-05:00',
      'waitSeconds': 600,
      'approximateDrivingDurationSeconds': 600,
      'approximateDistanceMeters': 3200,
      'validatedDrivingDurationSeconds': 540,
      'validatedDistanceMeters': 3000,
      'returnDrivingDurationSeconds': 900,
      'returnDistanceMeters': 2000,
      'usesApproximateReturnMetrics': true,
      'stops': [
        for (final id in [1, 2])
          {
            'orderId': id,
            'estimatedReadyAtUtc': '2026-10-19T04:40:00Z',
            'serviceSeconds': 120,
          }
      ],
    });
    expect(proposal.deliveryElapsedSeconds, 780);
    expect(proposal.roundTripElapsedSeconds, 1680);
    expect(proposal.roundTripDistanceMeters, 5000);
    expect(proposal.deliveryCompletedAtUtc, DateTime.utc(2026, 10, 19, 5, 3));
    expect(proposal.returnedToBranchAtUtc, DateTime.utc(2026, 10, 19, 5, 18));
    expect(proposal.usesApproximateMetrics, isFalse);
    expect(proposal.usesApproximateReturnMetrics, isTrue);
    expect(proposal.asStale({1}).returnedToBranchAtUtc, isNull);
    expect(proposal.asStale({1}).roundTripDistanceMeters, isNull);
  });

  test('contratos anteriores no inventan un regreso ni una hora', () {
    final proposal = DeliveryRouteProposal.fromJson({'id': 1, 'sequence': 1});
    expect(proposal.roundTripElapsedSeconds, isNull);
    expect(proposal.roundTripDistanceMeters, isNull);
    expect(proposal.deliveryCompletedAtUtc, isNull);
    expect(proposal.returnedToBranchAtUtc, isNull);
  });

  test('formato de recorrido maneja horas, redondeo y cambio de día', () {
    expect(routeDurationLabel(1), '1 min');
    expect(routeDurationLabel(0), '0 min');
    expect(routeDurationLabel(3599), '1 h');
    expect(routeDurationLabel(9120), '2 h y 32 min');
    expect(routeDistanceLabel(105000), '105,0 km');
    expect(routeArrivalLabel(DateTime(2026, 10, 18, 15, 18), null),
        '3:18 p. m. aprox.');
    expect(
        routeArrivalLabel(
            DateTime(2026, 10, 19, 0, 18), DateTime(2026, 10, 18, 23, 50)),
        '12:18 a. m. aprox. · +1 día');
    expect(
        routeArrivalLabel(
            DateTime(2026, 10, 20, 12), DateTime(2026, 10, 18, 23, 50)),
        '12:00 p. m. aprox. · +2 días');
  });

  test('muestra la excepción calculada sin aplicarla a los demás pedidos', () {
    final normal = DeliveryRoutingStop.fromJson({
      'orderId': 1,
      'estimatedReadyAtUtc': '2026-10-18T17:00:00Z',
    });
    final distant = DeliveryRoutingStop.fromJson({
      'orderId': 2,
      'estimatedReadyAtUtc': '2026-10-18T17:00:00Z',
      'deliveryTimeLimitSeconds': 4034,
    });
    expect(normal.exceptionLabel, isNull);
    expect(distant.exceptionLabel, contains('automática'));
    expect(distant.exceptionLabel, contains('68 min'));
  });
  test('parsea plan, propuesta, capacidad y pedidos sin ruta', () {
    final plan = DeliveryRoutingPlan.fromJson({
      'id': 3,
      'version': 8,
      'capacity': {'availableNow': 2, 'availableSoon': 1},
      'warnings': null,
      'proposals': [
        {
          'id': 7,
          'sequence': 1,
          'recommendation': 'leaveNow',
          'approximateDrivingDurationSeconds': 600,
          'approximateDistanceMeters': 3200,
          'validatedDrivingDurationSeconds': 540,
          'lastDeliverySeconds': 1140,
          'validatedDistanceMeters': 3000,
          'isClaimable': true,
          'claimableReadyOrderIds': [10],
          'planningWarnings': null,
          'stops': [
            {
              'orderId': 10,
              'stopSequence': 1,
              'address': 'Calle 1',
              'neighborhood': 'Centro',
              'estimatedReadyAtUtc': '2026-08-10T17:00:00Z',
              'isReady': true,
              'unroutedReason': null,
            }
          ],
        }
      ],
      'unroutedOrders': [
        {
          'orderId': 11,
          'stopSequence': null,
          'address': '',
          'neighborhood': null,
          'estimatedReadyAtUtc': '2026-08-10T17:05:00Z',
          'isReady': false,
          'unroutedReason': 'requiresLocation',
        }
      ],
    });

    expect(plan.version, 8);
    expect(plan.availableNow, 2);
    expect(plan.proposals.single.durationSeconds, 540);
    expect(plan.proposals.single.lastDeliverySeconds, 1140);
    expect(plan.proposals.single.timingLabel,
        '~19 min hasta última entrega · 9 min de conducción');
    expect(plan.proposals.single.asStale({}).lastDeliverySeconds, 1140);
    expect(plan.proposals.single.claimableReadyOrderIds, [10]);
    expect(plan.unroutedOrders.single.unroutedReason, 'requiresLocation');
    expect(plan.warning, isNull);
    expect(plan.proposedOrderCount, 1);
    expect(plan.totalOrderCount, 2);
    expect(plan.proposedReadyCount, 1);
    expect(plan.totalReadyCount, 1);
    expect(plan.proposals.single.usesApproximateMetrics, isFalse);
  });

  test('los pendientes no se presentan como rutas imposibles', () {
    final stop = DeliveryRoutingStop.fromJson({
      'orderId': 12,
      'estimatedReadyAtUtc': '2026-10-17T17:00:00Z',
      'unroutedReason': 'notSelectedByOptimizer',
    });
    expect(stop.reasonLabel, contains('costo de recorrido'));
    expect(stop.reasonLabel, isNot(contains('factible')));
  });

  test('informa por qué disminuye la capacidad cuando vence el GPS', () {
    final plan = DeliveryRoutingPlan.fromJson({
      'id': 1,
      'version': 1,
      'capacity': {
        'availableNow': 1,
        'availableSoon': 0,
        'couriers': [
          {'workSessionId': 3, 'state': 'unknown'},
          {'workSessionId': 4, 'state': 'unknown'},
          {'workSessionId': 0, 'state': 'offDuty'},
        ]
      },
      'proposals': [],
      'unroutedOrders': [],
    });
    expect(plan.warning, startsWith('2 domiciliario(s) sin GPS reciente'));
  });

  test('explica los límites de tiempo sin confundirlos con falta de conductor',
      () {
    final stop = DeliveryRoutingStop.fromJson({
      'orderId': 34,
      'estimatedReadyAtUtc': '2026-10-18T17:00:00Z',
      'unroutedReason': 'deliveryTimeLimit',
    });
    expect(stop.reasonLabel, 'supera el tiempo máximo desde la sucursal');
  });
}
