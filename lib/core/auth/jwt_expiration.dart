import 'dart:convert';

/// Utilidades para leer `exp` del JWT sin validar firma (solo UX / refresh proactivo).
abstract final class JwtExpiration {
  static const Duration defaultProactiveSkew = Duration(minutes: 5);

  /// `exp` en segundos desde epoch UTC, o null si no se puede leer.
  static int? readExpSecondsUtc(String? jwt) {
    if (jwt == null || jwt.isEmpty) return null;
    final payload = _decodePayload(jwt);
    if (payload == null) return null;
    final exp = payload['exp'];
    if (exp is int) return exp;
    if (exp is num) return exp.toInt();
    return null;
  }

  /// Instantánea UTC de expiración, o null.
  static DateTime? expiresAtUtc(String? jwt) {
    final sec = readExpSecondsUtc(jwt);
    if (sec == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true);
  }

  /// true si falta `exp`, ya expiró o expira dentro de [skew].
  static bool shouldProactivelyRefresh(
    String? jwt, {
    Duration skew = defaultProactiveSkew,
  }) {
    final at = expiresAtUtc(jwt);
    if (at == null) return true;
    final now = DateTime.now().toUtc();
    return !at.isAfter(now.add(skew));
  }

  static Map<String, dynamic>? _decodePayload(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;
      final bytes = _decodeBase64Url(parts[1]);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static List<int> _decodeBase64Url(String segment) {
    var s = segment.replaceAll('-', '+').replaceAll('_', '/');
    switch (s.length % 4) {
      case 2:
        s += '==';
        break;
      case 3:
        s += '=';
        break;
    }
    return base64Decode(s);
  }
}
