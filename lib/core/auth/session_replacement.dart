const sessionReplacedCode = 'SESSION_REPLACED';
const sessionReplacedMessage =
    'Tu sesión fue iniciada en otro dispositivo. Inicia sesión nuevamente.';

bool isSessionReplacedResponse(int? statusCode, dynamic data) {
  if (statusCode != 401 || data is! Map) return false;
  final code = data['code'] ?? data['Code'];
  if (code?.toString().toUpperCase() == sessionReplacedCode) return true;

  final message =
      (data['message'] ?? data['Message'])?.toString().toLowerCase();
  return message?.contains('otro dispositivo') == true;
}

String? sessionReplacementMessage(dynamic data) {
  if (data is! Map) return null;
  final value = data['message'] ?? data['Message'];
  return value is String && value.trim().isNotEmpty
      ? value.trim()
      : sessionReplacedMessage;
}
