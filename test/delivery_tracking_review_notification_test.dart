import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:delivery_app/features/notifications/fcm_service.dart';
import 'package:delivery_app/features/notifications/tracking_review_dialog.dart';

void main() {
  const data = {
    'type': 'delivery_tracking_review',
    'alertId': '42',
    'alertType': 'unexpected_stay',
    'deliverymanId': '7',
    'title': 'Revisión de seguimiento',
    'body': 'Mensaje de revisión',
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('reconoce y persiste una notificación de revisión sin duplicarla',
      () async {
    final notice = DeliveryTrackingReviewNotice.fromData(data);

    expect(notice, isNotNull);
    expect(notice!.alertId, 42);
    expect(notice.deliverymanId, 7);
    expect(notice.alertType, 'unexpected_stay');

    await FcmService.handleTrackingReviewData(data, notifyUi: false);
    await FcmService.handleTrackingReviewData(data, notifyUi: false);

    final pending = await FcmService.pendingTrackingReviewNotices();
    expect(pending, hasLength(1));
    expect(pending.single.alertId, 42);

    await FcmService.dismissTrackingReviewNotice(42);
    expect(await FcmService.pendingTrackingReviewNotices(), isEmpty);

    await FcmService.handleTrackingReviewData(data, notifyUi: false);
    expect(await FcmService.pendingTrackingReviewNotices(), isEmpty);
  });

  test('ignora mensajes FCM ajenos o incompletos', () {
    expect(
      DeliveryTrackingReviewNotice.fromData({...data, 'type': 'order_ready'}),
      isNull,
    );
    expect(
      DeliveryTrackingReviewNotice.fromData({...data}..remove('alertId')),
      isNull,
    );
  });

  test('limpia todos los avisos pendientes al cerrar sesión', () async {
    await FcmService.handleTrackingReviewData(data, notifyUi: false);

    await FcmService.clearTrackingReviewNotices();

    expect(await FcmService.pendingTrackingReviewNotices(), isEmpty);
  });

  test('conserva varios avisos pendientes en orden y deduplicados', () async {
    await FcmService.handleTrackingReviewData(data, notifyUi: false);
    await FcmService.handleTrackingReviewData(
      {...data, 'alertId': '43', 'alertType': 'gps_disabled'},
      notifyUi: false,
    );
    await FcmService.handleTrackingReviewData(data, notifyUi: false);

    final pending = await FcmService.pendingTrackingReviewNotices();

    expect(pending.map((notice) => notice.alertId), [42, 43]);
  });

  testWidgets('el modal solo se cierra con Aceptar', (tester) async {
    const notice = DeliveryTrackingReviewNotice(
      alertId: 42,
      deliverymanId: 7,
      alertType: 'unexpected_stay',
      title: 'Revisión de seguimiento',
      body: 'Mensaje de revisión',
    );
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (value) {
        context = value;
        return const Scaffold();
      }),
    ));

    unawaited(showTrackingReviewDialog(context, notice));
    await tester.pumpAndSettle();
    expect(find.text('Revisión de seguimiento'), findsOneWidget);

    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.text('Revisión de seguimiento'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Revisión de seguimiento'), findsOneWidget);

    await tester.tap(find.text('Aceptar'));
    await tester.pumpAndSettle();
    expect(find.text('Revisión de seguimiento'), findsNothing);
  });
}
