import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/dio_client.dart';
import '../../../core/api/api_constants.dart';
import '../models/order_models.dart';

class OrderRepository {
  final DioClient _client;

  const OrderRepository(this._client);

  Future<List<Order>> getAvailableOrders({int? branchId}) async {
    final params = <String, dynamic>{};
    if (branchId != null) params['branchId'] = branchId;

    return _client.get<List<Order>>(
      ApiConstants.deliveryAvailable,
      queryParameters: params.isEmpty ? null : params,
      fromJson: _parseOrderList,
    );
  }

  Future<List<Order>> getPreparationOrders({int? branchId}) async {
    final body = <String, dynamic>{
      'type': 'delivery',
      'status': 'in_preparation',
      'page': 1,
      'pageSize': 100,
    };
    if (branchId != null) body['branchId'] = branchId;

    return _client.post<List<Order>>(
      ApiConstants.ordersSearch,
      data: body,
      fromJson: (data) {
        final list = data is List
            ? data
            : (data as Map<String, dynamic>)['items'] as List? ?? [];
        return list
            .map((e) => Order.fromJson(e as Map<String, dynamic>))
            .toList();
      },
    );
  }

  static List<Order> _parseOrderList(dynamic data) {
    if (data is List) {
      return data.map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();
    }
    final items = (data as Map<String, dynamic>)['items'] as List?;
    return (items ?? []).map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PagedOrders> getAssignedOrders({
    required int deliverymanId,
    int page = 1,
    int pageSize = 20,
    String? fromDate,
    String? toDate,
    int? branchId,
    String? status,
    String? type,
    bool includeOnsiteActiveInHistory = false,
    int? neighborhoodId,
  }) async {
    final params = <String, dynamic>{
      'Page': page,
      'PageSize': pageSize,
    };
    if (fromDate != null) params['FromDate'] = fromDate;
    if (toDate != null) params['ToDate'] = toDate;
    if (branchId != null) params['BranchId'] = branchId;
    if (status != null) params['Status'] = status;
    if (type != null) params['Type'] = type;
    if (includeOnsiteActiveInHistory) params['IncludeOnsiteActiveInHistory'] = true;
    if (neighborhoodId != null) params['NeighborhoodId'] = neighborhoodId;

    return _client.get<PagedOrders>(
      ApiConstants.deliveryAssigned(deliverymanId),
      queryParameters: params,
      fromJson: (data) =>
          PagedOrders.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<void> selfAssignOrders({
    required List<int> orderIds,
    required String password,
  }) async {
    await _client.post<dynamic>(
      ApiConstants.deliverySelfAssign,
      data: {'orderIds': orderIds, 'password': password},
    );
  }

  /// Detalle completo (líneas, pagos, etc.) — equivalente a `GET .../details` del front.
  Future<Order> getOrderWithDetails(int orderId) async {
    return _client.get<Order>(
      ApiConstants.orderWithDetails(orderId),
      fromJson: (data) => Order.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<Order> updateOrderStatus(int orderId, OrderStatus newStatus) async {
    return _client.put<Order>(
      ApiConstants.orderStatus(orderId),
      data: {'status': newStatus.apiValue},
      fromJson: (data) => Order.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<List<BranchSummary>> getAssignedBranchSummary({
    required int deliverymanId,
    required String fromDate,
    required String toDate,
    String? status,
    bool includeOnsiteActiveInHistory = false,
  }) async {
    final params = <String, dynamic>{
      'fromDate': fromDate,
      'toDate': toDate,
    };
    if (status != null) params['status'] = status;
    if (includeOnsiteActiveInHistory) params['includeOnsiteActiveInHistory'] = true;

    return _client.get<List<BranchSummary>>(
      ApiConstants.deliveryAssignedBranchSummary(deliverymanId),
      queryParameters: params,
      fromJson: (data) {
        final list = data is List ? data : (data as Map)['items'] as List? ?? [];
        return list
            .map((e) => BranchSummary.fromJson(e as Map<String, dynamic>))
            .toList();
      },
    );
  }
}

final orderRepositoryProvider = Provider<OrderRepository>((ref) {
  return OrderRepository(ref.watch(dioClientProvider));
});
