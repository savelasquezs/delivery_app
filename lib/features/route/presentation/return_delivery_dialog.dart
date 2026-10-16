import 'package:flutter/material.dart';
import '../../../core/errors/user_facing_error.dart';

Future<bool> showReturnDeliveryDialog(
  BuildContext context, {
  required List<int> orderIds,
  required Future<void> Function(List<int>) onConfirm,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ReturnDeliveryDialog(
        orderIds: orderIds,
        onConfirm: onConfirm,
      ),
    ) ?? false;

/// A deliberate human confirmation, never a GPS automatic-delivery signal.
class ReturnDeliveryDialog extends StatefulWidget {
  const ReturnDeliveryDialog({
    super.key,
    required this.orderIds,
    required this.onConfirm,
  });
  final List<int> orderIds;
  final Future<void> Function(List<int>) onConfirm;

  @override
  State<ReturnDeliveryDialog> createState() => _ReturnDeliveryDialogState();
}

class _ReturnDeliveryDialogState extends State<ReturnDeliveryDialog> {
  late final Set<int> _selected = widget.orderIds.toSet();
  bool _saving = false;
  String? _error;

  Future<void> _confirm() async {
    if (_saving || _selected.isEmpty) return;
    setState(() { _saving = true; _error = null; });
    try {
      await widget.onConfirm(_selected.toList()..sort());
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = userFacingErrorMessage(
          error, fallback: 'No pudimos confirmar las entregas.');
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Pedidos pendientes al regresar'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Confirma únicamente los pedidos que entregaste. '
              'Desmarca los que devolviste o siguen pendientes.'),
          for (final id in widget.orderIds)
            CheckboxListTile(
              title: Text('Pedido #$id'),
              value: _selected.contains(id),
              onChanged: _saving ? null : (value) => setState(() {
                if (value == true) { _selected.add(id); }
                else { _selected.remove(id); }
              }),
            ),
          if (_error != null)
            Text(_error!, style:
                TextStyle(color: Theme.of(context).colorScheme.error)),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Ahora no')),
        FilledButton(
          onPressed: _saving || _selected.isEmpty ? null : _confirm,
          child: Text(_saving ? 'Guardando…' : 'Confirmar entregas')),
      ],
    ),
  );
}
