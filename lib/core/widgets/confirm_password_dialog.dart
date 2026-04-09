import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class ConfirmPasswordDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final Future<void> Function(String password) onConfirm;

  const ConfirmPasswordDialog({
    super.key,
    required this.title,
    this.subtitle,
    required this.onConfirm,
  });

  static Future<bool> show(
    BuildContext context, {
    required String title,
    String? subtitle,
    required Future<void> Function(String password) onConfirm,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ConfirmPasswordDialog(
        title: title,
        subtitle: subtitle,
        onConfirm: onConfirm,
      ),
    );
    return result ?? false;
  }

  @override
  State<ConfirmPasswordDialog> createState() => _ConfirmPasswordDialogState();
}

class _ConfirmPasswordDialogState extends State<ConfirmPasswordDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_controller.text.isEmpty) {
      setState(() => _error = 'Ingresa tu contraseña');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await widget.onConfirm(_controller.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.subtitle != null) ...[
            Text(
              widget.subtitle!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppTheme.spacingMd),
          ],
          TextField(
            controller: _controller,
            obscureText: _obscure,
            autofocus: true,
            style: const TextStyle(color: AppColors.onBackground),
            decoration: InputDecoration(
              labelText: 'Contraseña',
              labelStyle: const TextStyle(color: AppColors.hint),
              prefixIcon:
                  const Icon(Icons.lock_outline, color: AppColors.hint),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: AppColors.hint,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
              errorText: _error,
            ),
            onSubmitted: (_) => _confirm(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _confirm,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.onPrimary,
                  ),
                )
              : const Text('Confirmar'),
        ),
      ],
    );
  }
}
