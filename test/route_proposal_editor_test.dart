import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:delivery_app/core/theme/app_theme.dart';
import 'package:delivery_app/features/available/data/branch_presence_verifier.dart';
import 'package:delivery_app/features/available/presentation/available_notifier.dart';
import 'package:delivery_app/features/orders/data/order_repository.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:delivery_app/features/routing/delivery_routing_models.dart';
import 'package:delivery_app/features/routing/delivery_routing_repository.dart';
import 'package:delivery_app/features/routing/helpers/route_editor_helpers.dart';
import 'package:delivery_app/features/routing/route_proposal_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DeliveryRoutingStop _stop(int id, {bool ready = true, DateTime? arrival}) =>
    DeliveryRoutingStop(
        orderId: id,
        sequence: 1,
        address: 'Calle $id #10-20',
        neighborhood: 'Castilla',
        estimatedReadyAtUtc: DateTime.utc(2026, 10, 18, 17),
        estimatedArrivalAtUtc: arrival ?? DateTime.utc(2026, 10, 18, 17, id),
        serviceSeconds: 120,
        isReady: ready,
        unroutedReason: null);

DeliveryRoutingPlan _plan() => DeliveryRoutingPlan(
        id: 1,
        version: 1,
        availableNow: 2,
        availableSoon: 0,
        warning: null,
        proposals: [
          DeliveryRouteProposal(
              id: 10,
              sequence: 1,
              recommendation: 'leaveNow',
              durationSeconds: 300,
              distanceMeters: 500,
              isClaimable: true,
              claimableReadyOrderIds: [21, 23],
              stops: [_stop(21), _stop(23)],
              warning: null),
          DeliveryRouteProposal(
              id: 20,
              sequence: 2,
              recommendation: 'leaveNow',
              durationSeconds: 300,
              distanceMeters: 500,
              isClaimable: true,
              claimableReadyOrderIds: [24],
              stops: [_stop(24), _stop(25, ready: false)],
              warning: null),
        ],
        unroutedOrders: [
          _stop(22)
        ]);

class _Orders extends Fake implements OrderRepository {
  List<int>? accepted;
  String? fingerprint;
  @override
  Future<List<Order>> getAvailableOrders({int? branchId, CancelToken? cancelToken}) async => [
        for (final id in [21, 22, 23])
          Order(
              id: id,
              status: OrderStatus.ready,
              type: 'delivery',
              createdAt: DateTime.utc(2026, 10, 18),
              total: 1000,
              items: const [],
              branchId: 1,
              addressDescription: 'Calle $id #10-20',
              neighborhoodName: 'Castilla')
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
    accepted = List.of(orderIds);
    fingerprint = selectionFingerprint;
    return [
      for (final id in orderIds)
        Order(
            id: id,
            status: OrderStatus.onTheWay,
            type: 'delivery',
            createdAt: DateTime.utc(2026, 10, 18),
            total: 1000,
            items: const [],
            branchId: 1)
    ];
  }
}

class _Routes extends Fake implements DeliveryRoutingRepository {
  final calls = <List<int>>[];
  final pending = <Completer<DeliveryRouteProposal>>[];
  bool holdPreviews = false;
  Object? error;
  @override
  Future<DeliveryRoutingPlan> getPlan() async => _plan();
  @override
  Future<DeliveryRouteProposal> preview(List<int> orderIds, int version) async {
    calls.add(List.of(orderIds));
    if (error != null) throw error!;
    if (holdPreviews) {
      final completer = Completer<DeliveryRouteProposal>();
      pending.add(completer);
      return completer.future;
    }
    return previewResult(orderIds);
  }

  DeliveryRouteProposal previewResult(List<int> ids, {String? fingerprint}) =>
      DeliveryRouteProposal(
          id: 0,
          sequence: 0,
          recommendation: 'leaveNow',
          durationSeconds: 400,
          lastDeliverySeconds: 600,
          distanceMeters: 1000,
          expectedDepartureAtUtc: DateTime.utc(2026, 10, 18, 17),
          returnDrivingDurationSeconds: ids.last == 23 ? 180 : 300,
          returnDistanceMeters: ids.last == 23 ? 600 : 1000,
          isClaimable: true,
          claimableReadyOrderIds: ids,
          stops: ids.indexed
              .map((entry) => _stop(entry.$2,
                  arrival: DateTime.utc(2026, 10, 18, 17).add(Duration(
                      seconds: (entry.$1 + 1) * 400 ~/ ids.length +
                          entry.$1 * 120))))
              .toList(),
          warning: null,
          selectionFingerprint: fingerprint ?? 'selection-${ids.join('-')}');
}

class _Presence extends Fake implements BranchPresenceVerifier {}

Future<AvailableNotifier> _mount(
    WidgetTester tester, _Orders orders, _Routes routes,
    {Future<bool> Function()? canBeginDelivery, double scale = 1}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final notifier = AvailableNotifier(
      orders, _Presence(), routes, null, null, null, 50,
      canBeginDelivery: canBeginDelivery);
  await notifier.loadRouting();
  await notifier.load();
  await tester.pumpWidget(ProviderScope(
      overrides: [availableNotifierProvider.overrideWith((ref) => notifier)],
      child: MaterialApp(
          theme: AppTheme.darkTheme.copyWith(
              outlinedButtonTheme: OutlinedButtonThemeData(
                  style: AppTheme.darkTheme.outlinedButtonTheme.style?.copyWith(
                      textStyle: WidgetStatePropertyAll(
                          AppTheme.darkTheme.textTheme.labelLarge)))),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(
              body: Builder(
                  builder: (context) =>
                      TextButton(onPressed: () => showModalBottomSheet<List<Order>>(context: context, isScrollControlled: true, builder: (_) => RouteProposalEditor(proposal: _plan().proposals.first, version: 1)), child: const Text('Editar')))))));
  await tester.tap(find.text('Editar'));
  if (routes.holdPreviews) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  } else {
    await tester.pumpAndSettle();
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
  });
  return notifier;
}

Finder get _accept =>
    find.widgetWithText(FilledButton, 'Aceptar ruta y salir con estos pedidos');
bool _canAccept(WidgetTester tester) =>
    tester.widget<FilledButton>(_accept).onPressed != null;
Future<void> _remove(WidgetTester tester, int id, {bool confirm = true}) async {
  await tester.tap(find.descendant(
      of: find.byKey(ValueKey('selected-order-$id')),
      matching: find.byTooltip('Quitar pedido')));
  await tester.pumpAndSettle();
  expect(find.text('¿Quitar este pedido?'), findsOneWidget);
  await tester.tap(find.widgetWithText(
      confirm ? FilledButton : TextButton, confirm ? 'Quitar' : 'Cancelar'));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, int id) async {
  await tester.tap(find.text('Añadir pedido'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('add-order-$id')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final config = File('.dart_tool/package_config.json');
    final packages =
        jsonDecode(await config.readAsString())['packages'] as List;
    final flutter = packages
        .cast<Map>()
        .singleWhere((package) => package['name'] == 'flutter');
    final root = Directory.fromUri(
            config.absolute.uri.resolve(flutter['rootUri'] as String))
        .uri;
    final font = await File.fromUri(root.resolve(
            '../../bin/cache/artifacts/material_fonts/Roboto-Regular.ttf'))
        .readAsBytes();
    for (final family in ['Roboto', 'Ahem']) {
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.sublistView(font))))
          .load();
    }
    final icons = await File.fromUri(root.resolve(
            '../../bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'))
        .readAsBytes();
    await (FontLoader('MaterialIcons')
          ..addFont(Future.value(ByteData.sublistView(icons))))
        .load();
  });

  testWidgets('opens with addresses, automatic estimate and enabled acceptance',
      (tester) async {
    final routes = _Routes();
    await _mount(tester, _Orders(), routes);
    expect(routes.calls, [
      [21, 23]
    ]);
    expect(find.text('Calle 21 #10-20'), findsOneWidget);
    expect(find.textContaining('Castilla · Pedido #21'), findsOneWidget);
    expect(find.text('Actualizar estimación'), findsNothing);
    expect(find.textContaining('Última entrega: ~1,0 km · 11 min'),
        findsOneWidget);
    expect(find.textContaining('Regreso sucursal (total): ~1,6 km · 14 min'),
        findsOneWidget);
    expect(_canAccept(tester), isTrue);
    expect(
        tester.getSize(find.byType(RouteProposalEditor)).height, lessThan(750));
    await expectLater(
        find.byType(RouteProposalEditor),
        matchesGoldenFile(
            'goldens/route_proposal_editor_390${Platform.isLinux ? '_linux' : ''}.png'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'removal requires confirmation and recalculates only when confirmed',
      (tester) async {
    final routes = _Routes();
    await _mount(tester, _Orders(), routes);
    await _remove(tester, 21, confirm: false);
    expect(find.byKey(const ValueKey('selected-order-21')), findsOneWidget);
    expect(routes.calls.length, 1);
    await _remove(tester, 21);
    expect(find.byKey(const ValueKey('selected-order-21')), findsNothing);
    expect(routes.calls.last, [23]);
    expect(
        find.textContaining('Última entrega: ~1,0 km · 9 min'), findsOneWidget);
    expect(find.textContaining('Regreso sucursal (total): ~1,6 km · 12 min'),
        findsOneWidget);
    expect(_canAccept(tester), isTrue);
  });

  testWidgets('adds an unrouted ready order and accepts the latest fingerprint',
      (tester) async {
    final orders = _Orders();
    final routes = _Routes();
    await _mount(tester, orders, routes);
    await _pick(tester, 22);
    expect(find.byType(AlertDialog), findsNothing);
    expect(routes.calls.last, [21, 23, 22]);
    expect(orders.accepted, isNull);
    await tester.tap(_accept);
    await tester.pumpAndSettle();
    expect(orders.accepted, [21, 23, 22]);
    expect(orders.fingerprint, 'selection-21-23-22');
    expect(find.byType(RouteProposalEditor), findsNothing);
  });

  testWidgets(
      'taking from another proposal requires confirmation without mutating it while editing',
      (tester) async {
    final routes = _Routes();
    final orders = _Orders();
    final notifier = await _mount(tester, orders, routes);
    await _pick(tester, 24);
    expect(find.text('¿Tomar un pedido de la Ruta 2?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await tester.pumpAndSettle();
    expect(routes.calls.length, 1);
    expect(find.byKey(const ValueKey('selected-order-24')), findsNothing);
    await _pick(tester, 24);
    await tester.tap(find.text('Añadir a mi ruta'));
    await tester.pumpAndSettle();
    expect(routes.calls.last, [21, 23, 24]);
    expect(
        notifier.state.routingPlan!.proposals[1].stops
            .map((stop) => stop.orderId),
        contains(24));
    expect(orders.accepted, isNull);
    await tester.tap(_accept);
    await tester.pumpAndSettle();
    expect(orders.accepted, [21, 23, 24]);
    expect(orders.fingerprint, 'selection-21-23-24');
  });

  testWidgets(
      'picker identifies origins and filters addresses without offering preparation',
      (tester) async {
    await _mount(tester, _Orders(), _Routes());
    await tester.tap(find.text('Añadir pedido'));
    await tester.pumpAndSettle();
    expect(find.text('Sin ruta sugerida'), findsNothing);
    expect(find.textContaining('Sin ruta sugerida'), findsOneWidget);
    expect(find.textContaining('En Ruta 2 · requiere confirmación'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('add-order-25')), findsNothing);
    await tester.enterText(find.byType(TextField), 'Calle 24');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-order-24')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-order-22')), findsNothing);
  });

  testWidgets(
      'reordering recalculates automatically and ignores the older response',
      (tester) async {
    final routes = _Routes()..holdPreviews = true;
    final orders = _Orders();
    await _mount(tester, orders, routes);
    expect(_canAccept(tester), isFalse);
    tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorder(0, 2);
    await tester.pump(const Duration(milliseconds: 300));
    expect(routes.calls, [
      [21, 23],
      [23, 21]
    ]);
    routes.pending[1]
        .complete(routes.previewResult([23, 21], fingerprint: 'new-preview'));
    await tester.pump();
    await tester.pump();
    expect(_canAccept(tester), isTrue);
    routes.pending[0]
        .complete(routes.previewResult([21, 23], fingerprint: 'old-preview'));
    await tester.pump();
    await tester.tap(_accept);
    await tester.pumpAndSettle();
    expect(orders.accepted, [23, 21]);
    expect(orders.fingerprint, 'new-preview');
  });

  testWidgets(
      'rapid changes debounce previews and disable acceptance until current',
      (tester) async {
    final routes = _Routes();
    await _mount(tester, _Orders(), routes);
    final reorder = tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorder;
    reorder(0, 2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_canAccept(tester), isFalse);
    reorder(1, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(routes.calls.length, 1);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(routes.calls, [
      [21, 23],
      [21, 23]
    ]);
    expect(_canAccept(tester), isTrue);
  });

  testWidgets(
      'an empty selection never requests a preview or allows acceptance',
      (tester) async {
    final routes = _Routes();
    await _mount(tester, _Orders(), routes);
    await _remove(tester, 21);
    await _remove(tester, 23);
    expect(routes.calls, [
      [21, 23],
      [23]
    ]);
    expect(_canAccept(tester), isFalse);
    expect(
        find.textContaining('Añade al menos un pedido listo'), findsOneWidget);
    await _pick(tester, 21);
    expect(find.byType(AlertDialog), findsNothing);
    expect(routes.calls.last, [21]);
    expect(_canAccept(tester), isTrue);
  });

  testWidgets(
      'preview failure is recoverable without a permanent update button',
      (tester) async {
    final routes = _Routes()..error = StateError('Sin conexión');
    await _mount(tester, _Orders(), routes);
    expect(_canAccept(tester), isFalse);
    expect(find.text('Reintentar cálculo'), findsOneWidget);
    routes.error = null;
    await tester.tap(find.text('Reintentar cálculo'));
    await tester.pumpAndSettle();
    expect(routes.calls.length, 2);
    expect(_canAccept(tester), isTrue);
    expect(find.text('Reintentar cálculo'), findsNothing);
  });

  testWidgets('SignalR invalidation cannot enable an in-flight selection',
      (tester) async {
    final routes = _Routes()..holdPreviews = true;
    final notifier = await _mount(tester, _Orders(), routes);
    notifier.invalidateRouting('Cambió desde otro dispositivo.');
    routes.pending.single.complete(routes.previewResult([21, 23]));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(_canAccept(tester), isFalse);
    expect(find.text('Volver y actualizar rutas'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Añadir pedido'))
            .onPressed,
        isNull);
  });

  testWidgets('closing during preview ignores late responses safely',
      (tester) async {
    final routes = _Routes()..holdPreviews = true;
    await _mount(tester, _Orders(), routes);
    await tester.tap(find.byTooltip('Cerrar preparación de ruta'));
    await tester.pumpAndSettle();
    routes.pending.single.complete(routes.previewResult([21, 23]));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('acceptance keeps the existing tracking requirement',
      (tester) async {
    final orders = _Orders();
    await _mount(tester, orders, _Routes(),
        canBeginDelivery: () async => false);
    await tester.tap(_accept);
    await tester.pumpAndSettle();
    expect(orders.accepted, isNull);
    expect(find.textContaining('seguimiento de ubicación'), findsOneWidget);
    expect(find.byType(RouteProposalEditor), findsOneWidget);
  });

  testWidgets('dragging the handle updates the order and recalculates',
      (tester) async {
    final routes = _Routes();
    await _mount(tester, _Orders(), routes);
    final handle = find.descendant(
        of: find.byKey(const ValueKey('selected-order-21')),
        matching: find.byIcon(Icons.drag_handle));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(routes.calls.last, [23, 21]);
    expect(_canAccept(tester), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a changed plan cancels a pending confirmation from another proposal',
      (tester) async {
    final routes = _Routes();
    final notifier = await _mount(tester, _Orders(), routes);
    await _pick(tester, 24);
    notifier.invalidateRouting('Otro domiciliario aceptó la propuesta.');
    await tester.pump();
    await tester.tap(find.text('Añadir a mi ruta'));
    await tester.pumpAndSettle();
    expect(routes.calls.length, 1);
    expect(find.byKey(const ValueKey('selected-order-24')), findsNothing);
    expect(_canAccept(tester), isFalse);
  });

  testWidgets('picker remains usable with larger text and the keyboard',
      (tester) async {
    await _mount(tester, _Orders(), _Routes(), scale: 1.4);
    tester.view.physicalSize = const Size(390, 640);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Añadir pedido'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Calle 24');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-order-24')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
      'choice helper preserves origin, uses addresses and excludes assigned or unready orders',
      () async {
    final available = await _Orders().getAvailableOrders();
    final choices = routeEditorChoices(_plan(), available);
    expect(choices.keys.toSet(), {21, 22, 23, 24});
    expect(choices[24]!.proposalId, 20);
    expect(choices[22]!.proposalId, isNull);
    expect(routeEditorAddress(choices[21]!), 'Calle 21 #10-20');
    final assigned = Order(
        id: 24,
        status: OrderStatus.ready,
        type: 'delivery',
        createdAt: DateTime.now(),
        total: 1000,
        items: const [],
        branchId: 1,
        deliveryManId: 7);
    expect(
        routeEditorChoices(_plan(), [...available, assigned]).containsKey(24),
        isFalse);
  });
}
