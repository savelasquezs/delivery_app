import 'package:dio/dio.dart';

import '../api/api_exception.dart';

const defaultUserErrorMessage =
    'No pudimos completar la acción. Inténtalo de nuevo.';

String userFacingErrorMessage(
  Object? error, {
  String fallback = defaultUserErrorMessage,
}) {
  final extracted = _extractMessage(error, fallback);
  return _sanitizeMessage(extracted, fallback);
}

String _extractMessage(Object? error, String fallback) {
  if (error == null) return fallback;
  if (error is ApiException) return error.message;
  if (error is DioException) {
    final nested = error.error;
    if (nested != null && !identical(nested, error)) {
      return _extractMessage(nested, fallback);
    }

    final serverMessage = _serverMessage(error.response?.data);
    if (serverMessage != null) return serverMessage;

    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        'La conexión tardó demasiado. Revisa tu internet e inténtalo de nuevo.',
      DioExceptionType.connectionError =>
        'No pudimos conectarnos. Revisa tu conexión a internet e inténtalo de nuevo.',
      DioExceptionType.cancel => 'La operación fue cancelada.',
      _ => fallback,
    };
  }
  if (error is StateError) return error.message.toString();
  if (error is String) return error;
  return error.toString();
}

String? _serverMessage(dynamic data) {
  if (data is String && data.trim().isNotEmpty) return data;
  if (data is! Map) return null;

  for (final key in const [
    'message',
    'Message',
    'detail',
    'Detail',
    'title',
    'Title',
  ]) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

String _sanitizeMessage(String value, String fallback) {
  var message = value.replaceAll('\r\n', '\n').trim();
  if (message.isEmpty) return fallback;

  final dioError = RegExp(
    r'(?:^|\n)Error:\s*(.+)$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(message);
  if (message.contains('DioException') && dioError != null) {
    message = dioError.group(1)!.trim();
  }

  final prefixes = [
    RegExp(r'^ApiException:\s*', caseSensitive: false),
    RegExp(r'^Exception:\s*', caseSensitive: false),
    RegExp(r'^Bad state:\s*', caseSensitive: false),
    RegExp(r'^Error:\s*', caseSensitive: false),
    RegExp(r'^Error al iniciar sesión:\s*', caseSensitive: false),
    RegExp(r'^Error al enviar el correo:\s*', caseSensitive: false),
  ];
  var changed = true;
  while (changed) {
    changed = false;
    for (final prefix in prefixes) {
      final next = message.replaceFirst(prefix, '').trim();
      if (next != message) {
        message = next;
        changed = true;
      }
    }
  }

  if (message.isEmpty) return fallback;

  final lower = message.toLowerCase();
  if (lower.contains('dioexception') ||
      lower.contains('socketexception') ||
      lower.contains('formatexception') ||
      lower.contains('clientexception') ||
      lower.contains('instance of ') ||
      lower.contains('stack trace') ||
      lower.contains('.env')) {
    return fallback;
  }
  if (lower == 'error interno del servidor' ||
      lower == 'internal server error' ||
      lower == 'unknown error') {
    return fallback;
  }

  return message;
}
