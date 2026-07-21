import 'package:delivery_app/features/auth/data/auth_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AuthUser conserva las coordenadas de la sucursal', () {
    final user = AuthUser.fromJson({
      'id': 12,
      'name': 'Domiciliario',
      'email': 'domiciliario@example.com',
      'role': 'deliveryman',
      'branchId': 3,
      'branchLatitude': 4.60971,
      'branchLongitude': -74.08175,
    });

    expect(user.branchLatitude, 4.60971);
    expect(user.branchLongitude, -74.08175);

    final restored = AuthUser.fromJson(user.toJson());
    expect(restored.branchLatitude, user.branchLatitude);
    expect(restored.branchLongitude, user.branchLongitude);
  });

  test('AuthUser tolera sesiones guardadas sin coordenadas', () {
    final user = AuthUser.fromJson({
      'id': 12,
      'name': 'Domiciliario',
      'email': 'domiciliario@example.com',
      'role': 'deliveryman',
      'branchId': 3,
    });

    expect(user.branchLatitude, isNull);
    expect(user.branchLongitude, isNull);
  });
}
