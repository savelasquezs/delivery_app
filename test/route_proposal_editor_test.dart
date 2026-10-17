import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:delivery_app/core/theme/app_theme.dart';
import 'package:delivery_app/features/available/data/branch_presence_verifier.dart';
import 'package:delivery_app/features/available/presentation/available_notifier.dart';
import 'package:delivery_app/features/orders/data/order_repository.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:delivery_app/features/routing/delivery_routing_models.dart';
import 'package:delivery_app/features/routing/delivery_routing_repository.dart';
import 'package:delivery_app/features/routing/route_proposal_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'routing_plan_validity_test.dart' as fixture;

class _Orders extends Fake implements OrderRepository {
  List<int>? accepted;
  String? fingerprint;
  @override
  Future<List<Order>> getAvailableOrders({int? branchId}) async => [
        for (final id in [21, 22])
          Order(
              id: id,
              status: OrderStatus.ready,
              type: 'delivery',
              createdAt: DateTime.now(),
              total: 1000,
              items: const [],
              branchId: 1,
              neighborhoodName: 'Barrio')
      ];
  @override
  Future<List<Order>> selfAssignOrders(
      {required List<int> orderIds,
      int? proposalId,
      int? expectedPlanVersion,
      bool modifiedProposal = false,
      String? selectionFingerprint}) async {
    expect(modifiedProposal, isTrue);
    expect(proposalId, 10);
    expect(expectedPlanVersion, 1);
    accepted = orderIds;
    fingerprint = selectionFingerprint;
    return [
      Order(
          id: orderIds.single,
          status: OrderStatus.onTheWay,
          type: 'delivery',
          createdAt: DateTime.now(),
          total: 1000,
          items: const [],
          branchId: 1)
    ];
  }
}

class _Routes extends Fake implements DeliveryRoutingRepository {
  List<int>? previewed;
  Completer<DeliveryRouteProposal>? pending;
  @override
  Future<DeliveryRoutingPlan> getPlan() async => fixture.plan();
  @override
  Future<DeliveryRouteProposal> preview(List<int> orderIds, int version) async {
    previewed = orderIds;
    if (pending != null) return pending!.future;
    return previewResult();
  }

  DeliveryRouteProposal previewResult() => DeliveryRouteProposal(
      id: 0,
      sequence: 0,
      recommendation: 'leaveNow',
      durationSeconds: 400,
      distanceMeters: 1000,
      isClaimable: true,
      claimableReadyOrderIds: previewed ?? [],
      stops: const [],
      warning: null,
      selectionFingerprint: 'verified-selection');
}

class _Presence extends Fake implements BranchPresenceVerifier {}

void main() {
  setUpAll(() async {
    final config = File('.dart_tool/package_config.json');
    final packages =
        jsonDecode(await config.readAsString())['packages'] as List;
    final flutter =
        packages.cast<Map>().singleWhere((p) => p['name'] == 'flutter');
    final root = Directory.fromUri(
            config.absolute.uri.resolve(flutter['rootUri'] as String))
        .uri;
    final font = File.fromUri(root.resolve(
        '../../bin/cache/artifacts/material_fonts/roboto-regular.ttf'));
    final loader = FontLoader('Roboto')
      ..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())));
    await loader.load();
    await (FontLoader('Ahem')
          ..addFont(
              Future.value(ByteData.sublistView(await font.readAsBytes()))))
        .load();
    final icons = File.fromUri(root.resolve(
        '../../bin/cache/artifacts/material_fonts/materialicons-regular.otf'));
    await (FontLoader('MaterialIcons')
          ..addFont(
              Future.value(ByteData.sublistView(await icons.readAsBytes()))))
        .load();
  });
  testWidgets(
      'mobile editor removes, adds, previews and confirms the selected ready orders',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final orders = _Orders();
    final routes = _Routes();
    final n =
        AvailableNotifier(orders, _Presence(), routes, null, null, null, 50);
    await n.loadRouting();
    await n.load();
    await tester.pumpWidget(ProviderScope(
        overrides: [availableNotifierProvider.overrideWith((ref) => n)],
        child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => showModalBottomSheet<List<Order>>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => RouteProposalEditor(
                                proposal: fixture.plan().proposals.single,
                                version: 1)),
                        child: const Text('Editar')))))));
    await tester.tap(find.text('Editar'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(RouteProposalEditor),
        matchesGoldenFile('goldens/route_proposal_editor_390.png'));
    await tester.tap(find.byTooltip('Quitar pedido'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#22 · Barrio').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Actualizar estimación'));
    await tester.pumpAndSettle();
    expect(routes.previewed, [22]);
    await tester.tap(find.text('Aceptar ruta y salir con estos pedidos'));
    await tester.pumpAndSettle();
    expect(orders.accepted, [22]);
    expect(orders.fingerprint, 'verified-selection');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('SignalR invalidation rejects an in-flight edit preview', () async {
    final routes = _Routes()..pending = Completer<DeliveryRouteProposal>();
    final n =
        AvailableNotifier(_Orders(), _Presence(), routes, null, null, null, 50);
    addTearDown(n.dispose);
    await n.loadRouting();
    final result = n.previewRouting([21], 1);
    final assertion = expectLater(result, throwsStateError);
    n.invalidateRouting('Cambió desde otro dispositivo.');
    routes.pending!.complete(routes.previewResult());
    await assertion;
  });
}
