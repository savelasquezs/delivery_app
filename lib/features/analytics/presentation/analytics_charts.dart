import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../models/analytics_dashboard_models.dart';

/// Evolución de entregas y fees (parte domiciliario) por bucket.
class DeliveryEvolutionCharts extends StatelessWidget {
  final List<String> labels;
  final List<int> deliveries;
  final List<double> feesPayable;

  const DeliveryEvolutionCharts({
    super.key,
    required this.labels,
    required this.deliveries,
    required this.feesPayable,
  });

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) {
      return const SizedBox.shrink();
    }
    final n = labels.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Entregas por período',
          style: TextStyle(
            color: AppColors.hint.withValues(alpha: 0.95),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 200,
          child: _LineChart(
            color: AppColors.accent,
            maxYHint:
                deliveries.reduce((a, b) => a > b ? a : b).toDouble() * 1.15 +
                    1,
            spots: [
              for (var i = 0; i < n; i++)
                FlSpot(i.toDouble(),
                    (i < deliveries.length ? deliveries[i] : 0).toDouble()),
            ],
            labels: labels,
            isIntegerY: true,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Tu parte en fees (nómina)',
          style: TextStyle(
            color: AppColors.hint.withValues(alpha: 0.95),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 200,
          child: _LineChart(
            color: AppColors.warning,
            maxYHint: feesPayable.isEmpty
                ? 1
                : (feesPayable.reduce((a, b) => a > b ? a : b) * 1.1 + 1)
                    .clamp(1.0, double.infinity),
            spots: [
              for (var i = 0; i < n; i++)
                FlSpot(
                  i.toDouble(),
                  i < feesPayable.length ? feesPayable[i] : 0,
                ),
            ],
            labels: labels,
            isIntegerY: false,
          ),
        ),
      ],
    );
  }
}

class _LineChart extends StatelessWidget {
  final List<FlSpot> spots;
  final List<String> labels;
  final Color color;
  final double maxYHint;
  final bool isIntegerY;

  const _LineChart({
    required this.spots,
    required this.labels,
    required this.color,
    required this.maxYHint,
    required this.isIntegerY,
  });

  @override
  Widget build(BuildContext context) {
    final validSpots =
        spots.where((s) => s.y.isFinite && s.x.isFinite).toList();
    if (validSpots.isEmpty) {
      return const Center(child: Text('Sin datos'));
    }

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (labels.length - 1).clamp(0, 999).toDouble(),
        minY: 0,
        maxY: maxYHint <= 0 ? 1 : maxYHint,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxYHint > 5 ? maxYHint / 4 : 1,
          getDrawingHorizontalLine: (v) => FlLine(
            color: AppColors.divider.withValues(alpha: 0.5),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (value, meta) => Text(
                isIntegerY
                    ? value.toInt().toString()
                    : value >= 1000
                        ? '${(value / 1000).toStringAsFixed(0)}k'
                        : value.toStringAsFixed(0),
                style: const TextStyle(color: AppColors.hint, fontSize: 9),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (labels.length / 4).clamp(1, 999).toDouble(),
              getTitlesWidget: (value, meta) {
                final i = value.round().clamp(0, labels.length - 1);
                final raw = labels[i];
                final short = raw.length > 8 ? '${raw.substring(0, 6)}…' : raw;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    short,
                    style: const TextStyle(color: AppColors.hint, fontSize: 9),
                  ),
                );
              },
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: validSpots,
            isCurved: true,
            color: color,
            barWidth: 2,
            dotData: const FlDotData(show: true),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Resumen compacto de rutas cerradas (SLA).
class RouteMetricsSection extends StatelessWidget {
  final RouteDashboardMetrics metrics;

  const RouteMetricsSection({super.key, required this.metrics});

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
          const Text(
            'Rutas cerradas',
            style: TextStyle(
              color: AppColors.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _chip(
                'Completadas',
                '${metrics.completedRoutesCount}',
                AppColors.primaryLight,
              ),
              _chip(
                'En hora (período)',
                '${metrics.periodOnTimePercent.toStringAsFixed(0)}%',
                AppColors.success,
              ),
            ],
          ),
          if (metrics.evolutionRoutesCompleted.isNotEmpty) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 160,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: () {
                    final m = metrics.evolutionRoutesCompleted
                        .reduce((a, b) => a > b ? a : b);
                    return m.toDouble() * 1.2 + 1;
                  }(),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (v) => FlLine(
                      color: AppColors.divider.withValues(alpha: 0.4),
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: false,
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        getTitlesWidget: (v, m) => Text(
                          v.toInt().toString(),
                          style: const TextStyle(
                              color: AppColors.hint, fontSize: 9),
                        ),
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0;
                        i < metrics.evolutionRoutesCompleted.length;
                        i++)
                      BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: metrics.evolutionRoutesCompleted[i].toDouble(),
                            color: AppColors.primary,
                            width: 10,
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4)),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (metrics.recentRoutes.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Últimas rutas',
              style: TextStyle(
                color: AppColors.hint,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            ...metrics.recentRoutes.take(5).map((r) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        r.metSla == true
                            ? Icons.check_circle_outline
                            : r.metSla == false
                                ? Icons.cancel_outlined
                                : Icons.help_outline,
                        size: 16,
                        color: r.metSla == true
                            ? AppColors.success
                            : r.metSla == false
                                ? AppColors.error
                                : AppColors.hint,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          r.completedAtUtc != null
                              ? '${r.completedAtUtc!.toLocal()}'
                              : 'Ruta #${r.id}',
                          style: const TextStyle(
                            color: AppColors.onSurface,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${r.totalDistanceKm.toStringAsFixed(1)} km',
                        style: const TextStyle(
                            color: AppColors.hint, fontSize: 11),
                      ),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  TextStyle(color: color.withValues(alpha: 0.9), fontSize: 10)),
          Text(value,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w800, fontSize: 14)),
        ],
      ),
    );
  }
}
