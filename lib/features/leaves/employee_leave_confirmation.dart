import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    if (auth.status != AuthStatus.authenticated || auth.user?.id != ownerId) { password.clear(); Navigator.pop(context, false); return; }
    final value = password.text; password.clear();
    setState(() { busy = true; error = null; });
    try { await widget.action(value); if (mounted) Navigator.pop(context, true); }
    on LeaveFailure catch (failure) {
      if (!mounted) return;
      if (failure.conflict) { Navigator.pop(context, failure); return; }
      setState(() => error = failure.message);
    } catch (_) { if (mounted) setState(() => error = 'No se pudo confirmar. Revisa la conexión e inténtalo de nuevo.'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next.status != AuthStatus.authenticated || next.user?.id != ownerId) {
        password.clear(); if (mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context, false);
      }
    });
    return PopScope(canPop: !busy, child: AlertDialog(
      icon: const Icon(Icons.lock_outline), title: Text(widget.title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Confirma con tu contraseña actual. Tu sesión permanece abierta.'), const SizedBox(height: 16),
        TextField(key: const Key('leave-password'), controller: password, autofocus: true, obscureText: true,
          enabled: !busy, maxLength: 256, enableSuggestions: false, autocorrect: false,
          autofillHints: const [AutofillHints.password], decoration: const InputDecoration(labelText: 'Tu contraseña', counterText: ''),
          onSubmitted: (_) => submit(), onChanged: (_) => setState(() {})),
        if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, key: const Key('leave-confirmation-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ]),
      actions: [TextButton(onPressed: busy ? null : () { password.clear(); Navigator.pop(context, false); }, child: const Text('Cancelar')),
        FilledButton(onPressed: busy || password.text.isEmpty ? null : submit, child: Text(busy ? 'Enviando…' : 'Confirmar'))],
    ));
  }
}
