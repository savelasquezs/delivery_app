import 'package:delivery_app/core/auth/session_replacement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detecta una sesión reemplazada por código', () {
    expect(
      isSessionReplacedResponse(401, {
        'code': 'SESSION_REPLACED',
        'message': 'Tu sesión fue iniciada en otro dispositivo.',
      }),
      isTrue,
    );
  });

  test('no confunde una expiración normal con un reemplazo', () {
    expect(
      isSessionReplacedResponse(401, {
        'code': 'UNAUTHORIZED',
        'message': 'Token inválido o expirado',
      }),
      isFalse,
    );
  });

  test('ignora el código si la respuesta no es 401', () {
    expect(
      isSessionReplacedResponse(400, {'code': 'SESSION_REPLACED'}),
      isFalse,
    );
  });
}
