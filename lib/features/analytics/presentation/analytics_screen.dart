import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/error_banner.dart';
import 'analytics_notifier.dart';

final _currencyFormat =
    NumberFormat.currency(locale: 'es_CO', symbol: '\$', decimalDigits: 0);

class AnalyticsScreen extends ConsumerStatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(analyticsNotifierProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(analyticsNotifierProvider);

    if (state.isLoading) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
            child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: () =>
            ref.read(analyticsNotifierProvider.notifier).load(),
        color: AppColors.primary,
        backgroundColor: AppColors.card,
        child: ListView(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          children: [
            if (state.error != null)
              ErrorBanner(
                message: state.error!,
                onRetry: () =>
                    ref.read(analyticsNotifierProvider.notifier).load(),
              ),
            if (state.dayState?.isBlocked == true)
              _BlockedDayBanner(reason: state.dayState!.blockedReason),
            const SizedBox(height: AppTheme.spacingSm),
            const _SectionTitle(title: 'Hoy'),
            const SizedBox(height: AppTheme.spacingSm),
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    icon: Icons.check_circle_outline,
                    label: 'Entregados',
                    value: '${state.stats?.deliveredToday ?? 0}',
                    color: AppColors.statusDelivered,
                  ),
                ),
                const SizedBox(width: AppTheme.spacingMd),
                Expanded(
                  child: _StatCard(
                    icon: Icons.attach_money,
                    label: 'Ganancias',
                    value: _currencyFormat
                        .format(state.stats?.earningsToday ?? 0),
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spacingMd),
            const _SectionTitle(title: 'Mes actual'),
            const SizedBox(height: AppTheme.spacingSm),
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    icon: Icons.local_shipping_outlined,
                    label: 'Total entregas',
                    value: '${state.stats?.totalDeliveries ?? 0}',
                    color: AppColors.info,
                  ),
                ),
                const SizedBox(width: AppTheme.spacingMd),
                Expanded(
                  child: _StatCard(
                    icon: Icons.savings_outlined,
                    label: 'Total ganancias',
                    value: _currencyFormat
                        .format(state.stats?.totalEarnings ?? 0),
                    color: AppColors.warning,
                  ),
                ),
              ],
            ),
            if (state.stats != null &&
                state.stats!.dailyBreakdown.isNotEmpty) ...[
              const SizedBox(height: AppTheme.spacingLg),
              const _SectionTitle(title: 'Detalle por día'),
              const SizedBox(height: AppTheme.spacingSm),
              _DailyBreakdownList(items: state.stats!.dailyBreakdown),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(title,
        style: Theme.of(context).textTheme.titleLarge);
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: AppTheme.spacingSm),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }
}

class _BlockedDayBanner extends StatelessWidget {
  final String? reason;
  const _BlockedDayBanner({this.reason});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, color: AppColors.warning, size: 18),
          const SizedBox(width: AppTheme.spacingSm),
          Expanded(
            child: Text(
              reason ?? 'Tu día está bloqueado. Contacta a administración.',
              style: const TextStyle(color: AppColors.warning, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyBreakdownList extends StatelessWidget {
  final List<DailyDelivery> items;
  const _DailyBreakdownList({required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: items.asMap().entries.map((entry) {
          final i = entry.key;
          final item = entry.value;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.spacingMd,
                    vertical: AppTheme.spacingSm),
                child: Row(
                  children: [
                    Text(
                      item.date,
                      style: const TextStyle(
                          color: AppColors.onSurface, fontSize: 13),
                    ),
                    const Spacer(),
                    Text(
                      '${item.count} entregas',
                      style: const TextStyle(
                          color: AppColors.hint, fontSize: 12),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _currencyFormat.format(item.amount),
                      style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (i < items.length - 1)
                const Divider(height: 1, indent: 16, endIndent: 16),
            ],
          );
        }).toList(),
      ),
    );
  }
}
