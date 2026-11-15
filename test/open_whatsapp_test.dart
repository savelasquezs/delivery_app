import 'package:delivery_app/core/whatsapp/open_whatsapp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:delivery_app/features/route/presentation/widgets/delivery_order_detail_sheet.dart';

void main() {
  testWidgets('username-only contact offers WhatsApp without a phone call',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: CustomerContactActions(username: '@cliente_arroz'))));
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Llamar'), findsNothing);
  });

  testWidgets(
      'phone contact retains both actions and invalid contacts have none',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: CustomerContactActions(
                phone: '3001234567', username: '@cliente_arroz'))));
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Llamar'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: CustomerContactActions(
                phone: '@cliente_arroz', username: 'bad/user'))));
    expect(find.text('WhatsApp'), findsNothing);
    expect(find.text('Llamar'), findsNothing);
  });

  test('contact selection validates phone and falls back to username', () {
    expect(whatsAppContact(phone: '3001234567', username: '@otro'),
        '573001234567');
    expect(whatsAppContact(phone: '123', username: ' @Cliente_Arroz '),
        '@cliente_arroz');
    expect(whatsAppContact(phone: '   ', username: '@cliente_arroz'),
        '@cliente_arroz');
    expect(whatsAppContact(), isNull);
  });

  test('phone validation rejects short, zero-prefixed and excessive numbers',
      () async {
    for (final value in [
      '123',
      '+57',
      '0001234567',
      '1234567890123456',
      '@cliente123'
    ]) {
      expect(waMeDigitsFromPhone(value), isNull);
      expect(await openPhoneCall(value), isFalse);
    }
  });

  test('query encoding keeps accents, emoji, newlines and reserved characters',
      () {
    const message = 'Hola Señor 🍚\n¿Apto #2? & pago=efectivo + cambio';
    for (final contact in ['@cliente_arroz', '+57 300 123 4567']) {
      final uri = buildWhatsAppUri(contact, message: message)!;
      expect(uri.host, 'wa.me');
      expect(uri.queryParameters, {'text': message});
      expect(uri.fragment, isEmpty);
    }
  });
  group('waMeDigitsFromPhone', () {
    test('móvil CO 10 dígitos con 3', () {
      expect(waMeDigitsFromPhone('3001234567'), '573001234567');
    });

    test('con +57', () {
      expect(waMeDigitsFromPhone('+573001234567'), '573001234567');
    });

    test('ya con 57 y 12 dígitos', () {
      expect(waMeDigitsFromPhone('573001234567'), '573001234567');
    });

    test('limpia espacios y guiones', () {
      expect(waMeDigitsFromPhone('+57 300 123-4567'), '573001234567');
    });

    test('no confunde usernames con números', () {
      expect(waMeDigitsFromPhone('@cliente_arroz'), isNull);
      expect(waMeDigitsFromPhone('cliente_arroz'), isNull);
    });

    test('vacío o solo símbolos', () {
      expect(waMeDigitsFromPhone(''), isNull);
      expect(waMeDigitsFromPhone('   '), isNull);
      expect(waMeDigitsFromPhone('---'), isNull);
    });
  });

  group('waMeUsername', () {
    test('quita @ y normaliza a minúsculas', () {
      expect(waMeUsername(' @Cliente_Arroz '), 'cliente_arroz');
    });

    test('rechaza identificadores inválidos', () {
      expect(waMeUsername('ab'), isNull);
      expect(waMeUsername('12'), isNull);
      expect(waMeUsername('573001234567'), isNull);
      expect(waMeUsername('@nombre con espacios'), isNull);
      expect(waMeUsername('@nombre/../ruta'), isNull);
    });
  });

  group('buildWhatsAppUri', () {
    test('construye chat de usuario sin teléfono', () {
      expect(
        buildWhatsAppUri('@cliente_arroz').toString(),
        'https://wa.me/cliente_arroz',
      );
    });

    test('prepara mensaje para usuario', () {
      final uri =
          buildWhatsAppUri('@cliente_arroz', message: 'Hola & bienvenido');
      expect(uri?.path, '/cliente_arroz');
      expect(uri?.queryParameters['text'], 'Hola & bienvenido');
    });

    test('no abre contactos no válidos', () {
      expect(buildWhatsAppUri('foo/bar'), isNull);
      expect(buildWhatsAppUri('---'), isNull);
    });

    test('construye chat sin mensaje', () {
      expect(
        buildWhatsAppUri('3001234567').toString(),
        'https://wa.me/573001234567',
      );
    });

    test('codifica mensaje prellenado', () {
      final uri = buildWhatsAppUri(
        '3001234567',
        message:
            'Hola, hablas con Juan de Señor Arroz. Te hablo porque ya voy en camino.',
      );

      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(uri.host, 'wa.me');
      expect(uri.path, '/573001234567');
      expect(
        uri.queryParameters['text'],
        'Hola, hablas con Juan de Señor Arroz. Te hablo porque ya voy en camino.',
      );
    });
  });
}
