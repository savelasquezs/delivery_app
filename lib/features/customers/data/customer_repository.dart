import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_constants.dart';
import '../../../core/api/dio_client.dart';
import '../models/neighborhood.dart';

class CustomerRepository {
  final DioClient _client;

  const CustomerRepository(this._client);

  Future<List<Neighborhood>> getNeighborhoods() async {
    return _client.get<List<Neighborhood>>(
      ApiConstants.customerNeighborhoods,
      fromJson: (data) {
        if (data is List) {
          return data
              .map((e) => Neighborhood.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        final map = data as Map<String, dynamic>;
        final inner = map['data'] as List<dynamic>? ??
            map['Data'] as List<dynamic>? ??
            [];
        return inner
            .map((e) => Neighborhood.fromJson(e as Map<String, dynamic>))
            .toList();
      },
    );
  }

  /// Cuerpo camelCase; el backend valida campos requeridos en actualización completa.
  Future<void> updateCustomerAddress({
    required int customerId,
    required int addressId,
    required Map<String, dynamic> body,
  }) async {
    await _client.put<dynamic>(
      ApiConstants.customerAddress(customerId, addressId),
      data: body,
    );
  }
}

final customerRepositoryProvider = Provider<CustomerRepository>((ref) {
  return CustomerRepository(ref.watch(dioClientProvider));
});
