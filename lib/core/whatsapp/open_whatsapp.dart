import 'package:url_launcher/url_launcher.dart';

/// Normaliza un teléfono a dígitos para `https://wa.me/<digits>`.
/// Alineado con el flujo de contacto del cliente en pedidos (CO móvil 3xx).
String? waMeDigitsFromPhone(String raw) {
  final clean = raw.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  if (clean.isEmpty) return null;
  final n = clean;
  if (n.startsWith('+57')) return n.replaceAll('+', '');
  if (n.startsWith('57') && n.length == 12) return n;
  if (n.startsWith('3') && n.length == 10) return '57$n';
  final noPlus = n.replaceAll('+', '');
  if (noPlus.isEmpty) return null;
  return noPlus;
}

Uri? buildWhatsAppUri(String phone, {String? message}) {
  final digits = waMeDigitsFromPhone(phone);
  if (digits == null || digits.isEmpty) return null;
  final text = message?.trim();
  return Uri.https(
    'wa.me',
    '/$digits',
    text != null && text.isNotEmpty ? {'text': text} : null,
  );
}

Future<bool> openWhatsAppChat(String phone, {String? message}) async {
  final uri = buildWhatsAppUri(phone, message: message);
  if (uri == null) return false;
  try {
    return await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}

Future<bool> openPhoneCall(String raw) async {
  final phone = raw.replaceAll(RegExp(r'[^0-9+]'), '');
  if (phone.isEmpty) return false;
  try {
    return await launchUrl(Uri(scheme: 'tel', path: phone),
        mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
