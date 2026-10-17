import 'dart:async';
import 'package:delivery_app/features/available/data/branch_presence_verifier.dart';
import 'package:delivery_app/features/available/presentation/available_notifier.dart';
import 'package:delivery_app/features/available/presentation/available_screen.dart';
import 'package:delivery_app/features/orders/data/order_repository.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:delivery_app/features/routing/delivery_routing_models.dart';
import 'package:delivery_app/features/routing/delivery_routing_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DeliveryRoutingStop stop(int id) => DeliveryRoutingStop(orderId: id, sequence: 1,
  address: 'Destino', neighborhood: 'Barrio', estimatedReadyAtUtc: DateTime.utc(2026, 10, 16),
  isReady: true, unroutedReason: 'noCapacity');
DeliveryRoutingPlan plan({bool empty = false}) => DeliveryRoutingPlan(id: 1, version: 1,
  availableNow: 1, availableSoon: 0, warning: null,
  proposals: empty ? [] : [DeliveryRouteProposal(id: 10, sequence: 1,
    recommendation: 'leaveNow', durationSeconds: 300, distanceMeters: 500, isClaimable: true,
    claimableReadyOrderIds: [21], stops: [stop(21)], warning: null)], unroutedOrders: [stop(22)]);
class Orders extends Fake implements OrderRepository {
  @override
  Future<List<Order>> getAvailableOrders({int? branchId}) async => [];
}
class Presence extends Fake implements BranchPresenceVerifier {}
class Routes extends Fake implements DeliveryRoutingRepository {
  Routes(this.read);
  final Future<DeliveryRoutingPlan> Function() read;
  @override
  Future<DeliveryRoutingPlan> getPlan() => read();
}
AvailableNotifier notifier(Routes repository) => AvailableNotifier(Orders(), Presence(), repository, null, null, null, 50);

void main() {
  test('removes orders from proposals and unrouted without retaining claim ids', () async {
    final n = notifier(Routes(() async => plan()));
    addTearDown(n.dispose);
    await n.loadRouting();
    n.removeOrders([21, 22]);
    expect(n.state.routingPlan!.proposals, isEmpty);
    expect(n.state.routingPlan!.unroutedOrders, isEmpty);
    expect(n.state.routingPlan!.isStale, isTrue);
  });

  test('silent refresh failure cannot leave an apparently valid claimable plan', () async {
    var fail = false;
    final n = notifier(Routes(() async {
      if (fail) throw StateError('Servidor no disponible');
      return plan();
    }));
    addTearDown(n.dispose);
    await n.loadRouting();
    fail = true;
    await n.loadRouting(silently: true);
    expect(n.state.errorRouting, isNotNull);
    expect(n.state.routingPlan!.isStale, isTrue);
    expect(n.state.routingPlan!.warning, contains('Plan desactualizado'));
    expect(n.state.routingPlan!.proposals.single.isClaimable, isFalse);
    await expectLater(n.selfAssign(orderIds: [21], proposalId: 10, expectedPlanVersion: 1), throwsStateError);
  });

  test('late HTTP result cannot resurrect an order removed by SignalR', () async {
    final first = Completer<DeliveryRoutingPlan>();
    var calls = 0;
    final n = notifier(Routes(() {
      calls++;
      return calls == 1 ? first.future : Future.value(plan(empty: true));
    }));
    addTearDown(n.dispose);
    final load = n.loadRouting();
    n.removeOrders([21]);
    first.complete(plan());
    await load;
    expect(calls, 2);
    expect(n.state.routingPlan!.containsOrder(21), isFalse);
  });

  testWidgets('existing route screen displays stale warning and hides taking a stale proposal', (tester) async {
    final n = notifier(Routes(() async => plan()));
    await tester.pumpWidget(ProviderScope(overrides: [availableNotifierProvider.overrideWith((ref) => n)],
      child: const MaterialApp(home: AvailableScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rutas'));
    await tester.pumpAndSettle();
    expect(find.text('Tomar 1 listo(s)'), findsOneWidget);
    n.invalidateRouting('Falló la actualización.');
    await tester.pumpAndSettle();
    expect(find.textContaining('Plan desactualizado.'), findsOneWidget);
    expect(find.text('Tomar 1 listo(s)'), findsNothing);
    expect(find.text('Disponibles'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
