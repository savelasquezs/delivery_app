import 'package:delivery_app/core/maps/open_delivery_destination_maps.dart';
import 'package:delivery_app/features/orders/models/order_models.dart';
import 'package:flutter_test/flutter_test.dart';

Order _minimalOrder({
  double? latitude,
  double? longitude,
  String? addressDescription,
  String? neighborhoodName,
}) {
  return Order(
    id: 1,
    status: OrderStatus.onTheWay,
    type: 'delivery',
    createdAt: DateTime.utc(2026, 1, 1),
    total: 1000,
    items: const [],
    branchId: 1,
    latitude: latitude,
    longitude: longitude,
    addressDescription: addressDescription,
    neighborhoodName: neighborhoodName,
  );
}

void main() {
  group('buildDeliveryDestinationMapsUri', () {
    test('usa dir con coordenadas válidas', () {
      final uri = buildDeliveryDestinationMapsUri(
        _minimalOrder(latitude: 4.60971, longitude: -74.08175),
      );
      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/dir/');
      expect(uri.queryParameters['api'], '1');
      expect(uri.queryParameters['travelmode'], 'driving');
      expect(uri.queryParameters['destination'], '4.60971,-74.08175');
    });

    test('ignora coordenadas en cero y usa búsqueda por dirección', () {
      final uri = buildDeliveryDestinationMapsUri(
        _minimalOrder(
          latitude: 0,
          longitude: 0,
          addressDescription: 'Calle 10 #5',
          neighborhoodName: 'Centro',
        ),
      );
      expect(uri, isNotNull);
      expect(uri!.path, '/maps/search/');
      expect(uri.queryParameters['api'], '1');
      expect(uri.queryParameters['query'], 'Calle 10 #5, Centro');
    });

    test('solo barrio si no hay línea de dirección', () {
      final uri = buildDeliveryDestinationMapsUri(
        _minimalOrder(neighborhoodName: 'Chapinero'),
      );
      expect(uri, isNotNull);
      expect(uri!.path, '/maps/search/');
      expect(uri.queryParameters['query'], 'Chapinero');
    });

    test('null si no hay coordenadas ni texto', () {
      expect(buildDeliveryDestinationMapsUri(_minimalOrder()), isNull);
    });
  });

  group('orderHasOpenableMapDestination', () {
    test('true con coords', () {
      expect(
        orderHasOpenableMapDestination(
          _minimalOrder(latitude: 1, longitude: -1),
        ),
        isTrue,
      );
    });

    test('false sin datos', () {
      expect(orderHasOpenableMapDestination(_minimalOrder()), isFalse);
    });
  });
}
