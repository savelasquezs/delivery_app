import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/errors/user_facing_error.dart';
import '../auth/presentation/auth_notifier.dart';
import 'employee_lunch.dart';

class EmployeeLunchGate extends ConsumerStatefulWidget {
  final Widget child;
  const EmployeeLunchGate({super.key, required this.child});
  @override
  ConsumerState<EmployeeLunchGate> createState() => _EmployeeLunchGateState();
}

class _EmployeeLunchGateState extends ConsumerState<EmployeeLunchGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ref.read(authNotifierProvider).status == AuthStatus.authenticated) {
      unawaited(ref.read(employeeLunchProvider.notifier).refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(authNotifierProvider).status != AuthStatus.authenticated) {
      return widget.child;
    }
    final lunch = ref.watch(employeeLunchProvider);
    final blocked =
        lunch.hasError || lunch.valueOrNull?.active == true || !lunch.hasValue;
    return Stack(children: [
      ExcludeFocus(
          excluding: blocked,
          child: IgnorePointer(ignoring: blocked, child: widget.child)),
      if (blocked)
        Positioned.fill(
            child: Material(
                color: Colors.black87,
                child: SafeArea(
                    child: Center(
                        child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 400),
                                child: const EmployeeLunchForm())))))),
    ]);
  }
}

class EmployeeLunchButton extends ConsumerWidget {
  const EmployeeLunchButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
        tooltip: 'Salir a almorzar',
        icon: const Icon(Icons.restaurant),
        onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(
                  title: Text('Almuerzo'),
                  content: SingleChildScrollView(child: EmployeeLunchForm()),
                )),
      );
}

class EmployeeLunchForm extends ConsumerStatefulWidget {
  const EmployeeLunchForm({super.key});
  @override
  ConsumerState<EmployeeLunchForm> createState() => _EmployeeLunchFormState();
}

class _EmployeeLunchFormState extends ConsumerState<EmployeeLunchForm> {
  final password = TextEditingController();
  Timer? timer;
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (saving || password.text.isEmpty) return;
    setState(() {
      saving = true;
      error = null;
    });
    final active = ref.read(employeeLunchProvider).valueOrNull?.active == true;
    try {
      await ref.read(employeeLunchProvider.notifier).change(password.text);
      if (mounted && !active && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingErrorMessage(e));
    } finally {
      password.clear();
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(employeeLunchProvider);
    final lunch = state.valueOrNull;
    final elapsed = lunch?.startedAt == null
        ? Duration.zero
        : DateTime.now()
            .toUtc()
            .add(lunch!.clockOffset)
            .difference(lunch.startedAt!);
    final minutes = elapsed.inMinutes < 0 ? 0 : elapsed.inMinutes;
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lunch?.active == true) ...[
            const Text('Estás almorzando',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 22)),
            Text(
                '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 40)),
            const Text('Tiempo de almuerzo · horas:minutos',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
          ],
          if (!state.hasValue && state.isLoading)
            const Center(child: CircularProgressIndicator()),
          TextField(
              controller: password,
              obscureText: true,
              autofocus: true,
              enabled: !saving && state.hasValue,
              maxLength: 256,
              decoration: const InputDecoration(
                  labelText: 'Contraseña personal', counterText: ''),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => submit()),
          if (error != null || state.hasError)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(error ?? userFacingErrorMessage(state.error),
                    style: const TextStyle(color: Colors.orangeAccent))),
          if (state.hasError)
            TextButton(
                onPressed: saving
                    ? null
                    : () => ref.read(employeeLunchProvider.notifier).refresh(),
                child: const Text('Actualizar estado')),
          FilledButton(
              onPressed: saving ||
                      state.hasError ||
                      !state.hasValue ||
                      password.text.isEmpty
                  ? null
                  : submit,
              child: Text(saving
                  ? 'Guardando…'
                  : lunch?.active == true
                      ? 'Regresé de almorzar'
                      : 'Salir a almorzar')),
          if (lunch?.active == true || state.hasError)
            TextButton(
                onPressed: saving
                    ? null
                    : () => ref.read(authNotifierProvider.notifier).logout(),
                child: const Text('Cerrar sesión')),
        ]);
  }
}
