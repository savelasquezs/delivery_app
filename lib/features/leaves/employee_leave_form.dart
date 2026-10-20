import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../auth/presentation/auth_notifier.dart';
import 'employee_leave.dart';

Future<bool> confirmEmployeeLeave(BuildContext context, String title, Future<void> Function(String) action) async {
  final result = await showDialog<Object>(context: context, barrierDismissible: false,
    builder: (_) => _PasswordConfirmation(title: title, action: action));
  if (result is LeaveFailure) throw result;
  return result == true;
}

class _PasswordConfirmation extends ConsumerStatefulWidget {
  final String title;
  final Future<void> Function(String) action;
  const _PasswordConfirmation({required this.title, required this.action});
  @override
  ConsumerState<_PasswordConfirmation> createState() => _PasswordConfirmationState();
}

class _PasswordConfirmationState extends ConsumerState<_PasswordConfirmation> {
  final password = TextEditingController();
  late final int? ownerId;
  bool busy = false;
  String? error;
  @override
  void initState() { super.initState(); ownerId = ref.read(authNotifierProvider).user?.id; }
  @override
  void dispose() { password.clear(); password.dispose(); super.dispose(); }
  Future<void> submit() async {
    if (busy || password.text.isEmpty || password.text.length > 256) return;
    final auth = ref.read(authNotifierProvider);
    if (auth.status != AuthStatus.authenticated || auth.user?.id != ownerId) {
      password.clear(); Navigator.pop(context, false); return;
    }
    final value = password.text;
    password.clear();
    setState(() { busy = true; error = null; });
    try {
      await widget.action(value);
      if (mounted) Navigator.pop(context, true);
    } on LeaveFailure catch (failure) {
      if (!mounted) return;
      if (failure.conflict) { Navigator.pop(context, failure); return; }
      setState(() => error = failure.message);
    } catch (_) {
      if (mounted) setState(() => error = 'No se pudo confirmar. Revisa la conexión e inténtalo de nuevo.');
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next.status != AuthStatus.authenticated || next.user?.id != ownerId) {
        password.clear();
        if (mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context, false);
      }
    });
    return PopScope(canPop: !busy, child: AlertDialog(
      title: Text(widget.title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Confirma con tu contraseña. No se cerrará tu sesión.'),
        const SizedBox(height: 12),
        TextField(key: const Key('leave-password'), controller: password, autofocus: true, obscureText: true,
          enabled: !busy, maxLength: 256, enableSuggestions: false, autocorrect: false,
          autofillHints: const [AutofillHints.password], decoration: const InputDecoration(labelText: 'Tu contraseña'),
          onSubmitted: (_) => submit(), onChanged: (_) => setState(() {})),
        if (error != null) Text(error!, key: const Key('leave-confirmation-error')),
      ]),
      actions: [
        TextButton(onPressed: busy ? null : () { password.clear(); Navigator.pop(context, false); }, child: const Text('Cancelar')),
        FilledButton(onPressed: busy || password.text.isEmpty ? null : submit,
          child: Text(busy ? 'Confirmando…' : 'Confirmar')),
      ],
    ));
  }
}

class EmployeeLeaveFormScreen extends ConsumerStatefulWidget {
  final LeaveDetail? detail;
  const EmployeeLeaveFormScreen({super.key, this.detail});
  @override
  ConsumerState<EmployeeLeaveFormScreen> createState() => _EmployeeLeaveFormState();
}

class _EmployeeLeaveFormState extends ConsumerState<EmployeeLeaveFormScreen> {
  final formKey = GlobalKey<FormState>();
  final document = TextEditingController(), justification = TextEditingController();
  final requestKey = const Uuid().v4();
  late Future<List<Map<String, dynamic>>> catalog;
  late DateTime startsAt, endsAt;
  String kind = 'other';
  bool support = false, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final detail = widget.detail;
    startsAt = detail?.request.startsAt ?? DateTime.now().toUtc();
    endsAt = detail?.request.endsAt ?? startsAt.add(const Duration(hours: 1));
    kind = detail?.request.kind ?? 'other';
    document.text = detail?.text('documentNumber') ?? '';
    justification.text = detail?.text('justification') ?? '';
    support = detail?.flag('supportRequired') ?? false;
    catalog = ref.read(employeeLeaveRepositoryProvider).catalog();
  }
  @override
  void dispose() { document.dispose(); justification.dispose(); super.dispose(); }
  Future<void> pickTime(bool start) async {
    final initial = leaveColombiaTime(start ? startsAt : endsAt);
    final day = await showDatePicker(context: context, initialDate: initial,
      firstDate: DateTime(initial.year - 2), lastDate: DateTime(initial.year + 2, 12, 31));
    if (day == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute));
    if (time == null || !mounted) return;
    final utc = leaveUtcTime(DateTime(day.year, day.month, day.day, time.hour, time.minute));
    setState(() { if (start) { startsAt = utc; } else { endsAt = utc; } });
  }
  Future<void> save() async {
    if (busy || formKey.currentState?.validate() != true) return;
    if (!endsAt.isAfter(startsAt) || endsAt.difference(startsAt) > const Duration(days: 366)) {
      setState(() => error = 'El regreso debe ser posterior a la salida; el intervalo máximo es 366 días.'); return;
    }
    final fields = <String, dynamic>{'requestKey': requestKey, 'version': widget.detail?.request.version ?? 0,
      'kind': kind, 'documentNumber': document.text.trim(), 'justification': justification.text.trim(),
      'startsAt': startsAt.toUtc().toIso8601String(), 'endsAt': endsAt.toUtc().toIso8601String(), 'supportRequired': support};
    setState(() { busy = true; error = null; });
    String? id;
    try {
      final repository = ref.read(employeeLeaveRepositoryProvider);
      final confirmed = await confirmEmployeeLeave(context, 'Enviar solicitud', (password) async {
        id = await repository.save(widget.detail?.request.id, fields, password);
      });
      if (!mounted) return;
      if (confirmed && id != null) {
        ref.invalidate(employeeLeaveUnreadProvider);
        Navigator.pop(context, id);
      }
    } on LeaveFailure catch (failure) {
      if (!mounted) return;
      if (failure.conflict && widget.detail != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.message)));
        Navigator.pop(context);
      } else { setState(() => error = failure.message); }
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    // Mantener el repositorio vivo mientras haya una confirmación en curso.
    ref.watch(employeeLeaveRepositoryProvider);
    return PopScope(canPop: !busy, child: Scaffold(
      appBar: AppBar(title: Text(widget.detail == null ? 'Solicitar permiso' : 'Modificar solicitud')),
      body: FutureBuilder<List<Map<String, dynamic>>>(future: catalog, builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: TextButton(onPressed: () => setState(() {
          catalog = ref.read(employeeLeaveRepositoryProvider).catalog();
        }), child: const Text('No se pudo cargar el formulario. Reintentar')));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        return Form(key: formKey, child: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Las fechas y horas corresponden a Colombia.'), const SizedBox(height: 16),
          DropdownButtonFormField<String>(initialValue: kind, isExpanded: true, decoration: const InputDecoration(labelText: 'Tipo de permiso *'),
            items: snapshot.data!.map((item) => DropdownMenuItem(value: item['code'] as String,
              child: Text(item['label'] as String, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: busy ? null : (value) => setState(() => kind = value ?? kind)),
          const SizedBox(height: 12),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Salida *'), subtitle: Text(leaveDate(startsAt)),
            trailing: const Icon(Icons.calendar_month), onTap: busy ? null : () => pickTime(true)),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Regreso previsto *'), subtitle: Text(leaveDate(endsAt)),
            trailing: const Icon(Icons.calendar_month), onTap: busy ? null : () => pickTime(false)),
          TextFormField(controller: document, enabled: !busy, maxLength: 32,
            decoration: const InputDecoration(labelText: 'Número de documento (opcional)')),
          TextFormField(controller: justification, enabled: !busy, minLines: 3, maxLines: 6, maxLength: 2000,
            decoration: const InputDecoration(labelText: 'Justificación *'),
            validator: (value) => value == null || value.trim().isEmpty ? 'Escribe la justificación.' : null),
          CheckboxListTile(contentPadding: EdgeInsets.zero, value: support, title: const Text('Presentaré un soporte'),
            subtitle: const Text('Podrás adjuntar PDF, JPG o PNG después de enviar la solicitud.'),
            onChanged: busy ? null : (value) => setState(() => support = value ?? false)),
          if (error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(error!)),
          FilledButton(onPressed: busy ? null : save, child: const Text('Revisar y confirmar envío')),
        ]));
      }),
    ));
  }
}
