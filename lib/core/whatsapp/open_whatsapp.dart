import 'package:url_launcher/url_launcher.dart';

/// Normaliza un teléfono a dígitos para `https://wa.me/<digits>`.
/// Alineado con el flujo de contacto del cliente en pedidos (CO móvil 3xx).
String? waMeDigitsFromPhone(String raw) {
  final clean = raw.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  if (clean.isEmpty || !RegExp(r'^\+?[0-9]+$').hasMatch(clean)) return null;
  final n = clean;
  if (n.startsWith('3') && n.length == 10) return '57$n';
  final digits = n.replaceFirst(RegExp(r'^\+'), '');
  return RegExp(r'^[1-9][0-9]{6,14}$').hasMatch(digits) ? digits : null;
}

/// WhatsApp username: 3–35 caracteres ASCII (sin el @ inicial).
/// Los nombres son distintos de los teléfonos y no se deben tratar como BSUID.
String? waMeUsername(String raw) {
  final candidate = raw.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  if (!RegExp(r'^[a-z0-9._]{3,35}$').hasMatch(candidate) ||
      RegExp(r'^[0-9]+$').hasMatch(candidate)) return null;
  return candidate;
}

String? whatsAppContact({String? phone, String? username}) {
  final digits = waMeDigitsFromPhone(phone ?? '');
  if (digits != null) return digits;
  final handle = waMeUsername(username ?? '');
  return handle == null ? null : '@$handle';
}

/// Abre por número o usuario. Los enlaces por username están sujetos
/// a la disponibilidad de la función de WhatsApp en el dispositivo.
Uri? buildWhatsAppUri(String contact, {String? message}) {
  final target = waMeDigitsFromPhone(contact) ?? waMeUsername(contact);
  if (target == null) return null;
  final text = message?.trim();
  return Uri.https(
    'wa.me',
    '/$target',
    text != null && text.isNotEmpty ? {'text': text} : null,
  );
}

Future<bool> openWhatsAppChat(String contact, {String? message}) async {
  final uri = buildWhatsAppUri(contact, message: message);
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
  final phone = waMeDigitsFromPhone(raw);
  if (phone == null) return false;
  try {
    return await launchUrl(Uri(scheme: 'tel', path: phone),
        mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
