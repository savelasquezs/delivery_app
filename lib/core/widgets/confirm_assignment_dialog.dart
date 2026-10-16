import 'package:flutter/material.dart';
import '../errors/user_facing_error.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class ConfirmAssignmentDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final Future<void> Function() onConfirm;

  const ConfirmAssignmentDialog({
    super.key,
    required this.title,
    this.subtitle,
    required this.onConfirm,
  });

  static Future<bool> show(
    BuildContext context, {
    required String title,
    String? subtitle,
    required Future<void> Function() onConfirm,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ConfirmAssignmentDialog(
        title: title,
        subtitle: subtitle,
        onConfirm: onConfirm,
      ),
    );
    return result ?? false;
  }

  @override
  State<ConfirmAssignmentDialog> createState() =>
      _ConfirmAssignmentDialogState();
}

class _ConfirmAssignmentDialogState extends State<ConfirmAssignmentDialog> {
  bool _isLoading = false;
  String? _error;

  Future<void> _confirm() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await widget.onConfirm();
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFacingErrorMessage(
          error,
          fallback: 'No pudimos asignar los pedidos.',
        );
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isLoading,
      child: AlertDialog(
        title: Text(widget.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.subtitle != null)
                Text(widget.subtitle!,
                    style: Theme.of(context).textTheme.bodyMedium),
              if (_error != null) ...[
                const SizedBox(height: AppTheme.spacingMd),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
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
      ),
    );
  }
}
