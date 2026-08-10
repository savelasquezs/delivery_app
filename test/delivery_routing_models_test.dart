import 'package:delivery_app/features/routing/delivery_routing_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(plan.proposals.single.claimableReadyOrderIds, [10]);
    expect(plan.unroutedOrders.single.unroutedReason, 'requiresLocation');
  });
}
