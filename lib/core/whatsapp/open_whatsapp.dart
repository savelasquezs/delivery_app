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

Future<bool> openWhatsAppChat(String phone) async {
  final digits = waMeDigitsFromPhone(phone);
  if (digits == null || digits.isEmpty) return false;
  try {
    return await launchUrl(
      Uri.parse('https://wa.me/$digits'),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}
