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
}
