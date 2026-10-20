import 'package:delivery_app/core/api/dio_client.dart';
import 'package:delivery_app/features/leaves/employee_leave.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReplayClient implements DioClient {
  @override
  final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid/api'));
  late FormData original, replay;
  _ReplayClient(bool fail) {
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) async {
      original = request.data as FormData;
      await original.finalize().drain<void>();
      replay = original.clone();
      request.data = replay;
      final response = Response<dynamic>(requestOptions: request, statusCode: fail ? 409 : 200,
        data: {'publicId': '98e08165-42a1-42d9-a7dc-79e695207f74'});
      if (fail) { handler.reject(DioException(requestOptions: request, response: response)); }
      else { handler.resolve(response); }
    }));
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
void main() {
  for (final fails in [false, true]) {
    test('clears original and replay body after ${fails ? 'failure' : 'success'}', () async {
      final client = _ReplayClient(fails), repository = EmployeeLeaveRepository(_ReplayClient(false));
      repository.dispose();
      final actual = EmployeeLeaveRepository(client); addTearDown(actual.dispose);
      final operation = actual.save(null, {'requestKey': '98e08165-42a1-42d9-a7dc-79e695207f74', 'kind': 'other'}, 'secret-confirmation');
      if (fails) { await expectLater(operation, throwsA(isA<LeaveFailure>())); }
      else { await operation; }
      expect(identical(client.original, client.replay), isFalse);
      for (final body in [client.original, client.replay]) {
        expect(body.fields.any((x) => x.key == 'password' || x.key == 'payload'), isFalse);
      }
    });
  }
}
