import 'dart:convert';

import 'package:delivery_app/core/auth/jwt_expiration.dart';
import 'package:flutter_test/flutter_test.dart';

/// JWT de prueba: payload {"exp": 2000000000} (~2033), firmas dummy.
String _jwtWithExp(int expSec) {
  final payload = base64Url.encode(utf8.encode('{"exp":$expSec}'));
  return 'x.$payload.y';
}

void main() {
  test('readExpSecondsUtc devuelve exp', () {
    expect(JwtExpiration.readExpSecondsUtc(_jwtWithExp(2000000000)), 2000000000);
  });

  test('shouldProactivelyRefresh es true sin jwt', () {
    expect(JwtExpiration.shouldProactivelyRefresh(null), isTrue);
    expect(JwtExpiration.shouldProactivelyRefresh(''), isTrue);
  });

  test('shouldProactivelyRefresh es true si ya expiró', () {
    final past = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    final exp = past.millisecondsSinceEpoch ~/ 1000;
    expect(JwtExpiration.shouldProactivelyRefresh(_jwtWithExp(exp)), isTrue);
  });

  test('shouldProactiveRefresh es false si falta mucho para expirar', () {
    final future = DateTime.now().toUtc().add(const Duration(hours: 2));
    final exp = future.millisecondsSinceEpoch ~/ 1000;
    expect(
      JwtExpiration.shouldProactivelyRefresh(
        _jwtWithExp(exp),
        skew: const Duration(minutes: 5),
      ),
      isFalse,
    );
  });
}
