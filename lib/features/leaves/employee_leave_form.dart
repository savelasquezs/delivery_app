import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../auth/presentation/auth_notifier.dart';
import 'employee_leave.dart';
import 'employee_leave_confirmation.dart';
import 'employee_leave_widgets.dart';
export 'employee_leave_confirmation.dart' show confirmEmployeeLeave;

class EmployeeLeaveFormScreen extends ConsumerStatefulWidget {
  final LeaveDetail? detail;
  const EmployeeLeaveFormScreen({super.key, this.detail});
  @override
  ConsumerState<EmployeeLeaveFormScreen> createState() => _EmployeeLeaveFormState();
}
class _EmployeeLeaveFormState extends ConsumerState<EmployeeLeaveFormScreen> {
  final formKey = GlobalKey<FormState>();
  final justification = TextEditingController();
  final requestKey = const Uuid().v4();
  final List<LeaveUpload> files = [];
  late Future<List<Map<String, dynamic>>> catalog;
  List<Map<String, dynamic>> kinds = [];
  late DateTime startsAt, endsAt;
  late final int? ownerId;
  String group = '';
  String? kind;
  bool fullDays = false, busy = false, picking = false;
  String? error;
  Map<String, dynamic>? get selectedKind {
    for (final item in kinds) { if (item['code'] == kind) return item; }
    return null;
  }
  bool get allDay => fullDays || selectedKind?['isPeriodRecord'] == true;
  List<LeaveAttachment> get existingEvidence => (widget.detail?.activeAttachments ?? []).map((file) => widget.detail?.request.kind == kind ? file
      : LeaveAttachment.fromJson({'id': file.id, 'size': file.size, 'fileName': file.name, 'contentType': file.contentType, 'evidenceCode': 'additional'})).toList();
  @override
  void initState() {
    super.initState(); ownerId = ref.read(authNotifierProvider).user?.id;
    final detail = widget.detail;
    startsAt = detail?.request.startsAt ?? DateTime.now().toUtc();
    endsAt = detail?.request.endsAt ?? startsAt.add(const Duration(hours: 1));
    fullDays = detail?.request.allDay ?? false;
    if (fullDays) endsAt = endsAt.subtract(const Duration(days: 1));
    kind = detail?.request.kind;
    justification.text = detail?.text('justification') ?? '';
    catalog = loadCatalog();
  }
  Future<List<Map<String, dynamic>>> loadCatalog() async {
    final data = await ref.read(employeeLeaveRepositoryProvider).catalog();
    if (mounted && ownerId == ref.read(authNotifierProvider).user?.id) {
      kinds = data;
      if (kind != null && group.isEmpty) group = selectedKind?['paidByCompanyPolicy'] == true ? 'paid' : 'unpaid';
    }
    return data;
  }
  void clearFiles() { for (final file in files) { file.dispose(); } files.clear(); }
  @override
  void dispose() { clearFiles(); justification.dispose(); super.dispose(); }
  Future<void> pickTime(bool start) async {
    final initial = leaveColombiaTime(start ? startsAt : endsAt);
    final day = await showDatePicker(context: context, initialDate: initial,
      firstDate: DateTime(initial.year - 2), lastDate: DateTime(initial.year + 2, 12, 31));
    if (day == null || !mounted) return;
    var time = TimeOfDay(hour: initial.hour, minute: initial.minute);
    if (!allDay) {
      final selected = await showTimePicker(context: context, initialTime: time);
      if (selected == null || !mounted) return;
      time = selected;
    }
    final utc = leaveUtcTime(DateTime(day.year, day.month, day.day, time.hour, time.minute));
    setState(() { if (start) { startsAt = utc; } else { endsAt = utc; } error = null; });
  }
  Future<void> addFile() async {
    if (busy || picking || files.length + existingEvidence.length >= 5) return;
    setState(() { picking = true; error = null; });
    try {
      final rules = leaveEvidence(selectedKind);
      final missing = rules.where((rule) => rule['required'] == true && rule['stage'] == 'before'
          && !files.any((x) => x.evidenceCode == rule['code']) && !existingEvidence.any((x) => x.evidenceCode == rule['code'] && x.reviewStatus != 'rejected')).toList();
      final code = missing.isNotEmpty ? missing.first['code'] as String : rules.isNotEmpty ? rules.first['code'] as String : 'additional';
      final file = await pickLeaveUpload(evidenceCode: code);
      if (!mounted || ownerId != ref.read(authNotifierProvider).user?.id) { file?.dispose(); return; }
      if (file != null) setState(() => files.add(file));
    } catch (failure) { if (mounted) setState(() => error = failure is LeaveFailure ? failure.message : 'No se pudo leer el documento.'); }
    finally { if (mounted) setState(() => picking = false); }
  }
  Future<void> save() async {
    if (busy || picking || formKey.currentState?.validate() != true) return;
    final selected = selectedKind;
    if (group.isEmpty || selected == null) { setState(() => error = 'Selecciona la remuneración y el motivo.'); return; }
    final start = allDay ? leaveDayStart(startsAt) : startsAt;
    final end = allDay ? leaveDayStart(endsAt).add(const Duration(days: 1)) : endsAt;
    if (!end.isAfter(start) || end.difference(start) > const Duration(days: 366)) {
      setState(() => error = 'Revisa las fechas. El final debe ser posterior y el intervalo no puede superar 366 días.'); return;
    }
    final missing = missingLeaveEvidence(leaveEvidence(selected), files, existingEvidence);
    if (missing.isNotEmpty) { setState(() => error = 'Adjunta antes de enviar: ${missing.join(', ')}.'); return; }
    final fields = <String, dynamic>{'requestKey': requestKey, 'version': widget.detail?.request.version ?? 0,
      'kind': kind, 'requestedIsPaid': group == 'paid', 'isAllDay': allDay,
      'documentNumber': widget.detail?.fields['documentNumber'], 'justification': justification.text.trim(),
      'startsAt': start.toIso8601String(), 'endsAt': end.toIso8601String(), 'supportRequired': false};
    setState(() { busy = true; error = null; });
    String? id;
    try {
      final repository = ref.read(employeeLeaveRepositoryProvider);
      final confirmed = await confirmEmployeeLeave(context, 'Enviar solicitud y ${files.length} documentos', (password) async {
        if (ownerId != ref.read(authNotifierProvider).user?.id) throw const LeaveFailure('La sesión cambió.');
        id = await repository.save(widget.detail?.request.id, fields, password, files: files);
      });
      if (!mounted) return;
      if (confirmed && id != null) { ref.invalidate(employeeLeaveUnreadProvider); Navigator.pop(context, id); }
    } on LeaveFailure catch (failure) {
      if (!mounted) return;
      if (failure.conflict && widget.detail != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.message))); Navigator.pop(context);
      } else { setState(() => error = failure.message); }
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    ref.watch(employeeLeaveRepositoryProvider);
    ref.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next.user?.id != ownerId || next.status != AuthStatus.authenticated) {
        clearFiles(); justification.clear();
        if (mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
      }
    });
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return PopScope(canPop: !busy && !picking, child: Scaffold(
      appBar: AppBar(title: Text(widget.detail == null ? 'Solicitar permiso' : 'Modificar solicitud')),
      bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(onPressed: busy || picking || kinds.isEmpty ? null : save,
          icon: const Icon(Icons.lock_outline, size: 18), label: const Text('Revisar y enviar')))),
      body: FutureBuilder<List<Map<String, dynamic>>>(future: catalog, builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: TextButton(onPressed: () => setState(() => catalog = loadCatalog()), child: const Text('Reintentar formulario')));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final selected = selectedKind;
        final filtered = kinds.where((item) => item['paidByCompanyPolicy'] == (group == 'paid')).toList();
        return Form(key: formKey, child: ListView(padding: const EdgeInsets.all(16), children: [
          Padding(padding: const EdgeInsets.only(bottom: 16), child: Text('Solicitud personal · Hora de Colombia', style: muted)),
          LeaveSectionCard(title: '1. Tipo de permiso', icon: Icons.event_note_outlined, children: [
            SizedBox(width: double.infinity, child: SegmentedButton<String>(showSelectedIcon: false, emptySelectionAllowed: true,
              selected: {if (group.isNotEmpty) group}, segments: const [ButtonSegment(value: 'paid', label: Text('Remunerado')), ButtonSegment(value: 'unpaid', label: Text('No remunerado'))],
              onSelectionChanged: busy || picking ? null : (values) => setState(() { group = values.isEmpty ? '' : values.first; kind = null; clearFiles(); error = null; }))),
            if (group.isNotEmpty) DropdownButtonFormField<String>(key: ValueKey('$group:$kind'), initialValue: kind, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Motivo del permiso *'),
              items: filtered.map((item) => DropdownMenuItem(value: item['code'] as String, child: Text(item['label'] as String, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: busy || picking ? null : (value) => setState(() { kind = value; clearFiles(); error = null; }),
              validator: (value) => value == null ? 'Selecciona un motivo.' : null),
            if (selected != null && (selected['description'] as String? ?? '').isNotEmpty) Text(selected['description'] as String, style: muted),
          ]),
          if (selected != null) ...[
            LeaveSectionCard(title: selected['isPeriodRecord'] == true ? '2. Período de las pausas' : '2. Fechas y duración', icon: Icons.schedule_outlined, children: [
              if (selected['isPeriodRecord'] != true) SegmentedButton<bool>(selected: {fullDays}, segments: const [
                ButtonSegment(value: false, label: Text('Por horas')), ButtonSegment(value: true, label: Text('Días completos'))],
                onSelectionChanged: busy ? null : (value) => setState(() => fullDays = value.single)),
              ListTile(contentPadding: EdgeInsets.zero, title: Text(allDay ? 'Desde *' : 'Inicio *'), subtitle: Text(allDay ? leaveDay(startsAt) : leaveDate(startsAt)),
                trailing: const Icon(Icons.calendar_month_outlined), onTap: busy ? null : () => pickTime(true)),
              ListTile(contentPadding: EdgeInsets.zero, title: Text(allDay ? 'Hasta (incluido) *' : 'Fin previsto *'), subtitle: Text(allDay ? leaveDay(endsAt) : leaveDate(endsAt)),
                trailing: const Icon(Icons.calendar_month_outlined), onTap: busy ? null : () => pickTime(false)),
              if (allDay) Text(selected['isPeriodRecord'] == true ? 'Registro del período, no de cada pausa. No es una ausencia de días completos.'
                : 'Incluye las dos fechas. No convierte días completos en horas laborales ni descuentos.', style: muted),
            ]),
            LeaveSectionCard(title: '3. Motivo y documentos', icon: Icons.description_outlined, children: [
              TextFormField(controller: justification, enabled: !busy, minLines: 3, maxLines: 6, maxLength: 2000,
                decoration: const InputDecoration(labelText: 'Justificación *', hintText: 'Explica brevemente por qué necesitas el permiso…'),
                validator: (value) => value == null || value.trim().isEmpty ? 'Escribe la justificación.' : null),
              LeaveEvidencePicker(files: files, requirements: leaveEvidence(selected), existing: existingEvidence, disabled: busy || picking,
                onAdd: addFile, onRemove: (file) => setState(() { files.remove(file); file.dispose(); }),
                onPurpose: (file, code) => setState(() => file.evidenceCode = code)),
              if (picking) const LinearProgressIndicator(),
            ]),
          ],
          if (error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (widget.detail != null) Text('La modificación vuelve a revisión y conserva el historial anterior.', style: muted),
        ]));
      }),
    ));
  }
}
