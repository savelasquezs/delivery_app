import 'dart:async';

import 'package:delivery_app/core/widgets/confirm_assignment_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openAssignmentDialog(
  WidgetTester tester,
  Future<void> Function() onConfirm,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => ConfirmAssignmentDialog.show(
            context,
            title: 'Confirmar asignación',
            subtitle: 'Pedidos: #11, #12',
            onConfirm: onConfirm,
          ),
          child: const Text('Asignarme'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Asignarme'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cancelar no envía ninguna asignación', (tester) async {
    var calls = 0;
    await openAssignmentDialog(tester, () async => calls++);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.text('Confirmar asignación'), findsNothing);
  });

  testWidgets('confirmar ejecuta la asignación una sola vez', (tester) async {
    var calls = 0;
    final pending = Completer<void>();
    await openAssignmentDialog(tester, () {
      calls++;
      return pending.future;
    });

    await tester.tap(find.text('Confirmar'));
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancelar'))
        .onPressed, isNull);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull);

    pending.complete();
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('Confirmar asignación'), findsNothing);
  });

  testWidgets('error conserva el diálogo para poder reintentar', (tester) async {
    await openAssignmentDialog(
      tester,
      () async => throw StateError('Pedido ya asignado'),
    );

    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();

    expect(find.text('Pedido ya asignado'), findsOneWidget);
    expect(find.text('Confirmar'), findsOneWidget);
  });
}
