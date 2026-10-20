import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../auth/presentation/auth_notifier.dart';
import 'employee_leave.dart';
import 'employee_leave_form.dart';
import 'employee_leave_notices.dart';

class EmployeeLeaveButton extends ConsumerStatefulWidget {
  const EmployeeLeaveButton({super.key});
  @override
  ConsumerState<EmployeeLeaveButton> createState() => _EmployeeLeaveButtonState();
}
class _EmployeeLeaveButtonState extends ConsumerState<EmployeeLeaveButton> with WidgetsBindingObserver {
  StreamSubscription<EmployeeLeaveNotice>? subscription;
  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    subscription = EmployeeLeaveNotices.changes.listen((notice) {
      if (mounted && notice.userId == ref.read(authNotifierProvider).user?.id) ref.invalidate(employeeLeaveUnreadProvider);
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(employeeLeaveUnreadProvider);
  }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); subscription?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final unread = ref.watch(employeeLeaveUnreadProvider).valueOrNull ?? 0;
    return IconButton(tooltip: 'Mis permisos', onPressed: () => context.push('/permisos'),
      icon: Badge(isLabelVisible: unread > 0, label: Text(unread > 99 ? '99+' : '$unread'), child: const Icon(Icons.event_note_outlined)));
  }
}

class EmployeeLeavesScreen extends ConsumerStatefulWidget {
  const EmployeeLeavesScreen({super.key});
  @override
  ConsumerState<EmployeeLeavesScreen> createState() => _EmployeeLeavesState();
}
class _EmployeeLeavesState extends ConsumerState<EmployeeLeavesScreen> with WidgetsBindingObserver {
  late Future<LeavePage<LeaveItem>> pageFuture;
  late Future<List<Map<String, dynamic>>> catalog;
  StreamSubscription<EmployeeLeaveNotice>? subscription;
  int page = 1;
  String status = '';
  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    catalog = ref.read(employeeLeaveRepositoryProvider).catalog();
    pageFuture = ref.read(employeeLeaveRepositoryProvider).list(page, status);
    subscription = EmployeeLeaveNotices.changes.listen((notice) {
      if (mounted && notice.userId == ref.read(authNotifierProvider).user?.id) unawaited(reload());
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) { if (state == AppLifecycleState.resumed) unawaited(reload()); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); subscription?.cancel(); super.dispose(); }
  Future<void> reload() async {
    if (!mounted) return;
    final future = ref.read(employeeLeaveRepositoryProvider).list(page, status);
    setState(() => pageFuture = future);
    ref.invalidate(employeeLeaveUnreadProvider);
    try { await future; } catch (_) { /* El FutureBuilder muestra el error y permite reintentar. */ }
  }
  Future<void> create() async {
    final id = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const EmployeeLeaveFormScreen()));
    if (!mounted) return;
    page = 1; await reload();
    if (mounted && id != null && isLeaveId(id)) await context.push('/permisos/$id');
    if (mounted) await reload();
  }
  @override
  Widget build(BuildContext context) {
    ref.watch(employeeLeaveRepositoryProvider);
    return Scaffold(appBar: AppBar(title: const Text('Mis permisos'), actions: [IconButton(onPressed: reload, icon: const Icon(Icons.refresh), tooltip: 'Actualizar')]),
      floatingActionButton: FloatingActionButton.extended(onPressed: create, icon: const Icon(Icons.add), label: const Text('Solicitar permiso')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: DropdownButtonFormField<String>(initialValue: status,
          decoration: const InputDecoration(labelText: 'Estado'), items: [const DropdownMenuItem(value: '', child: Text('Todos')),
            ...leaveStatuses.entries.map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value)))],
          onChanged: (value) { status = value ?? ''; page = 1; unawaited(reload()); })),
        Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(future: catalog, builder: (context, kinds) {
          final labels = {for (final item in kinds.data ?? <Map<String, dynamic>>[]) item['code']: item['label']};
          return FutureBuilder<LeavePage<LeaveItem>>(future: pageFuture, builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
            if (snapshot.hasError) return _LeaveError(snapshot.error, reload);
            final data = snapshot.data!;
            return RefreshIndicator(onRefresh: reload, child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              physics: const AlwaysScrollableScrollPhysics(), children: [
                if (data.items.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Text('No hay solicitudes con estos filtros.')),
                ...data.items.map((item) => Card(child: ListTile(
                  title: Text(labels[item.kind]?.toString() ?? item.kind),
                  subtitle: Text('${leaveStatuses[item.status] ?? item.status}\n${leaveDate(item.startsAt)} → ${leaveDate(item.endsAt)}\n${item.branchName}'),
                  isThreeLine: true, trailing: item.unread ? const Icon(Icons.mark_email_unread_outlined, semanticLabel: 'Actualización sin leer') : const Icon(Icons.chevron_right),
                  onTap: () async { await context.push('/permisos/${item.id}'); if (mounted) await reload(); },
                ))),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  TextButton(onPressed: page > 1 ? () { page--; unawaited(reload()); } : null, child: const Text('Anterior')),
                  Text('${data.page} / ${data.totalPages < 1 ? 1 : data.totalPages}'),
                  TextButton(onPressed: page < data.totalPages ? () { page++; unawaited(reload()); } : null, child: const Text('Siguiente')),
                ]),
              ]));
          });
        })),
      ]));
  }
}

class EmployeeLeaveDetailScreen extends ConsumerStatefulWidget {
  final String publicId;
  const EmployeeLeaveDetailScreen({super.key, required this.publicId});
  @override
  ConsumerState<EmployeeLeaveDetailScreen> createState() => _EmployeeLeaveDetailState();
}
class _EmployeeLeaveDetailState extends ConsumerState<EmployeeLeaveDetailScreen> with WidgetsBindingObserver {
  late Future<LeaveDetail> future;
  late Future<LeavePage<Map<String, dynamic>>> history;
  StreamSubscription<EmployeeLeaveNotice>? subscription;
  LeaveUpload? selected;
  int historyPage = 1;
  bool busy = false, changed = false;
  String? message;
  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    future = load(); history = ref.read(employeeLeaveRepositoryProvider).history(widget.publicId, 1);
    subscription = EmployeeLeaveNotices.changes.listen((notice) {
      if (mounted && notice.requestId == widget.publicId && notice.userId == ref.read(authNotifierProvider).user?.id) {
        if (busy) { setState(() => changed = true); } else { reload(); }
      }
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) reload();
  }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); subscription?.cancel(); selected?.dispose(); super.dispose(); }
  Future<LeaveDetail> load() async {
    final repository = ref.read(employeeLeaveRepositoryProvider);
    final value = await repository.detail(widget.publicId);
    if (mounted && value.request.unread) {
      try { await repository.read(value.request); if (mounted) ref.invalidate(employeeLeaveUnreadProvider); } catch (_) { /* Se conserva el aviso sin leer. */ }
    }
    return value;
  }
  void reload() {
    if (!mounted) return;
    setState(() { changed = false; future = load(); historyPage = 1;
      history = ref.read(employeeLeaveRepositoryProvider).history(widget.publicId, historyPage); });
  }
  Future<bool> perform(String title, Future<void> Function(String) action) async {
    if (busy) return false;
    setState(() { busy = true; message = null; });
    try {
      final confirmed = await confirmEmployeeLeave(context, title, action);
      if (mounted && confirmed) { ref.invalidate(employeeLeaveUnreadProvider); reload(); }
      return confirmed;
    } on LeaveFailure catch (error) {
      if (mounted) { setState(() => message = error.message); if (error.conflict) reload(); }
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
  Future<void> chooseFile(LeaveDetail detail) async {
    if (busy) return;
    setState(() { busy = true; message = null; });
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'], allowMultiple: false, withData: false);
      if (result == null || !mounted) return;
      final file = result.files.single;
      if (file.size <= 0 || file.size > leaveMaxBytes) throw const LeaveFailure('Adjunta un archivo de máximo 5 MB.');
      final bytes = await file.xFile.readAsBytes();
      if (!mounted) return;
      final upload = LeaveUpload(const Uuid().v4(), file.name, bytes);
      selected?.dispose(); setState(() => selected = upload);
    } catch (error) {
      if (mounted) setState(() => message = error is LeaveFailure ? error.message : 'No se pudo leer el archivo seleccionado.');
    } finally {
      try { await FilePicker.platform.clearTemporaryFiles(); } catch (_) { /* No afecta otros archivos ni la solicitud. */ }
      if (mounted) setState(() => busy = false);
    }
    if (mounted && selected != null) await upload(detail);
  }
  Future<void> upload(LeaveDetail detail) async {
    final file = selected;
    if (file == null) return;
    final repository = ref.read(employeeLeaveRepositoryProvider);
    if (await perform('Adjuntar soporte', (password) => repository.upload(detail.request, file, password))) {
      file.dispose(); if (mounted) setState(() => selected = null);
    }
  }
  Future<void> download(LeaveDetail detail, LeaveAttachment file) async {
    if (busy) return;
    setState(() { busy = true; message = null; });
    final owner = ref.read(authNotifierProvider).user?.id;
    try {
      final bytes = await ref.read(employeeLeaveRepositoryProvider).download(detail.request, file);
      if (!mounted || owner != ref.read(authNotifierProvider).user?.id) return;
      try {
        await FilePicker.platform.saveFile(dialogTitle: 'Guardar una copia del soporte', fileName: file.name, bytes: bytes,
          type: FileType.custom, allowedExtensions: [file.name.split('.').last.toLowerCase()]);
      } finally { bytes.fillRange(0, bytes.length, 0); }
    } catch (error) { if (mounted) setState(() => message = error is LeaveFailure ? error.message : 'No se pudo guardar el soporte.'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(employeeLeaveRepositoryProvider);
    return Scaffold(appBar: AppBar(title: const Text('Detalle del permiso'), actions: [IconButton(onPressed: busy ? null : reload,
      icon: const Icon(Icons.refresh), tooltip: 'Actualizar')]),
      body: FutureBuilder<LeaveDetail>(future: future, builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) return _LeaveError(snapshot.error, reload);
        final detail = snapshot.data!, leave = detail.request;
        final canUpload = leave.userId == ref.read(authNotifierProvider).user?.id
          && ['pending', 'postponed', 'approved'].contains(leave.status) && detail.attachments.length < 5;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text(leaveStatuses[leave.status] ?? leave.status, style: Theme.of(context).textTheme.headlineSmall),
          Text('${leaveDate(leave.startsAt)} → ${leaveDate(leave.endsAt)}\nHora de Colombia · ${leave.branchName}'),
          const SizedBox(height: 16), Text(detail.text('justification')),
          if (detail.text('documentNumber').isNotEmpty) Text('Documento: ${detail.text('documentNumber')}'),
          if (detail.text('decisionReason').isNotEmpty) ...[const Divider(), Text('Respuesta: ${detail.text('decisionReason')}'),
            Text('Por ${detail.text('decidedByName')} · ${leaveDate(detail.date('decidedAt'))}')],
          if (detail.fields['isPaid'] != null) Text(detail.fields['isPaid'] == true ? 'Permiso remunerado' : 'Permiso no remunerado'),
          if (!detail.flag('hasReviewer') && leave.status == 'pending') const Text('No hay un revisor habilitado. Contacta al superadministrador.'),
          if (changed) const Text('Hay una actualización pendiente. Actualiza antes de confirmar otra acción.'),
          if (message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(message!)),
          Wrap(spacing: 8, children: [
            if (detail.flag('canEdit')) OutlinedButton(onPressed: busy ? null : () async {
              await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => EmployeeLeaveFormScreen(detail: detail)));
              if (mounted) reload();
            }, child: const Text('Modificar solicitud')),
            if (detail.flag('canCancel')) OutlinedButton(onPressed: busy ? null : () async {
              final reason = await askReason('Cancelar solicitud');
              if (reason != null && mounted) await perform('Confirmar cancelación', (password) => repository.change(leave, 'cancel', password, reason: reason));
            }, child: const Text('Cancelar solicitud')),
            if (detail.flag('canReturn')) FilledButton(onPressed: busy ? null : () => perform('Confirmar mi regreso',
              (password) => repository.change(leave, 'return', password)), child: const Text('Ya regresé')),
          ]),
          const Divider(), Text('Soportes', style: Theme.of(context).textTheme.titleLarge),
          Text(leaveSupportStatuses[detail.text('supportStatus')] ?? detail.text('supportStatus')),
          if (detail.date('supportDueAt') != null) Text('Plazo: ${leaveDate(detail.date('supportDueAt'))}'),
          const Text('PDF, JPG o PNG; máximo 5 archivos de 5 MB. No adjuntes tu historia clínica.'),
          ...detail.attachments.map((file) => ListTile(contentPadding: EdgeInsets.zero, title: Text(file.name),
            subtitle: Text('${(file.size / 1024).ceil()} KB'), trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: 'Guardar copia', icon: const Icon(Icons.download_outlined), onPressed: busy ? null : () => download(detail, file)),
              if (detail.flag('canEdit')) IconButton(tooltip: 'Eliminar soporte', icon: const Icon(Icons.delete_outline), onPressed: busy ? null : () async {
                final reason = await askReason('Eliminar soporte');
                if (reason != null && mounted) await perform('Confirmar eliminación', (password) => repository.remove(leave, file, password, reason));
              }),
            ]))),
          if (canUpload) ...[
            if (selected != null) OutlinedButton(onPressed: busy ? null : () => upload(detail), child: Text('Reintentar soporte: ${selected!.name}')),
            OutlinedButton.icon(onPressed: busy ? null : () => chooseFile(detail), icon: const Icon(Icons.attach_file),
              label: Text(selected == null ? 'Adjuntar soporte' : 'Elegir otro archivo')),
          ],
          const Divider(), Text('Regreso', style: Theme.of(context).textTheme.titleLarge),
          Text('Registrado: ${leaveDate(detail.date('returnedAt'))}'),
          Text('Verificado: ${leaveDate(detail.date('returnVerifiedAt'))}'),
          if (detail.text('verificationReason').isNotEmpty) Text(detail.text('verificationReason')),
          const Divider(), Text('Historial', style: Theme.of(context).textTheme.titleLarge),
          FutureBuilder<LeavePage<Map<String, dynamic>>>(future: history, builder: (context, historySnapshot) {
            if (historySnapshot.hasError) return TextButton(onPressed: () => setState(() => history = repository.history(widget.publicId, historyPage)), child: const Text('Reintentar historial'));
            if (!historySnapshot.hasData) return const LinearProgressIndicator();
            final data = historySnapshot.data!;
            return Column(children: [
              ...data.items.map((entry) => ListTile(contentPadding: EdgeInsets.zero, title: Text(entry['reason'] as String? ?? ''),
                subtitle: Text('${entry['actorName']} · ${leaveDate(DateTime.parse(entry['changedAt'] as String))}'))),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                TextButton(onPressed: historyPage > 1 ? () => setState(() { historyPage--; history = repository.history(widget.publicId, historyPage); }) : null, child: const Text('Anterior')),
                Text('${data.page} / ${data.totalPages < 1 ? 1 : data.totalPages}'),
                TextButton(onPressed: historyPage < data.totalPages ? () => setState(() { historyPage++; history = repository.history(widget.publicId, historyPage); }) : null, child: const Text('Siguiente')),
              ]),
            ]);
          }),
        ]);
      }));
  }
}

class _LeaveError extends StatelessWidget {
  final Object? error;
  final VoidCallback retry;
  const _LeaveError(this.error, this.retry);
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
    Text(error is LeaveFailure ? (error as LeaveFailure).message : 'No se pudo cargar la solicitud.'),
    TextButton(onPressed: retry, child: const Text('Reintentar')),
  ])));
}
