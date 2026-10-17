import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api/api_constants.dart';
import '../../core/api/dio_client.dart';
import 'delivery_routing_models.dart';

class DeliveryRoutingRepository {
  final DioClient _client;
  DeliveryRoutingRepository(this._client);

  Future<DeliveryRoutingPlan> getPlan() => _client.get(
        ApiConstants.deliveryRoutingPlan,
        fromJson: (data) => DeliveryRoutingPlan.fromJson(
          Map<String, dynamic>.from(data as Map),
        ),
      );

  Future<DeliveryRouteProposal> preview(List<int> orderIds, int version) =>
      _client.post(
        '/delivery-routing/preview',
        data: {'orderIds': orderIds, 'expectedPlanVersion': version},
        fromJson: (data) => DeliveryRouteProposal.fromJson(
            Map<String, dynamic>.from(data as Map)),
      );
}

final deliveryRoutingRepositoryProvider = Provider(
  (ref) => DeliveryRoutingRepository(ref.watch(dioClientProvider)),
);
