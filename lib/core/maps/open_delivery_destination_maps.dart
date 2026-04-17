import 'package:url_launcher/url_launcher.dart';

import '../../features/orders/models/order_models.dart';

/// `true` si hay coordenadas válidas o texto de búsqueda para abrir el mapa.
bool orderHasOpenableMapDestination(Order order) =>
    buildDeliveryDestinationMapsUri(order) != null;

/// URL de Google Maps: ruta en auto hacia [lat],[lng], o búsqueda por dirección.
Uri? buildDeliveryDestinationMapsUri(Order order) {
  final lat = order.latitude;
  final lng = order.longitude;
  if (lat != null && lng != null && lat != 0 && lng != 0) {
    final dest = '$lat,$lng';
    return Uri.parse(
      'https://www.google.com/maps/dir/?api=1&travelmode=driving'
      '&destination=${Uri.encodeComponent(dest)}',
    );
  }
  final q = _mapsSearchQuery(order);
  if (q == null || q.isEmpty) return null;
  return Uri.parse(
    'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(q)}',
  );
}

String? _mapsSearchQuery(Order order) {
  final line = order.displayAddressLine?.trim();
  if (line != null && line.isNotEmpty) {
    final nb = order.displayNeighborhoodLabel?.trim();
    if (nb != null &&
        nb.isNotEmpty &&
        !line.toLowerCase().contains(nb.toLowerCase())) {
      return '$line, $nb';
    }
    return line;
  }
  final nb = order.displayNeighborhoodLabel?.trim();
  if (nb != null && nb.isNotEmpty) return nb;
  return null;
}

Future<bool> openDeliveryDestinationInMaps(Order order) async {
  final uri = buildDeliveryDestinationMapsUri(order);
  if (uri == null) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
