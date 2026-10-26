import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Botón compacto de icono + texto (misma apariencia que acciones en En ruta).
class CompactActionButton extends StatelessWidget {
  final IconData? icon;
  final Widget? leading;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool filled;
  final bool iconOnly;

  const CompactActionButton({
    super.key,
    this.icon,
    this.leading,
    required this.label,
    required this.color,
    required this.onTap,
    this.filled = false,
    this.iconOnly = false,
  }) : assert(icon != null || leading != null);

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = filled
        ? Colors.white
        : enabled
            ? color
            : AppColors.hint;
    return Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          child: Opacity(
            opacity: enabled ? 1 : 0.55,
            child: Container(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: filled ? color : color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                border: Border.all(
                  color: filled ? color : color.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  leading ?? Icon(icon, size: iconOnly ? 22 : 14, color: fg),
                  if (!iconOnly) ...[
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ));
  }
}
