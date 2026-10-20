import 'dart:convert';
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
  'postponed': 'Por ajustar', 'cancelled': 'Cancelado',
};
const leaveSupportStatuses = <String, String>{
  'not_required': 'No requerido', 'pending': 'Por entregar', 'missing': 'Por entregar',
  'submitted': 'Por revisar', 'verified': 'Verificado', 'rejected': 'Por corregir',
};
final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
bool isLeaveId(String id) => _uuid.hasMatch(id);
DateTime leaveColombiaTime(DateTime utc) => utc.toUtc().subtract(const Duration(hours: 5));
DateTime leaveUtcTime(DateTime local) => DateTime.utc(local.year, local.month, local.day, local.hour, local.minute).add(const Duration(hours: 5));
DateTime leaveDayStart(DateTime utc) {
  final civil = leaveColombiaTime(utc);
  return DateTime.utc(civil.year, civil.month, civil.day, 5);
}
String leaveDate(DateTime? value) => value == null ? 'Sin registrar' : DateFormat('dd/MM/yyyy HH:mm').format(leaveColombiaTime(value));
String leaveDay(DateTime value) => DateFormat('dd/MM/yyyy').format(leaveColombiaTime(value));
Map<String, dynamic> leaveMap(dynamic value) => Map<String, dynamic>.from(value as Map);
List<Map<String, dynamic>> leaveEvidence(Map<String, dynamic>? kind) => (kind?['evidence'] as List? ?? []).map(leaveMap).toList();

class LeaveItem {
  final String id, kind, status, branchName, supportStatus;
  final int userId, version;
  final DateTime startsAt, endsAt;
  final bool unread, allDay, periodRecord;
  final bool? requestedIsPaid, isPaid;
  LeaveItem.fromJson(Map<String, dynamic> json)
      : id = json['publicId'] as String, kind = json['kind'] as String,
        status = json['status'] as String, branchName = json['branchName'] as String? ?? '',
        supportStatus = json['supportStatus'] as String? ?? 'not_required',
        userId = (json['userId'] as num).toInt(), version = (json['version'] as num).toInt(),
        startsAt = DateTime.parse(json['startsAt'] as String).toUtc(),
        endsAt = DateTime.parse(json['endsAt'] as String).toUtc(), unread = json['isUnread'] == true,
        allDay = json['isAllDay'] == true, periodRecord = json['isPeriodRecord'] == true,
        requestedIsPaid = json['requestedIsPaid'] as bool?, isPaid = json['isPaid'] as bool? {
    if (!isLeaveId(id) || version < 1) throw const FormatException('Solicitud no válida.');
  }
  String get durationLabel {
    if (periodRecord) return 'Período de pausas · no es ausencia';
    final minutes = endsAt.difference(startsAt).inMinutes;
    if (allDay) { final days = minutes ~/ 1440; return '$days ${days == 1 ? 'día completo' : 'días completos'}'; }
    final h = minutes ~/ 60, m = minutes % 60;
    return h > 0 ? '$h ${h == 1 ? 'hora' : 'horas'}${m > 0 ? ' $m min' : ''}' : '$m min';
  }
  String get periodLabel {
    if (!allDay) return '${leaveDate(startsAt)} → ${leaveDate(endsAt)}';
    final first = leaveDay(startsAt), last = leaveDay(endsAt.subtract(const Duration(milliseconds: 1)));
    return first == last ? first : '$first al $last';
  }
}

class LeaveAttachment {
  final int id, size;
  final String name, contentType, evidenceCode, reviewStatus;
  final String? reviewReason;
  final DateTime? supersededAt;
  final int? replacesAttachmentId;
  LeaveAttachment.fromJson(Map<String, dynamic> json)
      : id = (json['id'] as num).toInt(), size = (json['size'] as num).toInt(),
        name = json['fileName'] as String, contentType = json['contentType'] as String,
        evidenceCode = json['evidenceCode'] as String? ?? 'additional', reviewStatus = json['reviewStatus'] as String? ?? 'submitted',
        reviewReason = json['reviewReason'] as String?, supersededAt = json['supersededAt'] == null ? null : DateTime.parse(json['supersededAt'] as String),
        replacesAttachmentId = (json['replacesAttachmentId'] as num?)?.toInt();
}

class LeaveDetail {
  final LeaveItem request;
  final Map<String, dynamic> fields;
  final List<LeaveAttachment> attachments;
  LeaveDetail.fromJson(Map<String, dynamic> json)
      : request = LeaveItem.fromJson(leaveMap(json['request'])), fields = Map.unmodifiable(json),
        attachments = List.unmodifiable((json['attachments'] as List).map((x) => LeaveAttachment.fromJson(leaveMap(x))));
  String text(String key) => fields[key] as String? ?? '';
  bool flag(String key) => fields[key] == true;
  DateTime? date(String key) => fields[key] == null ? null : DateTime.parse(fields[key] as String).toUtc();
  List<Map<String, dynamic>> get evidence => (fields['evidenceRequirements'] as List? ?? []).map(leaveMap).toList();
  List<LeaveAttachment> get activeAttachments => attachments.where((x) => x.supersededAt == null).toList();
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
  String evidenceCode;
  final int? replacesAttachmentId;
  LeaveUpload(this.key, this.name, this.bytes, {this.evidenceCode = 'additional', this.replacesAttachmentId}) : contentType = leaveFileType(name, bytes);
  void dispose() => bytes.fillRange(0, bytes.length, 0);
}
List<String> missingLeaveEvidence(List<Map<String, dynamic>> rules, List<LeaveUpload> files, List<LeaveAttachment> existing) =>
    rules.where((rule) => rule['required'] == true && rule['stage'] == 'before'
        && !files.any((file) => file.evidenceCode == rule['code'])
        && !existing.any((file) => file.evidenceCode == rule['code'] && file.supersededAt == null && file.reviewStatus != 'rejected'))
      .map((rule) => rule['label'] as String).toList();

class EmployeeLeaveRepository {
  final DioClient client;
  final CancelToken _cancel = CancelToken();
  EmployeeLeaveRepository(this.client);
  void dispose() => _cancel.cancel('La pantalla o la sesión cambió.');
  String _path(String id) {
    if (!isLeaveId(id)) throw const LeaveFailure('No encontramos esta solicitud.');
    return '/employee-leaves/$id';
  }
  Future<dynamic> _request(String path, {String method = 'GET', dynamic data, Map<String, dynamic>? query,
      ResponseType? responseType, ProgressCallback? onProgress}) async {
    try {
      return (await client.dio.request<dynamic>(path, data: data, queryParameters: query, cancelToken: _cancel, onSendProgress: onProgress,
        options: Options(method: method, responseType: responseType, followRedirects: false,
          contentType: data is FormData ? 'multipart/form-data' : 'application/json',
          receiveTimeout: const Duration(seconds: 120)))).data;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final message = error.error is ApiException ? (error.error as ApiException).message
          : status == 409 ? 'La solicitud cambió. Actualiza el detalle y confirma nuevamente.'
          : 'No se pudo completar la operación. Revisa tu conexión e inténtalo de nuevo.';
      error.requestOptions.data = null;
      throw LeaveFailure(message, status);
    } finally {
      if (data is Map) data.remove('password');
      if (data is FormData) data.fields.removeWhere((field) => field.key == 'password' || field.key == 'payload');
    }
  }
  Future<List<Map<String, dynamic>>> catalog() async => (await _request('/employee-leaves/catalog') as List).map(leaveMap).toList();
  Future<int> unread() async => (leaveMap(await _request('/employee-leaves/summary'))['unread'] as num).toInt();
  Future<LeavePage<LeaveItem>> list(int page, String status, {bool? remunerated}) async => LeavePage.fromJson(
      leaveMap(await _request('/employee-leaves', query: {'page': page, 'pageSize': 20, if (status.isNotEmpty) 'status': status,
        if (remunerated != null) 'remunerated': remunerated})), LeaveItem.fromJson);
  Future<LeaveDetail> detail(String id) async => LeaveDetail.fromJson(leaveMap(await _request(_path(id))));
  Future<LeavePage<Map<String, dynamic>>> history(String id, int page) async => LeavePage.fromJson(
      leaveMap(await _request('${_path(id)}/history', query: {'page': page, 'pageSize': 25})), (json) => json);
  Future<void> read(LeaveItem leave) async => _request('${_path(leave.id)}/read', method: 'POST', data: {'version': leave.version});
  Future<String> save(String? id, Map<String, dynamic> fields, String password, {List<LeaveUpload> files = const [], ProgressCallback? onProgress}) async {
    if (id != null) _path(id);
    if (files.length > 5) throw const LeaveFailure('Se permiten hasta cinco documentos.');
    final payload = {...fields}..remove('password');
    final data = FormData();
    data.fields.addAll([MapEntry('payload', jsonEncode(payload)), MapEntry('password', password),
      if (id != null) MapEntry('publicId', id),
      MapEntry('evidence', jsonEncode(files.map((file) => {'uploadKey': file.key, 'evidenceCode': file.evidenceCode}).toList()))]);
    for (final file in files) {
      data.files.add(MapEntry('files', MultipartFile.fromBytes(file.bytes, filename: file.name, contentType: DioMediaType.parse(file.contentType))));
    }
    final result = leaveMap(await _request('/employee-leaves/submit', method: 'POST', data: data, onProgress: onProgress));
    return result['publicId'] as String;
  }
  Future<void> change(LeaveItem leave, String action, String password, {String reason = ''}) async {
    if (action != 'cancel' && action != 'return') throw const LeaveFailure('Acción no disponible en esta aplicación.');
    await _request('${_path(leave.id)}/$action', method: 'POST', data: {'version': leave.version, 'password': password, 'reason': reason});
  }
  Future<void> upload(LeaveItem leave, LeaveUpload file, String password) async {
    final data = FormData.fromMap({'version': leave.version, 'password': password, 'uploadKey': file.key, 'evidenceCode': file.evidenceCode,
      if (file.replacesAttachmentId != null) 'replacesAttachmentId': file.replacesAttachmentId,
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
