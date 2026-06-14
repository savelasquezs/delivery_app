import 'package:delivery_app/core/whatsapp/open_whatsapp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

    test('vacío o solo símbolos', () {
      expect(waMeDigitsFromPhone(''), isNull);
      expect(waMeDigitsFromPhone('   '), isNull);
      expect(waMeDigitsFromPhone('---'), isNull);
    });
  });

  group('buildWhatsAppUri', () {
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
