import 'dart:async';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../auth/presentation/auth_notifier.dart';
import 'employee_leave.dart';
import 'employee_leave_form.dart';
import 'employee_leave_notices.dart';
import 'employee_leave_widgets.dart';

class EmployeeLeaveDetailScreen extends ConsumerStatefulWidget {
  final String publicId;
  const EmployeeLeaveDetailScreen({super.key, required this.publicId});
  @override
  ConsumerState<EmployeeLeaveDetailScreen> createState() => _EmployeeLeaveDetailState();
}
class _EmployeeLeaveDetailState extends ConsumerState<EmployeeLeaveDetailScreen> with WidgetsBindingObserver {
  late Future<LeaveDetail> future;
  late Future<LeavePage<Map<String, dynamic>>> history;
  late Future<List<Map<String, dynamic>>> catalog;
  late final int? ownerId;
  StreamSubscription<EmployeeLeaveNotice>? subscription;
  LeaveUpload? selected;
  int historyPage = 1;
  bool busy = false, changed = false;
  String? message;
  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    ownerId = ref.read(authNotifierProvider).user?.id;
    future = load(); history = ref.read(employeeLeaveRepositoryProvider).history(widget.publicId, 1);
    catalog = ref.read(employeeLeaveRepositoryProvider).catalog();
    subscription = EmployeeLeaveNotices.changes.listen((notice) {
      if (mounted && notice.requestId == widget.publicId && notice.userId == ref.read(authNotifierProvider).user?.id) {
        if (busy) { setState(() => changed = true); } else { reload(); }
      }
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) { if (state == AppLifecycleState.resumed && !busy) reload(); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); subscription?.cancel(); selected?.dispose(); super.dispose(); }
  Future<LeaveDetail> load() async {
    final repository = ref.read(employeeLeaveRepositoryProvider);
    final value = await repository.detail(widget.publicId);
    if (mounted && value.request.unread && ownerId == ref.read(authNotifierProvider).user?.id) {
      try { await repository.read(value.request); if (mounted) ref.invalidate(employeeLeaveUnreadProvider); } catch (_) { /* Keep the unread indicator when acknowledgement fails. */ }
    }
    return value;
  }
  void reload() {
    if (!mounted || ownerId != ref.read(authNotifierProvider).user?.id) return;
    setState(() { changed = false; future = load(); historyPage = 1;
      history = ref.read(employeeLeaveRepositoryProvider).history(widget.publicId, historyPage); });
  }
  Future<bool> perform(String title, Future<void> Function(String) action) async {
    if (busy || ownerId != ref.read(authNotifierProvider).user?.id) return false;
    if (changed) { reload(); setState(() => message = 'Se actualizó la solicitud. Revisa la versión actual antes de confirmar.'); return false; }
    setState(() { busy = true; message = null; });
    try {
      final confirmed = await confirmEmployeeLeave(context, title, action);
      if (mounted && confirmed) { ref.invalidate(employeeLeaveUnreadProvider); reload(); }
      return confirmed;
    } on LeaveFailure catch (failure) {
      if (mounted) { setState(() => message = failure.message); if (failure.conflict) reload(); }
      return false;
    } finally { if (mounted) setState(() => busy = false); }
  }
  Future<String?> askReason(String title) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(context: context, builder: (context) => StatefulBuilder(builder: (context, update) => AlertDialog(
        title: Text(title), content: TextField(controller: controller, autofocus: true, minLines: 2, maxLines: 5, maxLength: 1000,
          decoration: const InputDecoration(labelText: 'Motivo *'), onChanged: (_) => update(() {})),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Volver')),
          FilledButton(onPressed: controller.text.trim().isEmpty ? null : () => Navigator.pop(context, controller.text.trim()), child: const Text('Continuar'))],
      )));
    } finally { controller.dispose(); }
  }
  Future<void> chooseFile(LeaveDetail detail, {LeaveAttachment? replace}) async {
    if (busy) return;
    setState(() { busy = true; message = null; });
    LeaveUpload? picked;
    try {
      var code = replace?.evidenceCode;
      if (code == null && detail.evidence.isNotEmpty) {
        code = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (context) => SafeArea(
          child: ListView(shrinkWrap: true, children: [const Padding(padding: EdgeInsets.all(16), child: Text('¿Qué documento vas a adjuntar?')),
            ...detail.evidence.map((rule) => ListTile(leading: const Icon(Icons.description_outlined), title: Text(rule['label'] as String),
              subtitle: Text(rule['stage'] == 'before' ? 'Soporte previo' : 'Después del evento'), onTap: () => Navigator.pop(context, rule['code'] as String))),
            ListTile(title: const Text('Información adicional'), onTap: () => Navigator.pop(context, 'additional')),
          ])));
        if (code == null || !mounted) return;
      }
      picked = await pickLeaveUpload(evidenceCode: code ?? 'additional', replacesAttachmentId: replace?.id);
      if (!mounted || ownerId != ref.read(authNotifierProvider).user?.id) { picked?.dispose(); return; }
      if (picked != null) { selected?.dispose(); setState(() => selected = picked); }
    } catch (failure) { if (mounted) setState(() => message = failure is LeaveFailure ? failure.message : 'No se pudo leer el archivo seleccionado.'); }
    finally { if (mounted) setState(() => busy = false); }
    if (mounted && picked != null) await upload(detail);
  }
  Future<void> upload(LeaveDetail detail) async {
    final file = selected;
    if (file == null) return;
    final repository = ref.read(employeeLeaveRepositoryProvider);
    if (await perform(file.replacesAttachmentId == null ? 'Adjuntar soporte' : 'Reemplazar soporte rechazado',
        (password) => repository.upload(detail.request, file, password))) {
      file.dispose(); if (mounted) setState(() => selected = null);
    }
  }
  Future<void> download(LeaveDetail detail, LeaveAttachment file) async {
    if (busy) return;
    setState(() { busy = true; message = null; });
    Uint8List? bytes;
    try {
      bytes = await ref.read(employeeLeaveRepositoryProvider).download(detail.request, file);
      if (!mounted || ownerId != ref.read(authNotifierProvider).user?.id) return;
      await FilePicker.platform.saveFile(dialogTitle: 'Guardar una copia del soporte', fileName: file.name, bytes: bytes,
        type: FileType.custom, allowedExtensions: [file.name.split('.').last.toLowerCase()]);
    } catch (failure) { if (mounted) setState(() => message = failure is LeaveFailure ? failure.message : 'No se pudo guardar el soporte.'); }
    finally { if (bytes != null) bytes.fillRange(0, bytes.length, 0); if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(employeeLeaveRepositoryProvider), auth = ref.watch(authNotifierProvider);
    if (auth.user?.id != ownerId || auth.status != AuthStatus.authenticated) return const SizedBox.shrink();
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(appBar: AppBar(title: const Text('Detalle del permiso'), actions: [IconButton(onPressed: busy ? null : reload,
      icon: const Icon(Icons.refresh), tooltip: 'Actualizar')]),
      body: FutureBuilder<LeaveDetail>(future: future, builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) return Center(child: TextButton(onPressed: reload, child: Text(snapshot.error is LeaveFailure ? (snapshot.error as LeaveFailure).message : 'No se pudo cargar. Reintentar')));
        final detail = snapshot.data!, leave = detail.request;
        final own = leave.userId == auth.user?.id;
        final canUpload = own && ['pending', 'postponed', 'approved'].contains(leave.status);
        final active = detail.activeAttachments;
        bool protectedFile(LeaveAttachment file) => detail.evidence.any((rule) => rule['code'] == file.evidenceCode && rule['required'] == true && rule['stage'] == 'before');
        return ListView(padding: const EdgeInsets.all(16), children: [
          if (message != null) Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(message!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (changed) Padding(padding: const EdgeInsets.only(bottom: 16), child: Text('Hay una actualización pendiente. Actualiza antes de confirmar otra acción.', style: muted)),
          LeaveSectionCard(title: 'Tu solicitud', icon: Icons.event_note_outlined, children: [
            FutureBuilder<List<Map<String, dynamic>>>(future: catalog, builder: (_, kinds) {
              final labels = {for (final kind in kinds.data ?? <Map<String, dynamic>>[]) kind['code']: kind['label']};
              return Text(labels[leave.kind]?.toString() ?? 'Permiso laboral', style: Theme.of(context).textTheme.titleMedium);
            }),
            Wrap(spacing: 8, runSpacing: 6, children: [LeaveStatusChip(leave.status),
              if ((leave.isPaid ?? leave.requestedIsPaid) != null) LeaveStatusChip((leave.isPaid ?? leave.requestedIsPaid)! ? 'paid' : 'unpaid',
                label: (leave.isPaid ?? leave.requestedIsPaid)! ? 'Remunerado' : 'No remunerado')]),
            Text(leave.periodLabel), Text(leave.durationLabel, style: muted), Text('Hora de Colombia · ${leave.branchName}', style: muted),
            const Divider(height: 1), Text(detail.text('justification')),
            if (leave.periodRecord) Text('Registro de pausas de lactancia. No representa ausencia durante todos esos días.', style: muted),
          ]),
          LeaveSectionCard(title: 'Respuesta y seguimiento', icon: Icons.chat_bubble_outline, children: [
            if (detail.text('decisionReason').isNotEmpty) ...[Text(detail.text('decisionReason')),
              Text('${detail.text('decidedByName')} · ${leaveDate(detail.date('decidedAt'))}', style: muted)]
            else Text(detail.flag('hasReviewer') ? 'La solicitud está pendiente de revisión. Te avisaremos cuando tenga una respuesta.' : 'No hay un revisor habilitado. Contacta al superadministrador.', style: muted),
            Wrap(spacing: 8, runSpacing: 6, children: [
              if (detail.flag('canEdit')) OutlinedButton(onPressed: busy ? null : () async {
                await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => EmployeeLeaveFormScreen(detail: detail)));
                if (mounted) reload();
              }, child: const Text('Modificar')),
              if (detail.flag('canCancel')) TextButton(onPressed: busy ? null : () async {
                final reason = await askReason('Cancelar solicitud');
                if (reason != null && mounted) await perform('Confirmar cancelación', (password) => repository.change(leave, 'cancel', password, reason: reason));
              }, child: const Text('Cancelar solicitud')),
            ]),
          ]),
          LeaveSectionCard(title: 'Documentos de soporte', icon: Icons.folder_open_outlined, children: [
            LeaveStatusChip(detail.text('supportStatus'), label: leaveSupportStatuses[detail.text('supportStatus')]),
            ...detail.evidence.map((rule) => ListTile(contentPadding: EdgeInsets.zero, title: Text(rule['label'] as String, style: Theme.of(context).textTheme.bodySmall),
              subtitle: Text(rule['required'] == true ? rule['stage'] == 'before' ? 'Requisito previo' : 'Después del evento' : 'Opcional', style: muted),
              trailing: LeaveStatusChip(rule['status'] as String))),
            if (detail.date('supportDueAt') != null) Text('Plazo acordado: ${leaveDate(detail.date('supportDueAt'))}', style: muted),
            if (active.isEmpty) Text('Todavía no hay documentos adjuntos.', style: muted),
            ...active.map((file) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [const Icon(Icons.description_outlined, size: 20), const SizedBox(width: 8), Expanded(child: Text(file.name, style: Theme.of(context).textTheme.bodySmall)),
                IconButton(tooltip: 'Guardar copia', icon: const Icon(Icons.download_outlined), onPressed: busy ? null : () => download(detail, file))]),
              LeaveStatusChip(file.reviewStatus),
              if (file.reviewReason != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(file.reviewReason!, style: muted)),
              Wrap(spacing: 8, children: [
                if (canUpload && file.reviewStatus == 'rejected') OutlinedButton(onPressed: busy ? null : () => chooseFile(detail, replace: file), child: const Text('Reemplazar documento')),
                if (detail.flag('canEdit') && !protectedFile(file)) TextButton(onPressed: busy ? null : () async {
                  final reason = await askReason('Retirar documento');
                  if (reason != null && mounted) await perform('Confirmar retiro', (password) => repository.remove(leave, file, password, reason));
                }, child: const Text('Retirar')),
              ]), const Divider(),
            ])),
            if (selected != null && canUpload) OutlinedButton(onPressed: busy ? null : () => upload(detail), child: Text('Reintentar: ${selected!.name}')),
            if (canUpload && active.length < 5) OutlinedButton.icon(onPressed: busy ? null : () => chooseFile(detail), icon: const Icon(Icons.attach_file), label: const Text('Adjuntar soporte')),
            if (detail.attachments.any((x) => x.supersededAt != null)) ExpansionTile(tilePadding: EdgeInsets.zero,
              title: const Text('Documentos reemplazados'), children: detail.attachments.where((x) => x.supersededAt != null).map((file) => ListTile(
                title: Text(file.name, style: muted), subtitle: Text(file.reviewReason ?? '', style: muted), trailing: IconButton(tooltip: 'Guardar copia histórica',
                  onPressed: busy ? null : () => download(detail, file), icon: const Icon(Icons.download_outlined)))).toList()),
            Text('Acceso privado. Máximo cinco documentos vigentes de 5 MB. Los reemplazos conservan la aprobación y el historial.', style: muted),
          ]),
          if (!leave.periodRecord) LeaveSectionCard(title: 'Regreso al trabajo', icon: Icons.assignment_turned_in_outlined, children: [
            Text('Registrado: ${leaveDate(detail.date('returnedAt'))}', style: muted), Text('Verificado: ${leaveDate(detail.date('returnVerifiedAt'))}', style: muted),
            if (detail.flag('canReturn')) FilledButton(onPressed: busy ? null : () => perform('Confirmar mi regreso', (password) => repository.change(leave, 'return', password)), child: const Text('Ya regresé')),
          ]),
          LeaveSectionCard(title: 'Historial de la solicitud', icon: Icons.history, children: [
            FutureBuilder<LeavePage<Map<String, dynamic>>>(future: history, builder: (context, historySnapshot) {
              if (historySnapshot.hasError) return TextButton(onPressed: () => setState(() => history = repository.history(widget.publicId, historyPage)), child: const Text('Reintentar historial'));
              if (!historySnapshot.hasData) return const LinearProgressIndicator();
              final data = historySnapshot.data!;
              return Column(children: [
                ...data.items.map((entry) => ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.circle, size: 8, color: Theme.of(context).colorScheme.primary),
                  title: Text(entry['reason'] as String? ?? '', style: Theme.of(context).textTheme.bodySmall),
                  subtitle: Text('${entry['actorName']} · ${leaveDate(DateTime.parse(entry['changedAt'] as String))}', style: muted))),
                if (data.totalPages > 1) Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  TextButton(onPressed: historyPage > 1 ? () => setState(() { historyPage--; history = repository.history(widget.publicId, historyPage); }) : null, child: const Text('Anterior')),
                  Text('${data.page} / ${data.totalPages}', style: muted),
                  TextButton(onPressed: historyPage < data.totalPages ? () => setState(() { historyPage++; history = repository.history(widget.publicId, historyPage); }) : null, child: const Text('Siguiente')),
                ]),
              ]);
            }),
          ]),
        ]);
      }));
  }
}
