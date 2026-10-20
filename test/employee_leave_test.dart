import 'dart:convert';
import 'dart:typed_data';
import 'package:delivery_app/core/api/dio_client.dart';
import 'package:delivery_app/features/auth/data/auth_models.dart';
import 'package:delivery_app/features/auth/presentation/auth_notifier.dart';
import 'package:delivery_app/features/leaves/employee_leave.dart';
import 'package:delivery_app/features/leaves/employee_leave_form.dart';
import 'package:delivery_app/features/leaves/employee_leave_notices.dart';
import 'package:delivery_app/features/lunch/employee_lunch_control.dart';
import 'package:delivery_app/features/notifications/fcm_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const requestId = '98e08165-42a1-42d9-a7dc-79e695207f74';
const uploadId = '79aa29c2-bf3d-43a4-ab04-683ad36ccce8';
final sample = <String, dynamic>{'publicId': requestId, 'userId': 7, 'branchId': 1, 'branchName': 'Santander',
  'kind': 'other', 'status': 'pending', 'version': 3, 'isUnread': true,
  'startsAt': '2026-10-21T17:00:00Z', 'endsAt': '2026-10-21T18:00:00Z'};

class _Client implements DioClient {
  @override
  final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid/api'));
  final List<RequestOptions> requests = [];
  final List<Map<String, dynamic>> snapshots = [];
  int? rejectStatus;
  dynamic response = <String, dynamic>{'publicId': requestId};
  _Client() {
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      final data = options.data;
      snapshots.add(data is Map ? Map<String, dynamic>.from(data)
          : data is FormData ? Map<String, dynamic>.fromEntries(data.fields) : {});
      final result = Response<dynamic>(requestOptions: options, statusCode: rejectStatus ?? 200, data: response);
      if (rejectStatus != null) {
        handler.reject(DioException(requestOptions: options, response: result, type: DioExceptionType.badResponse));
      } else { handler.resolve(result); }
    }));
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth extends StateNotifier<AuthState> implements AuthNotifier {
  _Auth() : super(const AuthState(status: AuthStatus.authenticated,
    user: AuthUser(id: 7, name: 'Persona', email: 'persona@example.com', role: 'deliveryman')));
  void replace(AuthState value) => state = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(EmployeeLeaveNotices.clear);
  test('el catálogo, la bandeja y el detalle usan contratos del backend', () async {
    final client = _Client(), repository = EmployeeLeaveRepository(_Client());
    repository.dispose();
    final actual = EmployeeLeaveRepository(client);
    addTearDown(actual.dispose);
    client.response = {'items': [sample], 'page': 2, 'totalPages': 3};
    final page = await actual.list(2, 'pending');
    expect(page.items.single.id, requestId);
    expect(page.page, 2);
    expect(client.requests.single.queryParameters, {'page': 2, 'pageSize': 20, 'status': 'pending'});
    client.response = {'request': sample, 'justification': 'Una diligencia', 'attachments': [], 'canEdit': true};
    final detail = await actual.detail(requestId);
    expect(detail.flag('canEdit'), isTrue);
    expect(detail.request.unread, isTrue);
    expect(detail.text('justification'), 'Una diligencia');
  });
  test('crear y modificar confirman contraseña sin login ni guardar identidad ajena', () async {
    final client = _Client(), fields = <String, dynamic>{'requestKey': requestId, 'kind': 'other', 'version': 0};
    final repository = EmployeeLeaveRepository(client); addTearDown(repository.dispose);
    await repository.save(null, fields, 'current-password');
    await repository.save(requestId, {...fields, 'version': 3}, 'current-password');
    expect(client.requests.map((x) => x.method), ['POST', 'PUT']);
    expect(client.requests.every((x) => x.path.startsWith('/employee-leaves')), isTrue);
    expect(client.snapshots.every((x) => x['password'] == 'current-password'), isTrue);
    expect(client.snapshots.every((x) => !x.containsKey('userId')), isTrue);
    expect(client.requests.every((x) => !(x.data as Map).containsKey('password')), isTrue);
    expect(fields.containsKey('password'), isFalse);
  });
  test('un conflicto conserva su clasificación y elimina la contraseña de la excepción HTTP', () async {
    final client = _Client()..rejectStatus = 409;
    final repository = EmployeeLeaveRepository(client); addTearDown(repository.dispose);
    await expectLater(repository.change(LeaveItem.fromJson(sample), 'return', 'secret'),
      throwsA(isA<LeaveFailure>().having((x) => x.conflict, 'conflict', isTrue)));
    expect(client.requests.single.data, isNull);
  });
  test('el móvil no ejecuta decisiones administrativas y rechaza identificadores de navegación inválidos', () async {
    final client = _Client(), repository = EmployeeLeaveRepository(_Client()); repository.dispose();
    final actual = EmployeeLeaveRepository(client); addTearDown(actual.dispose);
    await expectLater(actual.change(LeaveItem.fromJson(sample), 'decision', 'secret'), throwsA(isA<LeaveFailure>()));
    await expectLater(actual.detail('../other-user'), throwsA(isA<LeaveFailure>()));
    expect(client.requests, isEmpty);
  });
  test('reintentar soporte conserva UploadKey y usa multipart sin persistir la contraseña', () async {
    final client = _Client(), bytes = Uint8List.fromList(utf8.encode('%PDF-1.7\nexample'));
    final repository = EmployeeLeaveRepository(client); addTearDown(repository.dispose);
    final file = LeaveUpload(uploadId, 'soporte.pdf', bytes);
    await repository.upload(LeaveItem.fromJson(sample), file, 'secret');
    await repository.upload(LeaveItem.fromJson(sample), file, 'secret');
    expect(client.snapshots.map((x) => x['uploadKey']), [uploadId, uploadId]);
    expect(client.requests.every((x) => !(x.data as FormData).fields.any((f) => f.key == 'password')), isTrue);
    expect(client.requests.first.contentType, startsWith('multipart/form-data'));
    file.dispose(); expect(bytes.every((x) => x == 0), isTrue);
  });
  test('el refresh recrea el stream multipart ya consumido', () async {
    final body = FormData.fromMap({'password': 'secret', 'uploadKey': uploadId,
      'file': MultipartFile.fromBytes(utf8.encode('%PDF-1.7\nexample'), filename: 'soporte.pdf')});
    await body.finalize().drain<void>();
    final retry = replayableRequestBody(body) as FormData;
    expect(identical(body, retry), isFalse);
    final bytes = await retry.finalize().expand((chunk) => chunk).toList();
    final content = utf8.decode(bytes);
    expect(content, contains('%PDF-1.7\nexample'));
    expect(content, contains(uploadId));
    expect(content, contains('secret'));
  });
  test('valida contenido real y límites de soportes', () {
    expect(leaveFileType('soporte.PDF', utf8.encode('%PDF-1.7')), 'application/pdf');
    expect(leaveFileType('foto.jpg', [255,216,255,0]), 'image/jpeg');
    expect(leaveFileType('foto.png', [137,80,78,71,13,10,26,10]), 'image/png');
    expect(() => leaveFileType('foto.jpg', utf8.encode('%PDF-1.7')), throwsA(isA<LeaveFailure>()));
    expect(() => leaveFileType('archivo.pdf', []), throwsA(isA<LeaveFailure>()));
    expect(() => leaveFileType('archivo.pdf', Uint8List(leaveMaxBytes + 1)), throwsA(isA<LeaveFailure>()));
  });
  test('las horas de Colombia no dependen del huso horario del teléfono', () {
    final utc = DateTime.utc(2026,10,21,2,30);
    final local = leaveColombiaTime(utc);
    expect([local.day, local.hour, local.minute], [20,21,30]);
    expect(leaveUtcTime(local), utc);
  });
  test('solo la ruta personal de permisos evita el bloqueo de almuerzo', () {
    expect(isPersonalLeavePath('/permisos'), isTrue);
    expect(isPersonalLeavePath('/permisos/$requestId'), isTrue);
    expect(isPersonalLeavePath('/permisos-other'), isFalse);
    expect(isPersonalLeavePath('/'), isFalse);
  });
  test('la notificación valida tipo, UUID, usuario y versión; otro usuario no la hereda', () {
    final data = {'type': 'employee_leave_changed', 'requestId': requestId, 'userId': '7', 'version': '3'};
    EmployeeLeaveNotices.receive(data, opened: true);
    expect(EmployeeLeaveNotices.takeFor(8), isNull);
    expect(EmployeeLeaveNotices.takeFor(7), isNull);
    EmployeeLeaveNotices.receive(data, opened: true);
    expect(EmployeeLeaveNotices.takeFor(7)?.requestId, requestId);
    expect(EmployeeLeaveNotice.parse({...data, 'requestId': 'https://other.invalid'}), isNull);
    expect(EmployeeLeaveNotice.parse({...data, 'version': '0'}), isNull);
    expect(EmployeeLeaveNotice.parse({...data, 'type': 'work_session_closed'}), isNull);
    expect(DeliveryTrackingReviewNotice.fromData(data), isNull);
  });
  testWidgets('una contraseña errónea se borra, no cierra sesión y debe escribirse de nuevo', (tester) async {
    final auth = _Auth(); var calls = 0;
    await tester.pumpWidget(ProviderScope(overrides: [authNotifierProvider.overrideWith((ref) => auth)],
      child: MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => confirmEmployeeLeave(context, 'Enviar solicitud', (password) async {
          calls++; expect(password, 'correct-password');
          if (calls == 1) throw const LeaveFailure('Contraseña incorrecta', 400);
        }), child: const Text('Abrir')))))));
    await tester.tap(find.text('Abrir')); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('leave-password')), 'correct-password');
    await tester.tap(find.text('Confirmar')); await tester.pumpAndSettle();
    expect(find.text('Contraseña incorrecta'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('leave-password'))).controller!.text, isEmpty);
    expect(auth.state.status, AuthStatus.authenticated);
    await tester.enterText(find.byKey(const Key('leave-password')), 'correct-password');
    await tester.tap(find.text('Confirmar')); await tester.pumpAndSettle();
    expect(calls, 2); expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
