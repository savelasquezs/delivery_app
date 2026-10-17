import 'package:flutter_test/flutter_test.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:delivery_app/features/routing/delivery_routing_models.dart';
import 'routing_plan_validity_test.dart' as fixture;

void main() {
  test('an unrelated delivered order does not invalidate the current plan', () async {
    var requests = 0;
    final n = fixture.notifier(fixture.Routes(() async {
      requests++;
      return fixture.plan();
    }));
    addTearDown(n.dispose);
    await n.loadRouting();
    final current = n.state.routingPlan;
    await n.reconcileRoutingOrder(Order(id: 999, status: OrderStatus.delivered,
      type: 'delivery', createdAt: DateTime.now(), total: 1000, items: const [], deliveryManId: 7));
    expect(identical(n.state.routingPlan, current), isTrue);
    expect(n.state.routingPlan!.isStale, isFalse);
    expect(requests, 1);
  });

  testWidgets('expiry marks a plan stale without any periodic HTTP request', (tester) async {
    var requests = 0;
    final base = fixture.plan();
    final n = fixture.notifier(fixture.Routes(() async {
      requests++;
      return DeliveryRoutingPlan(id: base.id, version: base.version,
        availableNow: base.availableNow, availableSoon: base.availableSoon,
        proposals: base.proposals, unroutedOrders: base.unroutedOrders,
        warning: null, generatedAtUtc: DateTime.now().toUtc());
    }));
    await n.loadRouting();
    expect(n.state.routingPlan!.isStale, isFalse);
    await tester.pump(const Duration(minutes: 2));
    expect(n.state.routingPlan!.isStale, isTrue);
    expect(n.state.routingPlan!.proposals.single.isClaimable, isFalse);
    expect(requests, 1);
    n.dispose();
  });
}
