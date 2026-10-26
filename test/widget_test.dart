import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:delivery_app/core/theme/app_theme.dart';
import 'package:delivery_app/core/widgets/order_card.dart';
import 'package:delivery_app/core/widgets/compact_action_button.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';

void main() {
  testWidgets(
      'compact route card remains readable and action taps do not open detail',
      (tester) async {
    var opened = 0, called = 0;
    final order = Order.fromJson({
      'id': 999999,
      'status': 'onTheWay',
      'type': 'delivery',
      'createdAt': '2026-10-25T14:00:00Z',
      'total': 99999999,
      'deliveryFee': 4500,
      'customer': {
        'id': 1,
        'name': 'Cliente de nombre largo',
        'phone': '3000000001'
      },
      'neighborhoodName': 'Barrio de nombre muy largo',
      'addressDescription':
          'Carrera 123 número 45-67, torre del conjunto residencial'
    });
    for (final width in [320.0, 390.0]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
              body: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(1.4)),
                  child: SingleChildScrollView(
                      child: OrderCard(
                          order: order,
                          compact: true,
                          showFeeAndCashSummary: true,
                          onTap: () => opened++,
                          trailing: Row(children: [
                            CompactActionButton(
                                icon: Icons.call,
                                label: 'Llamar',
                                color: Colors.blue,
                                iconOnly: true,
                                onTap: () => called++),
                          ])))))));
      expect(tester.takeException(), isNull);
      final action = find.byTooltip('Llamar');
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
      final previous = opened;
      await tester.tap(action);
      expect(opened, previous);
      await tester.tap(find.text('Cliente de nombre largo'));
    }
    expect(opened, 2);
    expect(called, 2);
    await tester.binding.setSurfaceSize(null);
  });
}
