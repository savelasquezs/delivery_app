import 'dart:collection';

import '../../features/orders/models/order_models.dart';

/// Clave de orden: `prepareAt` si existe; si no, `createdAt`.
DateTime sortKeyForAvailableList(Order o) => o.prepareAt ?? o.createdAt;

int compareOrdersOldestFirst(Order a, Order b) =>
    sortKeyForAvailableList(a).compareTo(sortKeyForAvailableList(b));

/// Etiqueta de grupo por barrio (cabecera). Sin nombre → «Sin barrio».
String neighborhoodGroupKey(Order o) {
  final n = o.displayNeighborhoodLabel?.trim();
  if (n != null && n.isNotEmpty) return n;
  return 'Sin barrio';
}

/// Orden global antiguo primero, luego agrupa conservando el orden de aparición
/// de cada barrio (según el pedido más antiguo de ese barrio).
LinkedHashMap<String, List<Order>> groupOrdersByNeighborhood(
  List<Order> orders,
) {
  final sorted = List<Order>.from(orders)..sort(compareOrdersOldestFirst);
  final keys = <String>[];
  final map = <String, List<Order>>{};
  for (final o in sorted) {
    final k = neighborhoodGroupKey(o);
    if (!map.containsKey(k)) {
      keys.add(k);
      map[k] = [];
    }
    map[k]!.add(o);
  }
  return LinkedHashMap<String, List<Order>>.fromEntries(
    keys.map((k) => MapEntry(k, map[k]!)),
  );
}

/// Ancla del semáforo: `prepareAt`, si no hay → `statusTimes['taken']`, si no → `createdAt`.
DateTime urgencyAnchorAt(Order o) {
  if (o.prepareAt != null) return o.prepareAt!;
  final taken = o.statusTimes['taken'];
  if (taken != null) return taken;
  return o.createdAt;
}

enum DeliveryUrgencyTier { green, orange, orangeRed, red }

/// Minutos transcurridos desde [anchor] hasta [now] (0 si [now] es anterior).
int elapsedWholeMinutes(DateTime anchor, DateTime now) {
  final d = now.difference(anchor);
  if (d.isNegative) return 0;
  return d.inMinutes;
}

/// Umbrales inclusivos: ≤20 verde, ≤30 naranja, ≤35 naranja rojizo, >35 rojo.
DeliveryUrgencyTier urgencyTierAt(DateTime anchor, DateTime now) {
  final m = elapsedWholeMinutes(anchor, now);
  if (m <= 20) return DeliveryUrgencyTier.green;
  if (m <= 30) return DeliveryUrgencyTier.orange;
  if (m <= 35) return DeliveryUrgencyTier.orangeRed;
  return DeliveryUrgencyTier.red;
}

DeliveryUrgencyTier urgencyTierForOrder(Order o, DateTime now) =>
    urgencyTierAt(urgencyAnchorAt(o), now);
