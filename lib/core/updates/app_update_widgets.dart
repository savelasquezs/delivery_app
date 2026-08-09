import 'package:flutter/material.dart';

import '../api/api_constants.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'delivery_app_release_manifest.dart';

class AppUpdateCard extends StatelessWidget {
  const AppUpdateCard({
    super.key,
    required this.result,
    required this.onDownload,
    this.onDismiss,
    this.compact = false,
  });

  final AppUpdateCheckResult result;
  final VoidCallback onDownload;
  final VoidCallback? onDismiss;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final forced = result.kind == AppUpdateKind.forced;
    final msg = result.manifest.message?.trim();
    final title =
        forced ? 'Actualizacion necesaria' : 'Nueva version disponible';

    return Container(
      padding:
          EdgeInsets.all(compact ? AppTheme.spacingMd : AppTheme.spacingLg),
      decoration: BoxDecoration(
        color: forced
            ? AppColors.error.withValues(alpha: 0.08)
            : AppColors.primaryContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: forced
              ? AppColors.error.withValues(alpha: 0.35)
              : AppColors.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                forced ? Icons.warning_amber_rounded : Icons.system_update_alt,
                color: forced ? AppColors.error : AppColors.primaryLight,
                size: compact ? 22 : 28,
              ),
              const SizedBox(width: AppTheme.spacingSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppColors.onBackground,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Instalada: build ${result.localBuild}  |  Disponible: ${result.manifest.versionName}+${result.manifest.buildNumber}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.onSurface,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (msg != null && msg.isNotEmpty) ...[
            const SizedBox(height: AppTheme.spacingSm),
            Text(
              msg,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.onSurface,
                    height: 1.35,
                  ),
            ),
          ],
          const SizedBox(height: AppTheme.spacingMd),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (onDismiss != null) ...[
                TextButton(
                  onPressed: onDismiss,
                  child: Text(forced ? 'Cerrar' : 'Mas tarde'),
                ),
                const SizedBox(width: AppTheme.spacingXs),
              ],
              FilledButton.icon(
                onPressed: onDownload,
                icon: const Icon(Icons.download_rounded),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.onPrimary,
                ),
                label: Text(
                  kPlayDistribution ? 'Actualizar en Play Store' : 'Descargar APK',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> showAppUpdateDialog({
  required BuildContext context,
  required AppUpdateCheckResult result,
  required VoidCallback onDownload,
  VoidCallback? onDismiss,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      titlePadding: const EdgeInsets.fromLTRB(
        AppTheme.spacingLg,
        AppTheme.spacingLg,
        AppTheme.spacingLg,
        0,
      ),
      contentPadding: const EdgeInsets.all(AppTheme.spacingLg),
      title: Text(
        result.kind == AppUpdateKind.forced
            ? 'Actualiza la app para continuar al dia'
            : 'Hay una nueva version de la app',
        style: const TextStyle(
          color: AppColors.onBackground,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: AppUpdateCard(
        result: result,
        compact: true,
        onDownload: () {
          Navigator.of(dialogContext).pop();
          onDownload();
        },
        onDismiss: onDismiss == null
            ? null
            : () {
                Navigator.of(dialogContext).pop();
                onDismiss();
              },
      ),
    ),
  );
}
