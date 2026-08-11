import '../../../core/constants/delivery_payroll.dart';

class RouteHistoryRow {
  final int id;
  final DateTime? completedAtUtc;
  final int? actualDurationSeconds;
  final int? metaDurationSeconds;
  final bool? metSla;
  final double totalDistanceKm;

  const RouteHistoryRow({
    required this.id,
    this.completedAtUtc,
    this.actualDurationSeconds,
    this.metaDurationSeconds,
    this.metSla,
    required this.totalDistanceKm,
  });

  factory RouteHistoryRow.fromJson(Map<String, dynamic> json) {
    final meters = (json['totalDistanceMeters'] as num?)?.toInt() ?? 0;
    return RouteHistoryRow(
      id: json['id'] as int? ?? 0,
      completedAtUtc: json['completedAtUtc'] != null
          ? DateTime.tryParse(json['completedAtUtc'].toString())
          : null,
      actualDurationSeconds: (json['actualDurationSeconds'] as num?)?.toInt(),
      metaDurationSeconds: (json['metaDurationSeconds'] as num?)?.toInt(),
      metSla: json['metSla'] as bool?,
      totalDistanceKm: meters / 1000.0,
    );
  }
}

class RouteDashboardMetrics {
  final int completedRoutesCount;
  final double periodOnTimePercent;
  final List<int> evolutionRoutesCompleted;
  final List<double?> evolutionOnTimePercent;
  final List<RouteHistoryRow> recentRoutes;

  const RouteDashboardMetrics({
    required this.completedRoutesCount,
    required this.periodOnTimePercent,
    required this.evolutionRoutesCompleted,
    required this.evolutionOnTimePercent,
    required this.recentRoutes,
  });

  factory RouteDashboardMetrics.fromJson(Map<String, dynamic> json) {
    final recent = (json['recentRoutes'] as List<dynamic>? ?? [])
        .map((e) => RouteHistoryRow.fromJson(e as Map<String, dynamic>))
        .toList();
    final onTime = (json['evolutionOnTimePercent'] as List<dynamic>? ?? [])
        .map((e) => e == null ? null : (e as num).toDouble())
        .toList();
    final evoR = (json['evolutionRoutesCompleted'] as List<dynamic>? ?? [])
        .map((e) => (e as num).toInt())
        .toList();
    return RouteDashboardMetrics(
      completedRoutesCount:
          (json['completedRoutesCount'] as num?)?.toInt() ?? 0,
      periodOnTimePercent:
          (json['periodOnTimePercent'] as num?)?.toDouble() ?? 0,
      evolutionRoutesCompleted: evoR,
      evolutionOnTimePercent: onTime,
      recentRoutes: recent,
    );
  }
}

class PayrollExpenseLineItem {
  final int detailId;
  final int headerId;
  final DateTime headerCreatedAt;
  final double lineTotal;
  final String notes;

  const PayrollExpenseLineItem({
    required this.detailId,
    required this.headerId,
    required this.headerCreatedAt,
    required this.lineTotal,
    required this.notes,
  });

  factory PayrollExpenseLineItem.fromJson(Map<String, dynamic> json) =>
      PayrollExpenseLineItem(
        detailId: (json['detailId'] as num?)?.toInt() ?? 0,
        headerId: (json['headerId'] as num?)?.toInt() ?? 0,
        headerCreatedAt:
            DateTime.tryParse(json['headerCreatedAt']?.toString() ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        lineTotal: (json['lineTotal'] as num?)?.toDouble() ?? 0,
        notes: json['notes'] as String? ?? '',
      );
}

class PayrollPeriod {
  final int deliveredOrdersCount;
  final double sumDeliveryFee;
  final double payableDeliveryFee;
  final double expenseLinesTotal;
  final List<PayrollExpenseLineItem> expenseLines;

  const PayrollPeriod({
    required this.deliveredOrdersCount,
    required this.sumDeliveryFee,
    required this.payableDeliveryFee,
    required this.expenseLinesTotal,
    required this.expenseLines,
  });

  factory PayrollPeriod.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const PayrollPeriod(
        deliveredOrdersCount: 0,
        sumDeliveryFee: 0,
        payableDeliveryFee: 0,
        expenseLinesTotal: 0,
        expenseLines: [],
      );
    }
    final linesRaw = json['expenseLines'] as List<dynamic>? ?? [];
    return PayrollPeriod(
      deliveredOrdersCount:
          (json['deliveredOrdersCount'] as num?)?.toInt() ?? 0,
      sumDeliveryFee: (json['sumDeliveryFee'] as num?)?.toDouble() ?? 0,
      payableDeliveryFee: (json['payableDeliveryFee'] as num?)?.toDouble() ?? 0,
      expenseLinesTotal: (json['expenseLinesTotal'] as num?)?.toDouble() ?? 0,
      expenseLines: linesRaw
          .map(
              (e) => PayrollExpenseLineItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class PayrollSeriesPoint {
  final String label;
  final int deliveredOrdersCount;
  final double payableDeliveryFee;
  final double sumDeliveryFee;

  const PayrollSeriesPoint({
    required this.label,
    required this.deliveredOrdersCount,
    required this.payableDeliveryFee,
    required this.sumDeliveryFee,
  });

  factory PayrollSeriesPoint.fromJson(Map<String, dynamic> json) =>
      PayrollSeriesPoint(
        label: json['label'] as String? ?? json['key'] as String? ?? '',
        deliveredOrdersCount:
            (json['deliveredOrdersCount'] as num?)?.toInt() ?? 0,
        payableDeliveryFee:
            (json['payableDeliveryFee'] as num?)?.toDouble() ?? 0,
        sumDeliveryFee: (json['sumDeliveryFee'] as num?)?.toDouble() ?? 0,
      );
}

class UserPayrollInsights {
  final double deliveryFeePayRate;
  final PayrollPeriod period;
  final List<PayrollSeriesPoint> series;

  const UserPayrollInsights({
    required this.deliveryFeePayRate,
    required this.period,
    required this.series,
  });

  factory UserPayrollInsights.fromJson(Map<String, dynamic> json) {
    final rate = (json['deliveryFeePayRate'] as num?)?.toDouble() ??
        kDeliveryFeeDriverShare;
    final seriesRaw = json['series'] as List<dynamic>? ?? [];
    return UserPayrollInsights(
      deliveryFeePayRate: rate,
      period: PayrollPeriod.fromJson(json['period'] as Map<String, dynamic>?),
      series: seriesRaw
          .map((e) => PayrollSeriesPoint.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
