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
      final uri = buildWhatsAppUri('@cliente_arroz', message: 'Hola & bienvenido');
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
