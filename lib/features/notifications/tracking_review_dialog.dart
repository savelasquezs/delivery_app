import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'fcm_service.dart';

Future<void> showTrackingReviewDialog(
  BuildContext context,
  DeliveryTrackingReviewNotice notice,
) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          icon: const Icon(
            Icons.warning_amber_rounded,
            color: AppColors.warning,
            size: 40,
          ),
          title: Text(notice.title),
          content: Text(notice.body),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Aceptar'),
            ),
          ],
        ),
      ),
    );
