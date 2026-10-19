import 'dart:async';

import 'package:delivery_app/core/api/api_exception.dart';
import 'package:delivery_app/features/realtime/order_hub_event.dart';
import 'package:delivery_app/features/routing/delivery_routing_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'routing_plan_validity_test.dart' as fixture;

DeliveryRoutingPlan plan(int version, {DateTime? expires}) {
  final base = fixture.plan();
  return DeliveryRoutingPlan(
    id: version,
    version: version,
    availableNow: base.availableNow,
    availableSoon: base.availableSoon,
    proposals: base.proposals,
    unroutedOrders: base.unroutedOrders,
    warning: null,
    expiresAtUtc: expires,
  );
}

void main() {
  test(
      'the notification sent before its HTTP response does not discard that response',
      () async {
    final response = Completer<DeliveryRoutingPlan>();
    var calls = 0;
    final n = fixture.notifier(fixture.Routes(() {
      calls++;
      return response.future;
    }));
    addTearDown(n.dispose);
    final loading = n.loadRouting();
    final event = n.routingPlanChanged(2);
    response.complete(plan(2));
    await Future.wait([loading, event]);
    expect(calls, 1);
    expect(n.state.routingPlan!.version, 2);
    expect(n.state.routingPlan!.isStale, isFalse);
    expect(n.state.isLoadingRouting, isFalse);
  });

  for (final size in [20, 30]) {
    test('$size concurrent notifications are satisfied by one current response',
        () async {
      final response = Completer<DeliveryRoutingPlan>();
      var calls = 0;
      final n = fixture.notifier(fixture.Routes(() {
        calls++;
        return response.future;
      }));
      addTearDown(n.dispose);
      final requests = [n.loadRouting()];
      for (var version = 1; version <= size; version++) {
        requests.add(n.routingPlanChanged(version));
      }
      response.complete(plan(size));
      await Future.wait(requests);
      expect(calls, 1);
      expect(n.state.routingPlan!.version, size);
      expect(n.state.routingPlan!.isStale, isFalse);
    });
  }

  test(
      'duplicates and old versions do not invalidate or fetch the current plan',
      () async {
    var calls = 0;
    final n = fixture.notifier(fixture.Routes(() async {
      calls++;
      return plan(3);
    }));
    addTearDown(n.dispose);
    await n.loadRouting();
    final current = n.state.routingPlan;
    await n.routingPlanChanged(3);
    await n.routingPlanChanged(2);
    expect(identical(current, n.state.routingPlan), isTrue);
    expect(calls, 1);
  });

  test('a newer announcement during HTTP fetch queues one catch-up response',
      () async {
    final first = Completer<DeliveryRoutingPlan>();
    var calls = 0;
    final n = fixture.notifier(fixture.Routes(
        () => ++calls == 1 ? first.future : Future.value(plan(4))));
    addTearDown(n.dispose);
    final loading = n.loadRouting();
    unawaited(n.routingPlanChanged(4));
    first.complete(plan(3));
    await loading;
    expect(calls, 2);
    expect(n.state.routingPlan!.version, 4);
    expect(n.state.routingPlan!.isStale, isFalse);
  });

  testWidgets('a lagging server cannot keep the loading future running forever',
      (tester) async {
    var calls = 0;
    final n = fixture.notifier(fixture.Routes(() async {
      calls++;
      return plan(1);
    }));
    await n.routingPlanChanged(4);
    expect(calls, 2);
    expect(n.state.isLoadingRouting, isFalse);
    for (final seconds in [1, 2, 4]) {
      await tester.pump(Duration(seconds: seconds));
    }
    expect(calls, 8);
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 8);
    expect(n.state.errorRouting, isNotNull);
    n.dispose();
  });

  testWidgets('server expiry renews the recommendation automatically',
      (tester) async {
    var calls = 0;
    final n = fixture.notifier(fixture.Routes(() async => plan(++calls,
        expires: DateTime.now().toUtc().add(const Duration(seconds: 30)))));
    await n.loadRouting();
    await tester.pump(const Duration(seconds: 31));
    expect(calls, 2);
    expect(n.state.routingPlan!.isStale, isFalse);
    n.dispose();
  });

  testWidgets(
      'transient errors retry at 1, 2 and 4 seconds then stop; manual retry recovers',
      (tester) async {
    var calls = 0;
    var fail = true;
    final n = fixture.notifier(fixture.Routes(() async {
      calls++;
      if (fail) {
        throw const ApiException('Servidor no disponible', statusCode: 503);
      }
      return plan(2);
    }));
    await n.loadRouting();
    expect(calls, 1);
    await tester.pump(const Duration(milliseconds: 999));
    expect(calls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 3);
    await tester.pump(const Duration(seconds: 4));
    expect(calls, 4);
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 4);
    expect(n.state.isLoadingRouting, isFalse);
    fail = false;
    await n.loadRouting();
    expect(n.state.errorRouting, isNull);
    expect(n.state.routingPlan!.isStale, isFalse);
    n.dispose();
  });

  testWidgets('authorization errors do not retry', (tester) async {
    var calls = 0;
    final n = fixture.notifier(fixture.Routes(() async {
      calls++;
      throw const ApiException('Sin permiso', statusCode: 403);
    }));
    await n.loadRouting();
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 1);
    n.dispose();
  });

  testWidgets(
      'background suspends expiry and foreground catches up automatically',
      (tester) async {
    var calls = 0;
    final n = fixture.notifier(fixture.Routes(() async => plan(++calls,
        expires: DateTime.now().toUtc().add(const Duration(seconds: 30)))));
    await n.loadRouting();
    n.setRoutingActive(false);
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 1);
    n.setRoutingActive(true);
    await tester.pump();
    expect(calls, 2);
    n.dispose();
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 2);
  });

  testWidgets('background cancels pending retries', (tester) async {
    var calls = 0;
    final n = fixture.notifier(fixture.Routes(() async {
      calls++;
      throw const ApiException('Sin servicio', statusCode: 503);
    }));
    await n.loadRouting();
    n.setRoutingActive(false);
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 1);
    n.dispose();
  });

  test('expiry is additive and old servers keep the two-minute fallback', () {
    final base = {
      'id': 1,
      'version': 1,
      'generatedAtUtc': '2026-10-19T18:00:00Z'
    };
    expect(DeliveryRoutingPlan.fromJson(base).effectiveExpiresAtUtc,
        DateTime.utc(2026, 10, 19, 18, 2));
    final explicit = DeliveryRoutingPlan.fromJson(
        {...base, 'expiresAtUtc': '2026-10-19T18:00:30Z'});
    expect(
        explicit.effectiveExpiresAtUtc, DateTime.utc(2026, 10, 19, 18, 0, 30));
    expect(explicit.asStale('Cambio').expiresAtUtc, explicit.expiresAtUtc);
  });

  test(
      'SignalR parses valid versions and keeps unversioned claim events separate',
      () {
    expect(
        routingPlanVersionFromHubEvent(deliveryRoutingPlanChangedHubEvent, [
          {'version': 2}
        ]),
        2);
    expect(
        routingPlanVersionFromHubEvent(deliveryRoutingPlanChangedHubEvent, [
          {'Version': 3}
        ]),
        3);
    expect(
        routingPlanVersionFromHubEvent(deliveryRoutingPlanChangedHubEvent, [
          {'version': 'oops'}
        ]),
        isNull);
    expect(
        routingPlanVersionFromHubEvent(routeProposalClaimedHubEvent, [
          {'version': 2}
        ]),
        isNull);
  });
}
