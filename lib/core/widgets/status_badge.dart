import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../../features/orders/models/order_models.dart';

class StatusBadge extends StatelessWidget {
  final OrderStatus status;

  const StatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final color = _colorForStatus(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        status.displayName,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _colorForStatus(OrderStatus status) => switch (status) {
        OrderStatus.taken => AppColors.statusTaken,
        OrderStatus.inPreparation => AppColors.statusPreparation,
        OrderStatus.ready => AppColors.statusReady,
        OrderStatus.onTheWay => AppColors.statusOnTheWay,
        OrderStatus.delivered => AppColors.statusDelivered,
        OrderStatus.cancelled => AppColors.statusCancelled,
      };
}
