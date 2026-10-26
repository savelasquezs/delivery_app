import '../../route/delivery_operations.dart';
import '../../../core/storage/secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_constants.dart';
import '../../../core/api/dio_client.dart';
import '../models/neighborhood.dart';

class CustomerRepository {
  final DioClient _client;

  const CustomerRepository(this._client);

  Future<List<Neighborhood>> getNeighborhoods() async {
    final operations = DeliveryOperations(_client, SecureStorage());
    final owner = await operations.owner();
    List<Neighborhood> parse(dynamic data) {
      final list = data is List ? data : (data as Map)['data'] ?? (data)['items'] ?? [];
      return (list as List).map((value) => Neighborhood.fromJson(Map<String, dynamic>.from(value as Map))).toList();
    }
    final cached = await operations.outbox.cached(owner, 'neighborhoods');
    if (cached != null) return parse(cached['items']);
    final result = await _client.get<dynamic>(ApiConstants.customerNeighborhoods);
    final list = parse(result);
    await operations.outbox.cache(owner, 'neighborhoods', {'items': [for (final n in list)
      {'id': n.id, 'name': n.name, 'branchId': n.branchId, 'deliveryFee': n.deliveryFee}]});
    return list;
  }


}

final customerRepositoryProvider = Provider<CustomerRepository>((ref) {
  return CustomerRepository(ref.watch(dioClientProvider));
});
