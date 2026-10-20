import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../auth/presentation/auth_notifier.dart';
import 'employee_leave.dart';
import 'employee_leave_form.dart';
import 'employee_leave_notices.dart';
import 'employee_leave_widgets.dart';
export 'employee_leave_detail_screen.dart' show EmployeeLeaveDetailScreen;

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
  void didChangeAppLifecycleState(AppLifecycleState state) { if (state == AppLifecycleState.resumed) ref.invalidate(employeeLeaveUnreadProvider); }
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
  late final int? ownerId;
  StreamSubscription<EmployeeLeaveNotice>? subscription;
  int page = 1;
  String status = '', remuneration = '';
  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    ownerId = ref.read(authNotifierProvider).user?.id;
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
    if (!mounted || ownerId != ref.read(authNotifierProvider).user?.id) return;
    final future = ref.read(employeeLeaveRepositoryProvider).list(page, status,
      remunerated: remuneration.isEmpty ? null : remuneration == 'paid');
    setState(() => pageFuture = future); ref.invalidate(employeeLeaveUnreadProvider);
    try { await future; } catch (_) { /* FutureBuilder offers retry without an unhandled asynchronous error. */ }
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
    final auth = ref.watch(authNotifierProvider);
    if (auth.user?.id != ownerId || auth.status != AuthStatus.authenticated) return const SizedBox.shrink();
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(appBar: AppBar(title: const Text('Mis permisos'), actions: [IconButton(onPressed: reload, icon: const Icon(Icons.refresh), tooltip: 'Actualizar')]),
      floatingActionButton: FloatingActionButton.extended(onPressed: create, icon: const Icon(Icons.add), label: const Text('Solicitar permiso')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Solicitudes, documentos y respuestas del equipo.', style: muted), const SizedBox(height: 16),
          Row(children: [Expanded(child: DropdownButtonFormField<String>(initialValue: status, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Estado'), items: [const DropdownMenuItem(value: '', child: Text('Todos')),
              ...leaveStatuses.entries.map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value)))],
            onChanged: (value) { status = value ?? ''; page = 1; unawaited(reload()); })), const SizedBox(width: 12),
            Expanded(child: DropdownButtonFormField<String>(initialValue: remuneration, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Remuneración'), items: const [DropdownMenuItem(value: '', child: Text('Todos')),
                DropdownMenuItem(value: 'paid', child: Text('Remunerado')), DropdownMenuItem(value: 'unpaid', child: Text('No remunerado'))],
              onChanged: (value) { remuneration = value ?? ''; page = 1; unawaited(reload()); })),
          ]),
        ])),
        Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(future: catalog, builder: (context, kinds) {
          final labels = {for (final item in kinds.data ?? <Map<String, dynamic>>[]) item['code']: item['label']};
          final payments = {for (final item in kinds.data ?? <Map<String, dynamic>>[]) item['code']: item['paidByCompanyPolicy']};
          return FutureBuilder<LeavePage<LeaveItem>>(future: pageFuture, builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
            if (snapshot.hasError) return Center(child: TextButton(onPressed: reload,
              child: Text(snapshot.error is LeaveFailure ? (snapshot.error as LeaveFailure).message : 'No se pudo cargar. Reintentar')));
            final data = snapshot.data!;
            return RefreshIndicator(onRefresh: reload, child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 100), physics: const AlwaysScrollableScrollPhysics(), children: [
              if (data.items.isEmpty) LeaveSectionCard(title: 'Sin solicitudes', icon: Icons.event_available_outlined,
                children: [Text('No hay solicitudes con estos filtros. Tus permisos y sus respuestas aparecerán aquí.', style: muted)]),
              ...data.items.map((item) {
                final paid = item.isPaid ?? item.requestedIsPaid ?? payments[item.kind] as bool?;
                return Card(margin: const EdgeInsets.only(bottom: 12), child: InkWell(borderRadius: BorderRadius.circular(12),
                  onTap: () async { await context.push('/permisos/${item.id}'); if (mounted) await reload(); },
                  child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: Text(labels[item.kind]?.toString() ?? 'Solicitud de permiso',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))), const SizedBox(width: 8), LeaveStatusChip(item.status)]),
                    const SizedBox(height: 10), Text(item.periodLabel, style: muted), const SizedBox(height: 6), Text(item.durationLabel, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 6, children: [
                      if (paid != null) LeaveStatusChip(paid ? 'paid' : 'unpaid', label: paid ? 'Remunerado' : 'No remunerado'),
                      if (item.supportStatus != 'not_required') LeaveStatusChip(item.supportStatus, label: leaveSupportStatuses[item.supportStatus]),
                      if (item.unread) const LeaveStatusChip('paid', label: 'Nuevo'),
                    ]), const SizedBox(height: 8), Text(item.branchName, style: muted),
                  ]))));
              }),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                TextButton(onPressed: page > 1 ? () { page--; unawaited(reload()); } : null, child: const Text('Anterior')),
                Text('${data.page} / ${data.totalPages < 1 ? 1 : data.totalPages}', style: muted),
                TextButton(onPressed: page < data.totalPages ? () { page++; unawaited(reload()); } : null, child: const Text('Siguiente')),
              ]),
            ]));
          });
        })),
      ]));
  }
}
