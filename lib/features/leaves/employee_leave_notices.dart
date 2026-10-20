import 'dart:async';

class EmployeeLeaveNotice {
  final String requestId;
  final int userId, version;
  const EmployeeLeaveNotice(this.requestId, this.userId, this.version);
  static EmployeeLeaveNotice? parse(Map<String, dynamic> data) {
    if (data['type'] != 'employee_leave_changed') return null;
    final id = data['requestId']?.toString() ?? '';
    final user = int.tryParse(data['userId']?.toString() ?? '');
    final version = int.tryParse(data['version']?.toString() ?? '');
    if (!RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(id)
        || user == null || user < 1 || version == null || version < 1) return null;
    return EmployeeLeaveNotice(id.toLowerCase(), user, version);
  }
  Map<String, dynamic> toJson() => {'type': 'employee_leave_changed', 'requestId': requestId, 'userId': userId, 'version': version};
}

/// Solo metadatos de navegación en memoria; nunca contraseñas, motivos o archivos.
class EmployeeLeaveNotices {
  static final _changes = StreamController<EmployeeLeaveNotice>.broadcast();
  static final _opened = StreamController<EmployeeLeaveNotice>.broadcast();
  static EmployeeLeaveNotice? _pending;
  static Stream<EmployeeLeaveNotice> get changes => _changes.stream;
  static Stream<EmployeeLeaveNotice> get opened => _opened.stream;
  static void receive(Map<String, dynamic> data, {bool opened = false}) {
    final notice = EmployeeLeaveNotice.parse(data);
    if (notice == null) return;
    _changes.add(notice);
    if (opened) { _pending = notice; _opened.add(notice); }
  }
  static EmployeeLeaveNotice? takeFor(int userId) {
    final notice = _pending; _pending = null;
    return notice?.userId == userId ? notice : null;
  }
  static void clear() { _pending = null; }
}
