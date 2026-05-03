import 'package:delivery_app/core/orders/available_orders_layout.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:flutter_test/flutter_test.dart';

Order _order({
  required int id,
  DateTime? prepareAt,
  DateTime? createdAt,
  Map<String, DateTime>? statusTimes,
  String? neighborhoodName,
  OrderStatus status = OrderStatus.ready,
}) {
  final ca = createdAt ?? DateTime.utc(2026, 1, 1, 12, 0);
  return Order(
    id: id,
    status: status,
    type: 'delivery',
    createdAt: ca,
    total: 1000,
    items: const [],
    branchId: 1,
    prepareAt: prepareAt,
    statusTimes: statusTimes ?? const {},
    neighborhoodName: neighborhoodName,
  );
}

void main() {
  group('compareOrdersOldestFirst', () {
    test('usa prepareAt cuando existe', () {
      final a = _order(
        id: 1,
        prepareAt: DateTime.utc(2026, 1, 1, 14, 0),
        createdAt: DateTime.utc(2026, 1, 1, 10, 0),
      );
      final b = _order(
        id: 2,
        prepareAt: DateTime.utc(2026, 1, 1, 13, 0),
        createdAt: DateTime.utc(2026, 1, 1, 9, 0),
      );
      final list = [a, b]..sort(compareOrdersOldestFirst);
      expect(list.map((e) => e.id).toList(), [2, 1]);
    });

    test('sin prepareAt usa createdAt', () {
      final a = _order(id: 1, createdAt: DateTime.utc(2026, 1, 2));
      final b = _order(id: 2, createdAt: DateTime.utc(2026, 1, 1));
      final list = [a, b]..sort(compareOrdersOldestFirst);
      expect(list.map((e) => e.id).toList(), [2, 1]);
    });
  });

  group('groupOrdersByNeighborhood', () {
    test('agrupa y mantiene orden antiguo primero dentro del grupo', () {
      final o1 = _order(
        id: 1,
        neighborhoodName: 'Centro',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final o2 = _order(
        id: 2,
        neighborhoodName: 'Centro',
        createdAt: DateTime.utc(2026, 1, 2),
      );
      final o3 = _order(
        id: 3,
        neighborhoodName: 'Norte',
        createdAt: DateTime.utc(2026, 1, 1, 12),
      );
      final g = groupOrdersByNeighborhood([o2, o3, o1]);
      expect(g.keys.toList(), ['Centro', 'Norte']);
      expect(g['Centro']!.map((e) => e.id).toList(), [1, 2]);
      expect(g['Norte']!.map((e) => e.id).toList(), [3]);
    });

    test('sin barrio va a Sin barrio', () {
      final o = _order(id: 1);
      final g = groupOrdersByNeighborhood([o]);
      expect(g.keys.single, 'Sin barrio');
    });

    test('con compare por ancla de urgencia: más urgente arriba en el grupo', () {
      final anchorOld = DateTime.utc(2026, 1, 1, 7, 0);
      final anchorNew = DateTime.utc(2026, 1, 1, 11, 0);
      final oLessUrgent = _order(
        id: 1,
        neighborhoodName: 'Centro',
        status: OrderStatus.taken,
        createdAt: anchorNew,
        statusTimes: {'taken': anchorNew},
      );
      final oMoreUrgent = _order(
        id: 2,
        neighborhoodName: 'Centro',
        status: OrderStatus.taken,
        createdAt: DateTime.utc(2026, 1, 1, 6, 0),
        statusTimes: {'taken': anchorOld},
      );
      final g = groupOrdersByNeighborhood(
        [oLessUrgent, oMoreUrgent],
        compare: compareOrdersUrgencyAnchorOldestFirst,
      );
      expect(g['Centro']!.map((e) => e.id).toList(), [2, 1]);
    });
  });

  group('compareOrdersUrgencyAnchorOldestFirst', () {
    test('ancla más antigua (más minutos) va primero', () {
      final a = _order(
        id: 1,
        statusTimes: {'taken': DateTime.utc(2026, 1, 1, 10, 0)},
      );
      final b = _order(
        id: 2,
        statusTimes: {'taken': DateTime.utc(2026, 1, 1, 8, 0)},
      );
      final list = [a, b]..sort(compareOrdersUrgencyAnchorOldestFirst);
      expect(list.map((e) => e.id).toList(), [2, 1]);
    });
  });

  group('urgencyAnchorAt', () {
    test('prioriza prepareAt', () {
      final p = DateTime.utc(2026, 6, 1, 10, 0);
      final t = DateTime.utc(2026, 6, 1, 8, 0);
      final o = _order(
        id: 1,
        prepareAt: p,
        createdAt: DateTime.utc(2026, 6, 1, 6, 0),
        statusTimes: {'taken': t},
      );
      expect(urgencyAnchorAt(o), p);
    });

    test('sin prepareAt usa taken', () {
      final t = DateTime.utc(2026, 6, 1, 8, 0);
      final o = _order(
        id: 1,
        createdAt: DateTime.utc(2026, 6, 1, 6, 0),
        statusTimes: {'taken': t},
      );
      expect(urgencyAnchorAt(o), t);
    });

    test('sin prepareAt ni taken usa createdAt', () {
      final c = DateTime.utc(2026, 6, 1, 6, 0);
      final o = _order(id: 1, createdAt: c);
      expect(urgencyAnchorAt(o), c);
    });
  });

  group('urgencyTierAt', () {
    final anchor = DateTime.utc(2026, 1, 1, 12, 0, 0);

    test('límites inclusivos 20 / 30 / 35', () {
      expect(
        urgencyTierAt(anchor, anchor.add(const Duration(minutes: 20))),
        DeliveryUrgencyTier.green,
      );
      expect(
        urgencyTierAt(anchor, anchor.add(const Duration(minutes: 21))),
        DeliveryUrgencyTier.orange,
      );
      expect(
        urgencyTierAt(anchor, anchor.add(const Duration(minutes: 30))),
        DeliveryUrgencyTier.orange,
      );
      expect(
        urgencyTierAt(anchor, anchor.add(const Duration(minutes: 31))),
        DeliveryUrgencyTier.orangeRed,
      );
      expect(
        urgencyTierAt(anchor, anchor.add(const Duration(minutes: 35))),
        DeliveryUrgencyTier.orangeRed,
      );
      expect(
        urgencyTierAt(anchor, anchor.add(const Duration(minutes: 36))),
        DeliveryUrgencyTier.red,
      );
    });
  });
}
