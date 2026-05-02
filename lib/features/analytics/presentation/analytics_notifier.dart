import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_constants.dart';
import '../../../core/api/dio_client.dart';
import '../../../core/constants/delivery_payroll.dart';
import '../../auth/presentation/auth_notifier.dart';
import '../models/advance_model.dart';
import '../models/analytics_dashboard_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Modelos — GET /dashboard/delivery/me (+ routeMetrics)
// ─────────────────────────────────────────────────────────────────────────────

class DashboardStats {
  final int totalDeliveries;

  /// Suma de fees de envío recaudados (100 %) en el período.
  final double totalFeesRecaudo;
  final double? avgDeliveryMinutes;
  final List<String> evolutionLabels;
  final List<int> evolutionDeliveries;
  final List<double> evolutionFees;
  final RouteDashboardMetrics? routeMetrics;

  const DashboardStats({
    required this.totalDeliveries,
    required this.totalFeesRecaudo,
    this.avgDeliveryMinutes,
    required this.evolutionLabels,
    required this.evolutionDeliveries,
    required this.evolutionFees,
    this.routeMetrics,
  });

  factory DashboardStats.fromDeliveryApi(Map<String, dynamic> json) {
    final deliverymen = json['deliverymen'] as List<dynamic>? ?? [];
    final me = deliverymen.isNotEmpty
        ? deliverymen.first as Map<String, dynamic>
        : <String, dynamic>{};

    final labels = (json['evolutionLabels'] as List<dynamic>? ?? [])
        .map((e) => e as String)
        .toList();
    final deliveries = (json['evolutionDeliveries'] as List<dynamic>? ?? [])
        .map((e) => (e as num).toInt())
        .toList();
    final fees = (json['evolutionFees'] as List<dynamic>? ?? [])
        .map((e) => (e as num).toDouble())
        .toList();

    final totalDel = deliveries.fold(0, (a, b) => a + b);
    final totalFee = fees.fold(0.0, (a, b) => a + b);

    RouteDashboardMetrics? routeMetrics;
    final rm = json['routeMetrics'];
    if (rm is Map<String, dynamic>) {
      routeMetrics = RouteDashboardMetrics.fromJson(rm);
    }

    return DashboardStats(
      totalDeliveries: (me['deliveredCount'] as num?)?.toInt() ?? totalDel,
      totalFeesRecaudo:
          (me['deliveryFeeTotal'] as num?)?.toDouble() ?? totalFee,
      avgDeliveryMinutes: (json['avgDeliveryMinutes'] as num?)?.toDouble() ??
          (me['avgDeliveryMinutes'] as num?)?.toDouble(),
      evolutionLabels: labels,
      evolutionDeliveries: deliveries,
      evolutionFees: fees,
      routeMetrics: routeMetrics,
    );
  }

  /// Tabla por bucket usando fee recaudado × tasa (si no hay nómina por punto).
  List<DailyDelivery> dailyBreakdownApplyRate(double payRate) {
    final result = <DailyDelivery>[];
    for (var i = 0; i < evolutionLabels.length; i++) {
      final fee = i < evolutionFees.length ? evolutionFees[i] : 0.0;
      result.add(DailyDelivery(
        date: evolutionLabels[i],
        count: i < evolutionDeliveries.length ? evolutionDeliveries[i] : 0,
        amount: fee * payRate,
      ));
    }
    return result;
  }
}

class DailyDelivery {
  final String date;
  final int count;
  final double amount;

  const DailyDelivery({
    required this.date,
    required this.count,
    required this.amount,
  });
}

class DayBlockState {
  final bool isBlocked;
  final String? blockedReason;

  const DayBlockState({this.isBlocked = false, this.blockedReason});

  factory DayBlockState.fromJson(Map<String, dynamic> json) => DayBlockState(
        isBlocked: json['isBlocked'] as bool? ??
            json['blocked'] as bool? ??
            json['dayBlocked'] as bool? ??
            false,
        blockedReason: json['reason'] as String?,
      );
}

class AnalyticsState {
  final DashboardStats? stats;
  final DayBlockState? dayState;
  final UserPayrollInsights? payrollInsights;
  final String? payrollError;
  final List<DeliverymanAdvance> advances;
  final bool isLoading;
  final bool isLoadingAdvances;
  final String? error;
  final String? advancesError;
  final DateTime fromDate;
  final DateTime toDate;

  /// Rango para abonos (`/me/advances`). Por defecto: solo hoy; al cambiar el
  /// período en el filtro, coincide con [fromDate]/[toDate].
  final DateTime advancesFromDate;
  final DateTime advancesToDate;

  const AnalyticsState({
    this.stats,
    this.dayState,
    this.payrollInsights,
    this.payrollError,
    this.advances = const [],
    this.isLoading = false,
    this.isLoadingAdvances = false,
    this.error,
    this.advancesError,
    required this.fromDate,
    required this.toDate,
    required this.advancesFromDate,
    required this.advancesToDate,
  });

  double get effectivePayRate =>
      payrollInsights?.deliveryFeePayRate ?? kDeliveryFeeDriverShare;

  /// Parte del domiciliario según nómina del API, o estimación desde dashboard.
  double get displayPayableFees {
    if (payrollInsights != null) {
      return payrollInsights!.period.payableDeliveryFee;
    }
    final s = stats;
    if (s == null) return 0;
    return s.totalFeesRecaudo * effectivePayRate;
  }

  int get displayTotalDeliveries {
    final payroll = payrollInsights;
    if (payroll != null) {
      return payroll.period.deliveredOrdersCount;
    }
    return stats?.totalDeliveries ?? 0;
  }

  double get displayTotalFeesRecaudo {
    final payroll = payrollInsights;
    if (payroll != null) {
      return payroll.period.sumDeliveryFee;
    }
    return stats?.totalFeesRecaudo ?? 0;
  }

  List<String> get evolutionLabelsForUi {
    final payroll = payrollInsights;
    if (payroll != null && payroll.series.isNotEmpty) {
      return payroll.series.map((p) => p.label).toList();
    }
    return stats?.evolutionLabels ?? const [];
  }

  List<int> get evolutionDeliveriesForUi {
    final payroll = payrollInsights;
    if (payroll != null && payroll.series.isNotEmpty) {
      return payroll.series.map((p) => p.deliveredOrdersCount).toList();
    }
    return stats?.evolutionDeliveries ?? const [];
  }

  List<double> get evolutionPayableFeesForUi {
    final payroll = payrollInsights;
    if (payroll != null && payroll.series.isNotEmpty) {
      return payroll.series.map((p) => p.payableDeliveryFee).toList();
    }
    final s = stats;
    if (s == null) return const [];
    return [
      for (final fee in s.evolutionFees) fee * effectivePayRate,
    ];
  }

  List<DailyDelivery> get dailyRowsForUi {
    final payroll = payrollInsights;
    if (payroll != null && payroll.series.isNotEmpty) {
      return payroll.series
          .map(
            (p) => DailyDelivery(
              date: p.label,
              count: p.deliveredOrdersCount,
              amount: p.payableDeliveryFee,
            ),
          )
          .toList();
    }
    final s = stats;
    if (s == null) return [];
    return s.dailyBreakdownApplyRate(effectivePayRate);
  }

  AnalyticsState copyWith({
    DashboardStats? stats,
    DayBlockState? dayState,
    UserPayrollInsights? payrollInsights,
    bool assignPayrollInsights = false,
    String? payrollError,
    List<DeliverymanAdvance>? advances,
    bool? isLoading,
    bool? isLoadingAdvances,
    String? error,
    String? advancesError,
    DateTime? fromDate,
    DateTime? toDate,
    DateTime? advancesFromDate,
    DateTime? advancesToDate,
    bool clearError = false,
    bool clearAdvancesError = false,
    bool clearPayrollError = false,
  }) =>
      AnalyticsState(
        stats: stats ?? this.stats,
        dayState: dayState ?? this.dayState,
        payrollInsights: assignPayrollInsights
            ? payrollInsights
            : (payrollInsights ?? this.payrollInsights),
        payrollError:
            clearPayrollError ? null : (payrollError ?? this.payrollError),
        advances: advances ?? this.advances,
        isLoading: isLoading ?? this.isLoading,
        isLoadingAdvances: isLoadingAdvances ?? this.isLoadingAdvances,
        error: clearError ? null : (error ?? this.error),
        advancesError:
            clearAdvancesError ? null : (advancesError ?? this.advancesError),
        fromDate: fromDate ?? this.fromDate,
        toDate: toDate ?? this.toDate,
        advancesFromDate: advancesFromDate ?? this.advancesFromDate,
        advancesToDate: advancesToDate ?? this.advancesToDate,
      );

  static AnalyticsState initial() {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    return AnalyticsState(
      fromDate: monthStart,
      toDate: now,
      advancesFromDate: monthStart,
      advancesToDate: now,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Notifier
// ─────────────────────────────────────────────────────────────────────────────

class AnalyticsNotifier extends StateNotifier<AnalyticsState> {
  final DioClient _client;
  final Ref _ref;

  AnalyticsNotifier(this._client, this._ref) : super(AnalyticsState.initial());

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime _colombiaDayStartUtc(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day, 5);

  static DateTime _colombiaDayEndUtc(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day + 1, 5)
          .subtract(const Duration(milliseconds: 1));

  static String _seriesGranularity(DateTime from, DateTime to) {
    final days = to.difference(from).inDays.abs() + 1;
    return days > 45 ? 'biweek' : 'day';
  }

  Future<void> load({DateTime? from, DateTime? to}) async {
    if (!mounted) return;
    final fromD = from ?? state.fromDate;
    final toD = to ?? state.toDate;
    final userId = _ref.read(authNotifierProvider).user?.id;

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearPayrollError: true,
      fromDate: fromD,
      toDate: toD,
    );

    try {
      final fromStr = _colombiaDayStartUtc(fromD).toIso8601String();
      final toStr = _colombiaDayEndUtc(toD).toIso8601String();

      final dashFuture = _client.get<Map<String, dynamic>>(
        ApiConstants.dashboardDeliveryMe,
        queryParameters: {'from': fromStr, 'to': toStr},
        fromJson: (d) => d as Map<String, dynamic>,
      );
      final dayFuture = _client.get<Map<String, dynamic>>(
        ApiConstants.myDayState,
        fromJson: (d) => d as Map<String, dynamic>,
      );

      Future<UserPayrollInsights?> loadPayroll() async {
        if (userId == null) return null;
        try {
          final j = await _client.get<Map<String, dynamic>>(
            ApiConstants.userPayrollInsights(userId),
            queryParameters: {
              'from': _fmt(fromD),
              'to': _fmt(toD),
              'seriesGranularity': _seriesGranularity(fromD, toD),
            },
            fromJson: (d) => d as Map<String, dynamic>,
          );
          return UserPayrollInsights.fromJson(j);
        } catch (e) {
          if (mounted) {
            state = state.copyWith(payrollError: e.toString());
          }
          return null;
        }
      }

      final results = await Future.wait<Object?>([
        dashFuture,
        dayFuture,
        loadPayroll(),
      ]);

      if (!mounted) return;
      final dash = results[0]! as Map<String, dynamic>;
      final dayJson = results[1]! as Map<String, dynamic>;
      final payroll = results[2] as UserPayrollInsights?;

      state = state.copyWith(
        stats: DashboardStats.fromDeliveryApi(dash),
        dayState: DayBlockState.fromJson(dayJson),
        payrollInsights: payroll,
        assignPayrollInsights: true,
        isLoading: false,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }

    await _loadAdvances();
  }

  Future<void> _loadAdvances() async {
    if (!mounted) return;
    final fromD = state.advancesFromDate;
    final toD = state.advancesToDate;
    state = state.copyWith(isLoadingAdvances: true, clearAdvancesError: true);
    try {
      final list = await _client.get<List<DeliverymanAdvance>>(
        ApiConstants.myAdvances,
        queryParameters: {
          'fromDate': _colombiaDayStartUtc(fromD).toIso8601String(),
          'toDate': _colombiaDayEndUtc(toD).toIso8601String(),
        },
        fromJson: (data) {
          final raw = data is List
              ? data
              : (data as Map<String, dynamic>)['advances'] as List? ?? [];
          return raw
              .map(
                  (e) => DeliverymanAdvance.fromJson(e as Map<String, dynamic>))
              .toList();
        },
      );
      if (!mounted) return;
      state = state.copyWith(advances: list, isLoadingAdvances: false);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoadingAdvances: false,
        advancesError: e.toString(),
      );
    }
  }

  Future<void> changeDateRange(DateTime from, DateTime to) async {
    final aFrom = DateTime(from.year, from.month, from.day);
    final aTo = DateTime(to.year, to.month, to.day);
    state = state.copyWith(
      advancesFromDate: aFrom,
      advancesToDate: aTo,
    );
    await load(from: from, to: to);
  }
}

final analyticsNotifierProvider =
    StateNotifierProvider.autoDispose<AnalyticsNotifier, AnalyticsState>((ref) {
  return AnalyticsNotifier(ref.watch(dioClientProvider), ref);
});
