import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../../features/orders/models/order_models.dart';
import 'status_badge.dart';

final _currencyFormat =
    NumberFormat.currency(locale: 'es_CO', symbol: '\$', decimalDigits: 0);

class OrderCard extends StatelessWidget {
  final Order order;
  final VoidCallback? onTap;
  final Widget? trailing;

  const OrderCard({
    super.key,
    required this.order,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _OrderIdBadge(orderId: order.id),
                  const SizedBox(width: AppTheme.spacingSm),
                  StatusBadge(status: order.status),
                  const Spacer(),
                  Text(
                    _currencyFormat.format(order.total),
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              if (order.customer != null) ...[
                const SizedBox(height: AppTheme.spacingSm),
                Row(
                  children: [
                    const Icon(Icons.person_outline,
                        size: 14, color: AppColors.hint),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        order.customer!.name,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (order.customer!.phone != null)
                      Text(
                        order.customer!.phone!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ],
              if (order.displayAddressLine != null &&
                  order.displayAddressLine!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.location_on_outlined,
                        size: 14, color: AppColors.hint),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        order.displayAddressLine!,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              if (order.addressAdditionalInfo != null &&
                  order.addressAdditionalInfo!.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Padding(
                  padding: const EdgeInsets.only(left: 18),
                  child: Text(
                    order.addressAdditionalInfo!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.hint,
                          fontSize: 11,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (order.notes != null && order.notes!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.notes, size: 14, color: AppColors.hint),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        order.notes!,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppTheme.spacingSm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        const Icon(Icons.location_city_outlined,
                            size: 13, color: AppColors.hint),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            order.displayNeighborhoodLabel ?? 'Sin barrio',
                            style: TextStyle(
                              color: order.displayNeighborhoodLabel != null
                                  ? AppColors.hint
                                  : AppColors.hint.withValues(alpha: 0.65),
                              fontSize: 11,
                              fontWeight: order.displayNeighborhoodLabel != null
                                  ? FontWeight.w500
                                  : FontWeight.normal,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    DateFormat('HH:mm').format(order.createdAt.toLocal()),
                    style: const TextStyle(color: AppColors.hint, fontSize: 11),
                  ),
                ],
              ),
              if (order.branchName != null &&
                  order.branchName!.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.store_outlined,
                        size: 11, color: AppColors.hint),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Sucursal · ${order.branchName}',
                        style: TextStyle(
                          color: AppColors.hint.withValues(alpha: 0.85),
                          fontSize: 10,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              if (trailing != null) ...[
                const SizedBox(height: AppTheme.spacingSm),
                const Divider(height: 1),
                const SizedBox(height: AppTheme.spacingSm),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderIdBadge extends StatelessWidget {
  final int orderId;
  const _OrderIdBadge({required this.orderId});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '#$orderId',
        style: const TextStyle(
          color: AppColors.primaryLight,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }
}
