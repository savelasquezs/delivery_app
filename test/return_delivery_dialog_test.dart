import 'dart:async';

import 'package:delivery_app/features/route/presentation/return_delivery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openReturnDialog(
    WidgetTester tester, Future<void> Function(List<int>) submit) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(builder: (context) => TextButton(
        onPressed: () => showReturnDeliveryDialog(
          context,
          orderIds: [11, 12],
          onConfirm: submit,
        ),
        child: const Text('Revisar'),
      )),
    ),
  ));
  await tester.tap(find.text('Revisar'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no se completa ningún pedido sin confirmar', (tester) async {
    var calls = 0;
    await openReturnDialog(tester, (_) async { calls++; });
    await tester.tap(find.text('Ahora no'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Pedidos pendientes al regresar'), findsNothing);
  });

  testWidgets('envía solo pedidos seleccionados y bloquea doble envío',
      (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    List<int>? sent;
    await openReturnDialog(tester, (ids) {
      calls++;
      sent = ids;
      return pending.future;
    });
    await tester.tap(find.text('Pedido #12'));
    await tester.pump();
    await tester.tap(find.text('Confirmar entregas'));
    await tester.pump();
    expect(sent, [11]);
    expect(calls, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    pending.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Pedidos pendientes al regresar'), findsNothing);
  });

  testWidgets('error de servidor permite reintentar sin perder selección',
      (tester) async {
    var calls = 0;
    await openReturnDialog(tester, (_) async {
      calls++;
      throw StateError('No se pudo confirmar');
    });
    await tester.tap(find.text('Confirmar entregas'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Pedido #11'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
}
