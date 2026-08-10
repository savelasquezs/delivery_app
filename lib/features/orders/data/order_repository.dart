import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_constants.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/api/dio_client.dart';
import '../models/order_models.dart';
import '../models/print_job_models.dart';

class OrderRepository {
  final DioClient _client;
  final PrintJobRequestCoordinator _printCoordinator;

  OrderRepository(
    this._client, {
    PrintJobRequestCoordinator? printCoordinator,
  }) : _printCoordinator = printCoordinator ?? PrintJobRequestCoordinator();

  Future<List<Order>> getAvailableOrders({int? branchId}) async {
    final params = <String, dynamic>{};
    if (branchId != null) params['branchId'] = branchId;

    return _client.get<List<Order>>(
      ApiConstants.deliveryAvailable,
      queryParameters: params.isEmpty ? null : params,
      fromJson: _parseOrderList,
    );
  }

  /// El backend solo devuelve estos pedidos si la ubicación está dentro del
  /// radio configurado para la sucursal del domiciliario autenticado.
  Future<List<Order>> getPreparationAndTakenOrders({
    required double latitude,
    required double longitude,
  }) async {
    return _client.post<List<Order>>(
      ApiConstants.deliveryPreparationNearBranch,
      data: {'latitude': latitude, 'longitude': longitude},
      fromJson: _parseOrderList,
    );
  }

  static List<Order> _parseOrderList(dynamic data) {
    if (data is List) {
      return data
          .map((e) => Order.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    final items = (data as Map<String, dynamic>)['items'] as List?;
    return (items ?? [])
        .map((e) => Order.fromJson(e as Map<String, dynamic>))
        .toList();
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
    if (includeOnsiteActiveInHistory) {
      params['IncludeOnsiteActiveInHistory'] = true;
    }
    if (neighborhoodId != null) params['NeighborhoodId'] = neighborhoodId;

    return _client.get<PagedOrders>(
      ApiConstants.deliveryAssigned(deliverymanId),
      queryParameters: params,
      fromJson: (data) => PagedOrders.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<void> selfAssignOrders({
    required List<int> orderIds,
    required String password,
    int? proposalId,
    int? expectedPlanVersion,
  }) async {
    await _client.post<dynamic>(
      ApiConstants.deliverySelfAssign,
      data: {
        'orderIds': orderIds,
        'password': password,
        if (proposalId != null) 'proposalId': proposalId,
        if (expectedPlanVersion != null)
          'expectedPlanVersion': expectedPlanVersion,
      },
    );
  }

  /// Encola reimpresión de ticket de domicilio (`kind: delivery`).
  Future<EnqueuePrintJobResult> enqueueDeliveryPrintJob({
    required int branchId,
    required List<int> orderIds,
  }) {
    final normalizedIds = orderIds.toSet().toList()..sort();
    final key = '$branchId:${normalizedIds.join(',')}';
    return _printCoordinator.run(
      key,
      () => _client.post<EnqueuePrintJobResult>(
        ApiConstants.branchPrintJobs(branchId),
        data: {'kind': 'delivery', 'orderIds': normalizedIds},
        fromJson: (data) => EnqueuePrintJobResult.fromJson(
          _unwrapApiEnvelope(data),
        ),
      ),
    );
  }

  Future<PrintJobStatusResult> getPrintJobStatus({
    required int branchId,
    required int jobId,
  }) {
    return _client.get<PrintJobStatusResult>(
      ApiConstants.branchPrintJobStatus(branchId, jobId),
      fromJson: (data) => PrintJobStatusResult.fromJson(
        _unwrapApiEnvelope(data),
      ),
    );
  }

  static Map<String, dynamic> _unwrapApiEnvelope(dynamic data) {
    if (data is! Map) {
      throw const ApiException('Respuesta inválida del servidor');
    }
    final map = Map<String, dynamic>.from(data);
    final ok = map['isSuccess'] as bool? ?? map['IsSuccess'] as bool?;
    if (ok == false) {
      final msg = map['message'] as String? ??
          map['Message'] as String? ??
          'No se pudo encolar la impresión';
      throw ApiException(msg);
    }
    final payload = map['data'] ?? map['Data'];
    if (payload is! Map) {
      throw const ApiException('Respuesta incompleta del servidor');
    }
    return Map<String, dynamic>.from(payload);
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
    if (includeOnsiteActiveInHistory) {
      params['includeOnsiteActiveInHistory'] = true;
    }

    return _client.get<List<BranchSummary>>(
      ApiConstants.deliveryAssignedBranchSummary(deliverymanId),
      queryParameters: params,
      fromJson: (data) {
        final list =
            data is List ? data : (data as Map)['items'] as List? ?? [];
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
