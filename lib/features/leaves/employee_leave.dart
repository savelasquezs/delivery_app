import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/dio_client.dart';
import '../auth/presentation/auth_notifier.dart';

const leaveMaxBytes = 5 * 1024 * 1024;
const leaveStatuses = <String, String>{
  'pending': 'Pendiente', 'approved': 'Aprobado', 'denied': 'Denegado',
  'postponed': 'Aplazado', 'cancelled': 'Cancelado',
};
const leaveSupportStatuses = <String, String>{
  'not_required': 'No requerido', 'pending': 'Pendiente de adjuntar',
  'submitted': 'Presentado', 'verified': 'Verificado', 'rejected': 'Rechazado',
};
final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
bool isLeaveId(String id) => _uuid.hasMatch(id);
DateTime leaveColombiaTime(DateTime utc) => utc.toUtc().subtract(const Duration(hours: 5));
DateTime leaveUtcTime(DateTime local) => DateTime.utc(local.year, local.month, local.day, local.hour, local.minute).add(const Duration(hours: 5));
String leaveDate(DateTime? value) => value == null ? 'Sin registrar' : DateFormat('dd/MM/yyyy HH:mm').format(leaveColombiaTime(value));
Map<String, dynamic> leaveMap(dynamic value) => Map<String, dynamic>.from(value as Map);

class LeaveItem {
  final String id, kind, status, branchName;
  final int userId, version;
  final DateTime startsAt, endsAt;
  final bool unread;
  LeaveItem.fromJson(Map<String, dynamic> json)
      : id = json['publicId'] as String, kind = json['kind'] as String,
        status = json['status'] as String, branchName = json['branchName'] as String? ?? '',
        userId = (json['userId'] as num).toInt(), version = (json['version'] as num).toInt(),
        startsAt = DateTime.parse(json['startsAt'] as String).toUtc(),
        endsAt = DateTime.parse(json['endsAt'] as String).toUtc(), unread = json['isUnread'] == true {
    if (!isLeaveId(id) || version < 1) throw const FormatException('Solicitud no válida.');
  }
}

class LeaveAttachment {
  final int id, size;
  final String name, contentType;
  LeaveAttachment.fromJson(Map<String, dynamic> json)
      : id = (json['id'] as num).toInt(), size = (json['size'] as num).toInt(),
        name = json['fileName'] as String, contentType = json['contentType'] as String;
}

class LeaveDetail {
  final LeaveItem request;
  final Map<String, dynamic> fields;
  final List<LeaveAttachment> attachments;
  LeaveDetail.fromJson(Map<String, dynamic> json)
      : request = LeaveItem.fromJson(leaveMap(json['request'])),
        fields = Map.unmodifiable(json),
        attachments = List.unmodifiable((json['attachments'] as List).map((x) => LeaveAttachment.fromJson(leaveMap(x))));
  String text(String key) => fields[key] as String? ?? '';
  bool flag(String key) => fields[key] == true;
  DateTime? date(String key) => fields[key] == null ? null : DateTime.parse(fields[key] as String).toUtc();
}

class LeavePage<T> {
  final List<T> items;
  final int page, totalPages;
  LeavePage.fromJson(Map<String, dynamic> json, T Function(Map<String, dynamic>) parse)
      : items = List.unmodifiable((json['items'] as List).map((x) => parse(leaveMap(x)))),
        page = (json['page'] as num).toInt(), totalPages = (json['totalPages'] as num).toInt();
}

class LeaveFailure implements Exception {
  final String message;
  final int? statusCode;
  const LeaveFailure(this.message, [this.statusCode]);
  bool get conflict => statusCode == 409;
  @override
  String toString() => message;
}

String leaveFileType(String name, List<int> content) {
  if (content.isEmpty || content.length > leaveMaxBytes) throw const LeaveFailure('Adjunta un archivo de máximo 5 MB.');
  final ext = name.split('.').last.toLowerCase();
  bool prefix(List<int> bytes) => content.length >= bytes.length && List.generate(bytes.length, (i) => content[i] == bytes[i]).every((x) => x);
  if (ext == 'pdf' && prefix([37, 80, 68, 70, 45])) return 'application/pdf';
  if ((ext == 'jpg' || ext == 'jpeg') && prefix([255, 216, 255])) return 'image/jpeg';
  if (ext == 'png' && prefix([137, 80, 78, 71, 13, 10, 26, 10])) return 'image/png';
  throw const LeaveFailure('El contenido debe ser un PDF, JPG o PNG válido.');
}

class LeaveUpload {
  final String key, name, contentType;
  final Uint8List bytes;
  LeaveUpload(this.key, this.name, this.bytes) : contentType = leaveFileType(name, bytes);
  void dispose() => bytes.fillRange(0, bytes.length, 0);
}

class EmployeeLeaveRepository {
  final DioClient client;
  final CancelToken _cancel = CancelToken();
  EmployeeLeaveRepository(this.client);
  void dispose() => _cancel.cancel('La pantalla o la sesión cambió.');
  String _path(String id) {
    if (!isLeaveId(id)) throw const LeaveFailure('No encontramos esta solicitud.');
    return '/employee-leaves/$id';
  }
  Future<dynamic> _request(String path, {String method = 'GET', dynamic data, Map<String, dynamic>? query, ResponseType? responseType}) async {
    try {
      return (await client.dio.request<dynamic>(path, data: data, queryParameters: query, cancelToken: _cancel,
        options: Options(method: method, responseType: responseType, followRedirects: false,
          contentType: data is FormData ? 'multipart/form-data' : 'application/json',
          receiveTimeout: const Duration(seconds: 60)))).data;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final message = error.error is ApiException ? (error.error as ApiException).message
          : status == 409 ? 'La solicitud cambió. Actualiza el detalle y confirma nuevamente.'
          : 'No se pudo completar la operación. Revisa tu conexión e inténtalo de nuevo.';
      error.requestOptions.data = null;
      throw LeaveFailure(message, status);
    } finally {
      if (data is Map) data.remove('password');
      if (data is FormData) data.fields.removeWhere((field) => field.key == 'password');
    }
  }
  Future<List<Map<String, dynamic>>> catalog() async =>
      (await _request('/employee-leaves/catalog') as List).map(leaveMap).toList();
  Future<int> unread() async => (leaveMap(await _request('/employee-leaves/summary'))['unread'] as num).toInt();
  Future<LeavePage<LeaveItem>> list(int page, String status) async => LeavePage.fromJson(
      leaveMap(await _request('/employee-leaves', query: {'page': page, 'pageSize': 20, if (status.isNotEmpty) 'status': status})), LeaveItem.fromJson);
  Future<LeaveDetail> detail(String id) async => LeaveDetail.fromJson(leaveMap(await _request(_path(id))));
  Future<LeavePage<Map<String, dynamic>>> history(String id, int page) async => LeavePage.fromJson(
      leaveMap(await _request('${_path(id)}/history', query: {'page': page, 'pageSize': 25})), (json) => json);
  Future<void> read(LeaveItem leave) async => _request('${_path(leave.id)}/read', method: 'POST', data: {'version': leave.version});
  Future<String> save(String? id, Map<String, dynamic> fields, String password) async {
    final result = leaveMap(await _request(id == null ? '/employee-leaves' : _path(id),
        method: id == null ? 'POST' : 'PUT', data: {...fields, 'password': password}));
    return result['publicId'] as String;
  }
  Future<void> change(LeaveItem leave, String action, String password, {String reason = ''}) async {
    if (action != 'cancel' && action != 'return') throw const LeaveFailure('Acción no disponible en esta aplicación.');
    await _request('${_path(leave.id)}/$action', method: 'POST', data: {'version': leave.version, 'password': password, 'reason': reason});
  }
  Future<void> upload(LeaveItem leave, LeaveUpload file, String password) async {
    final data = FormData.fromMap({'version': leave.version, 'password': password, 'uploadKey': file.key,
      'file': MultipartFile.fromBytes(file.bytes, filename: file.name, contentType: DioMediaType.parse(file.contentType))});
    await _request('${_path(leave.id)}/attachments', method: 'POST', data: data);
  }
  Future<void> remove(LeaveItem leave, LeaveAttachment file, String password, String reason) async =>
      _request('${_path(leave.id)}/attachments/${file.id}', method: 'DELETE', data: {'version': leave.version, 'password': password, 'reason': reason});
  Future<Uint8List> download(LeaveItem leave, LeaveAttachment file) async {
    if (file.size < 1 || file.size > leaveMaxBytes) throw const LeaveFailure('El tamaño del soporte no es válido.');
    final data = await _request('${_path(leave.id)}/attachments/${file.id}', responseType: ResponseType.bytes);
    final bytes = Uint8List.fromList(List<int>.from(data as List));
    if (bytes.length != file.size) throw const LeaveFailure('La descarga quedó incompleta. Inténtalo de nuevo.');
    leaveFileType(file.name, bytes);
    return bytes;
  }
}

final employeeLeaveRepositoryProvider = Provider.autoDispose<EmployeeLeaveRepository>((ref) {
  ref.watch(authNotifierProvider.select((state) => (state.status, state.user?.id)));
  final repository = EmployeeLeaveRepository(ref.watch(dioClientProvider));
  ref.onDispose(repository.dispose);
  return repository;
});
final employeeLeaveUnreadProvider = FutureProvider.autoDispose<int>((ref) {
  final auth = ref.watch(authNotifierProvider);
  if (auth.status != AuthStatus.authenticated) return Future.value(0);
  return ref.watch(employeeLeaveRepositoryProvider).unread();
});
