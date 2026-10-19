import 'package:delivery_app/features/routing/delivery_routing_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
