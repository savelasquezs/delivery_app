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
  final Widget? topContent;
  final Widget? trailing;

  /// Muestra domicilio y efectivo a cobrar / «Ya pagó» (p. ej. historial).
  final bool showFeeAndCashSummary;

  const OrderCard({
    super.key,
    required this.order,
    this.onTap,
    this.topContent,
    this.trailing,
    this.showFeeAndCashSummary = false,
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
              if (topContent != null) ...[
                topContent!,
                const SizedBox(height: AppTheme.spacingSm),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _OrderIdBadge(orderId: order.id),
                  const SizedBox(width: AppTheme.spacingSm),
                  StatusBadge(status: order.status),
                  const Spacer(),
                  if (showFeeAndCashSummary)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'A cobrar',
                          style: TextStyle(
                            color: AppColors.hint.withValues(alpha: 0.9),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _currencyFormat.format(order.cashToCollectOnDelivery),
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w800,
                            fontSize: 24,
                            height: 1.05,
                          ),
                        ),
                        if (order.showYaPagoMessage) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Ya pagó',
                            style: TextStyle(
                              color:
                                  AppColors.accentLight.withValues(alpha: 0.98),
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ],
                    )
                  else
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
              if (showFeeAndCashSummary &&
                  ((order.deliveryFee != null &&
                          order.deliveryFee! > Order.kPaymentCoverTolerance) ||
                      (order.total > Order.kPaymentCoverTolerance))) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (order.deliveryFee != null &&
                        order.deliveryFee! > Order.kPaymentCoverTolerance)
                      Text(
                        'Domicilio ${_currencyFormat.format(order.deliveryFee)}',
                        style: TextStyle(
                          color: AppColors.onSurface.withValues(alpha: 0.95),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (order.total > Order.kPaymentCoverTolerance)
                      Text(
                        'Total pedido ${_currencyFormat.format(order.total)}',
                        style: TextStyle(
                          color: AppColors.hint.withValues(alpha: 0.95),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ],
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
