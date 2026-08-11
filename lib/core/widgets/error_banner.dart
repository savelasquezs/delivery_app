import 'package:flutter/material.dart';
import '../errors/user_facing_error.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class ErrorBanner extends StatelessWidget {
  final Object message;
  final String title;
  final VoidCallback? onRetry;
  final EdgeInsetsGeometry margin;

  const ErrorBanner({
    super.key,
    required this.message,
    this.title = 'Algo necesita tu atención',
    this.onRetry,
    this.margin = const EdgeInsets.all(AppTheme.spacingMd),
  });

  static void show(
    BuildContext context,
    Object error, {
    String fallback = defaultUserErrorMessage,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.priority_high_rounded,
                color: AppColors.error,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                userFacingErrorMessage(error, fallback: fallback),
                style: const TextStyle(
                  color: AppColors.onSurface,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.cardElevated,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  static void showSuccess(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_outline,
                color: AppColors.success, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.cardElevated,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final friendlyMessage = userFacingErrorMessage(message);
    return Semantics(
      liveRegion: true,
      label: '$title. $friendlyMessage',
      child: Container(
        margin: margin,
        padding: const EdgeInsets.all(AppTheme.spacingMd),
        decoration: BoxDecoration(
          color: AppColors.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(
            color: AppColors.error.withValues(alpha: 0.22),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.priority_high_rounded,
                color: AppColors.error,
                size: 22,
              ),
            ),
            const SizedBox(width: AppTheme.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    friendlyMessage,
                    style: const TextStyle(
                      color: AppColors.onCard,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                  if (onRetry != null) ...[
                    const SizedBox(height: AppTheme.spacingSm),
                    TextButton.icon(
                      onPressed: onRetry,
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.error,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Intentar de nuevo'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
