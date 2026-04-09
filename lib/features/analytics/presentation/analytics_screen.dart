import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/error_banner.dart';
import '../models/advance_model.dart';
import 'analytics_notifier.dart';

final _money = NumberFormat.currency(locale: 'es_CO', symbol: '\$', decimalDigits: 0);
final _dateLabel = DateFormat('dd/MM/yyyy');

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

  Future<void> _pickDateRange() async {
    final state = ref.read(analyticsNotifierProvider);
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(
        start: state.fromDate,
        end: state.toDate,
      ),
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
      locale: const Locale('es', 'CO'),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: AppColors.primary,
            onPrimary: Colors.white,
            surface: AppColors.surface,
            onSurface: AppColors.onSurface,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      ref
          .read(analyticsNotifierProvider.notifier)
          .changeDateRange(picked.start, picked.end);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(analyticsNotifierProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: () => ref.read(analyticsNotifierProvider.notifier).load(),
        color: AppColors.primary,
        backgroundColor: AppColors.card,
        child: ListView(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          children: [
            // ── Selector de período ────────────────────────────────
            _PeriodCard(
              from: state.fromDate,
              to: state.toDate,
              isLoading: state.isLoading,
              onTap: _pickDateRange,
            ),
            const SizedBox(height: 12),

            // ── Error + día bloqueado ──────────────────────────────
            if (state.error != null)
              ErrorBanner(
                message: state.error!,
                onRetry: () =>
                    ref.read(analyticsNotifierProvider.notifier).load(),
              ),
            if (state.dayState?.isBlocked == true)
              _BlockedDayBanner(reason: state.dayState!.blockedReason),

            // ── KPI cards ─────────────────────────────────────────
            if (state.isLoading && state.stats == null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              )
            else if (state.stats != null) ...[
              _SectionLabel('RENDIMIENTO DEL PERÍODO'),
              const SizedBox(height: 8),
              _KpiGrid(stats: state.stats!),
              const SizedBox(height: 16),

              // ── Detalle diario ─────────────────────────────────
              if (state.stats!.dailyBreakdown.isNotEmpty) ...[
                _SectionLabel('DETALLE POR DÍA'),
                const SizedBox(height: 8),
                _DailyBreakdownCard(items: state.stats!.dailyBreakdown),
                const SizedBox(height: 16),
              ],
            ],

            // ── Préstamos / Abonos ────────────────────────────────
            _SectionLabel('PRÉSTAMOS / DESCUENTOS'),
            const SizedBox(height: 8),
            _AdvancesCard(
              advances: state.advances,
              isLoading: state.isLoadingAdvances,
              error: state.advancesError,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets de la pantalla
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: AppColors.hint,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      );
}

class _PeriodCard extends StatelessWidget {
  final DateTime from;
  final DateTime to;
  final bool isLoading;
  final VoidCallback onTap;
  const _PeriodCard({
    required this.from,
    required this.to,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final sameDay = from.year == to.year &&
        from.month == to.month &&
        from.day == to.day;
    final label = sameDay
        ? _dateLabel.format(from)
        : '${_dateLabel.format(from)} – ${_dateLabel.format(to)}';

    return InkWell(
      onTap: isLoading ? null : onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.primaryContainer,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border:
              Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.date_range_outlined,
                color: AppColors.primaryLight, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Período analizado',
                    style: TextStyle(
                        color: AppColors.hint,
                        fontSize: 11,
                        fontWeight: FontWeight.w500),
                  ),
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppColors.primaryLight,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            if (isLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primaryLight),
              )
            else
              const Icon(Icons.edit_calendar_outlined,
                  color: AppColors.primaryLight, size: 18),
          ],
        ),
      ),
    );
  }
}

class _KpiGrid extends StatelessWidget {
  final DashboardStats stats;
  const _KpiGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    final cards = [
      _KpiData(
        icon: Icons.local_shipping_outlined,
        label: 'Entregas en el período',
        value: '${stats.totalDeliveries}',
        color: AppColors.accent,
      ),
      _KpiData(
        icon: Icons.savings_outlined,
        label: 'Ganancias en fees',
        value: _money.format(stats.totalEarnings),
        color: AppColors.warning,
      ),
      if (stats.avgDeliveryMinutes != null)
        _KpiData(
          icon: Icons.timer_outlined,
          label: 'Tiempo prom. entrega',
          value: '${stats.avgDeliveryMinutes!.toStringAsFixed(0)} min',
          color: AppColors.statusReady,
        ),
    ];

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.5,
      children: cards.map((d) => _KpiCard(data: d)).toList(),
    );
  }
}

class _KpiData {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _KpiData({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
}

class _KpiCard extends StatelessWidget {
  final _KpiData data;
  const _KpiCard({required this.data});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: data.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(data.icon, color: data.color, size: 16),
            ),
            const Spacer(),
            Text(data.label,
                style:
                    const TextStyle(color: AppColors.hint, fontSize: 11)),
            const SizedBox(height: 2),
            Text(
              data.value,
              style: TextStyle(
                color: data.color,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );
}

class _DailyBreakdownCard extends StatelessWidget {
  final List<DailyDelivery> items;
  const _DailyBreakdownCard({required this.items});

  @override
  Widget build(BuildContext context) => Container(
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
                      horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.date,
                          style: const TextStyle(
                              color: AppColors.onSurface, fontSize: 13),
                        ),
                      ),
                      Text(
                        '${item.count} ent.',
                        style: const TextStyle(
                            color: AppColors.hint, fontSize: 12),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _money.format(item.amount),
                        style: const TextStyle(
                          color: AppColors.primaryLight,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (i < items.length - 1)
                  const Divider(height: 1, indent: 14, endIndent: 14),
              ],
            );
          }).toList(),
        ),
      );
}

class _BlockedDayBanner extends StatelessWidget {
  final String? reason;
  const _BlockedDayBanner({this.reason});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border:
              Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_outline,
                color: AppColors.warning, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                reason ??
                    'Tu día está bloqueado. Contacta a administración.',
                style: const TextStyle(
                    color: AppColors.warning, fontSize: 13),
              ),
            ),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Tabla de préstamos / abonos
// ─────────────────────────────────────────────────────────────────────────────

class _AdvancesCard extends StatelessWidget {
  final List<DeliverymanAdvance> advances;
  final bool isLoading;
  final String? error;
  const _AdvancesCard({
    required this.advances,
    required this.isLoading,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Container(
        height: 80,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.divider),
        ),
        child: const CircularProgressIndicator(
            color: AppColors.primary, strokeWidth: 2),
      );
    }

    if (error != null) {
      // Si es un error de permisos (403), mostramos mensaje amigable
      final isPermissionError = error!.contains('403') ||
          error!.toLowerCase().contains('permiso') ||
          error!.toLowerCase().contains('forbid') ||
          error!.toLowerCase().contains('unauthorized') ||
          error!.toLowerCase().contains('acceso');
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isPermissionError ? Icons.lock_outline : Icons.error_outline,
              color: AppColors.hint,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              isPermissionError
                  ? 'Información no disponible para este rol'
                  : 'No se pudieron cargar los préstamos',
              style: const TextStyle(color: AppColors.hint, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (advances.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.divider),
        ),
        child: const Text(
          'Sin préstamos en este período',
          style: TextStyle(color: AppColors.hint, fontSize: 13),
        ),
      );
    }

    final total = advances.fold<double>(0, (s, a) => s + a.amount);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          // ── Header tabla ──────────────────────────────────────
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.08),
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppTheme.radiusMd)),
              border: Border(
                  bottom: BorderSide(
                      color: AppColors.error.withValues(alpha: 0.2))),
            ),
            child: Row(
              children: [
                const Text('Fecha',
                    style: TextStyle(
                        color: AppColors.hint,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                const Text('Notas',
                    style: TextStyle(
                        color: AppColors.hint,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 16),
                const Text('Monto',
                    style: TextStyle(
                        color: AppColors.hint,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          // ── Filas ─────────────────────────────────────────────
          ...advances.asMap().entries.map((entry) {
            final i = entry.key;
            final adv = entry.value;
            final dateStr = adv.createdAt.isNotEmpty
                ? _dateLabel
                    .format(DateTime.tryParse(adv.createdAt) ?? DateTime.now())
                : '—';
            return Column(
              children: [
                if (i > 0)
                  const Divider(height: 1, indent: 14, endIndent: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Text(dateStr,
                          style: const TextStyle(
                              color: AppColors.onSurface, fontSize: 12)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          adv.notes?.trim().isNotEmpty == true
                              ? adv.notes!
                              : '—',
                          style: const TextStyle(
                              color: AppColors.hint, fontSize: 12),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _money.format(adv.amount),
                        style: const TextStyle(
                          color: AppColors.error,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }),
          // ── Total ─────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.06),
              borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(AppTheme.radiusMd)),
              border: Border(
                  top: BorderSide(
                      color: AppColors.error.withValues(alpha: 0.2))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Total descuentos',
                  style: TextStyle(
                      color: AppColors.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 13),
                ),
                Text(
                  _money.format(total),
                  style: const TextStyle(
                    color: AppColors.error,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
