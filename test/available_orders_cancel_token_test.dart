import 'package:delivery_app/core/api/api_constants.dart';
import 'package:delivery_app/core/api/dio_client.dart';
import 'package:delivery_app/features/orders/data/order_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _CaptureClient extends Fake implements DioClient {
  String? lastPath;
  Map<String, dynamic>? lastParams;
  CancelToken? lastCancel;
  @override
  Future<T> get<T>(String path, {
    Map<String, dynamic>? queryParameters,
    T Function(dynamic)? fromJson,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    lastPath = path;
    lastParams = queryParameters;
    lastCancel = cancelToken;
    return fromJson!(<dynamic>[]);
  }
}

void main() {
  test('available-orders repository passes the cancellation token and branch to Dio', () async {
    final client = _CaptureClient();
    final token = CancelToken();
    final orders = await OrderRepository(client).getAvailableOrders(
        branchId: 8, cancelToken: token);
    expect(orders, isEmpty);
    expect(client.lastPath, ApiConstants.deliveryAvailable);
    expect(client.lastParams, {'branchId': 8});
    expect(identical(client.lastCancel, token), isTrue);
  });
}
