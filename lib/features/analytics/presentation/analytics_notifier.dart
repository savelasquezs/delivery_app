import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/dio_client.dart';
import '../../../core/api/api_constants.dart';
import '../models/advance_model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Modelos — alineados con DashboardDeliveryApiResponse del backend
// ─────────────────────────────────────────────────────────────────────────────

class DashboardStats {
  /// Total de entregas en el período (suma evolutionDeliveries)
  final int totalDeliveries;
  /// Total de fees/ganancias en el período
  final double totalEarnings;
  /// Tiempo promedio de entrega en minutos
  final double? avgDeliveryMinutes;
  /// Puntos de la evolución de entregas (por bucket de fecha)
  final List<String> evolutionLabels;
  final List<int> evolutionDeliveries;
  final List<double> evolutionFees;

  const DashboardStats({
    required this.totalDeliveries,
    required this.totalEarnings,
    this.avgDeliveryMinutes,
    required this.evolutionLabels,
    required this.evolutionDeliveries,
    required this.evolutionFees,
  });

  /// Construye desde la respuesta real de GET /dashboard/delivery/me
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

    final total = deliveries.fold(0, (a, b) => a + b);
    final totalFee = fees.fold(0.0, (a, b) => a + b);

    return DashboardStats(
      totalDeliveries: (me['deliveredCount'] as num?)?.toInt() ?? total,
      totalEarnings: (me['deliveryFeeTotal'] as num?)?.toDouble() ?? totalFee,
      avgDeliveryMinutes:
          (json['avgDeliveryMinutes'] as num?)?.toDouble() ??
          (me['avgDeliveryMinutes'] as num?)?.toDouble(),
      evolutionLabels: labels,
      evolutionDeliveries: deliveries,
      evolutionFees: fees,
    );
  }

  /// Convierte evolución en lista de DailyDelivery para la tabla por día
  List<DailyDelivery> get dailyBreakdown {
    final result = <DailyDelivery>[];
    for (var i = 0; i < evolutionLabels.length; i++) {
      result.add(DailyDelivery(
        date: evolutionLabels[i],
        count: i < evolutionDeliveries.length ? evolutionDeliveries[i] : 0,
        amount: i < evolutionFees.length ? evolutionFees[i] : 0,
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
  final List<DeliverymanAdvance> advances;
  final bool isLoading;
  final bool isLoadingAdvances;
  final String? error;
  final String? advancesError;
  /// Fechas del rango activo (para mostrar en UI)
  final DateTime fromDate;
  final DateTime toDate;

  const AnalyticsState({
    this.stats,
    this.dayState,
    this.advances = const [],
    this.isLoading = false,
    this.isLoadingAdvances = false,
    this.error,
    this.advancesError,
    required this.fromDate,
    required this.toDate,
  });

  AnalyticsState copyWith({
    DashboardStats? stats,
    DayBlockState? dayState,
    List<DeliverymanAdvance>? advances,
    bool? isLoading,
    bool? isLoadingAdvances,
    String? error,
    String? advancesError,
    DateTime? fromDate,
    DateTime? toDate,
    bool clearError = false,
    bool clearAdvancesError = false,
  }) =>
      AnalyticsState(
        stats: stats ?? this.stats,
        dayState: dayState ?? this.dayState,
        advances: advances ?? this.advances,
        isLoading: isLoading ?? this.isLoading,
        isLoadingAdvances: isLoadingAdvances ?? this.isLoadingAdvances,
        error: clearError ? null : (error ?? this.error),
        advancesError: clearAdvancesError
            ? null
            : (advancesError ?? this.advancesError),
        fromDate: fromDate ?? this.fromDate,
        toDate: toDate ?? this.toDate,
      );

  static AnalyticsState initial() {
    final now = DateTime.now();
    return AnalyticsState(
      fromDate: DateTime(now.year, now.month, 1),
      toDate: now,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Notifier
// ─────────────────────────────────────────────────────────────────────────────

class AnalyticsNotifier extends StateNotifier<AnalyticsState> {
  final DioClient _client;

  AnalyticsNotifier(this._client) : super(AnalyticsState.initial());

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> load({DateTime? from, DateTime? to}) async {
    if (!mounted) return;
    final fromD = from ?? state.fromDate;
    final toD = to ?? state.toDate;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      fromDate: fromD,
      toDate: toD,
    );
    try {
      final fromStr = '${_fmt(fromD)}T00:00:00Z';
      final toStr = '${_fmt(toD)}T23:59:59Z';

      final results = await Future.wait([
        _client.get<Map<String, dynamic>>(
          ApiConstants.dashboardDeliveryMe,
          queryParameters: {'from': fromStr, 'to': toStr},
          fromJson: (d) => d as Map<String, dynamic>,
        ),
        _client.get<Map<String, dynamic>>(
          ApiConstants.myDayState,
          fromJson: (d) => d as Map<String, dynamic>,
        ),
      ]);

      if (!mounted) return;
      state = state.copyWith(
        stats: DashboardStats.fromDeliveryApi(results[0]),
        dayState: DayBlockState.fromJson(results[1]),
        isLoading: false,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }

    // Carga advances en paralelo
    await _loadAdvances(from: fromD, to: toD);
  }

  Future<void> _loadAdvances({DateTime? from, DateTime? to}) async {
    if (!mounted) return;
    final fromD = from ?? state.fromDate;
    final toD = to ?? state.toDate;
    state = state.copyWith(isLoadingAdvances: true, clearAdvancesError: true);
    try {
      final list = await _client.get<List<DeliverymanAdvance>>(
        ApiConstants.myAdvances,
        queryParameters: {
          'fromDate': '${_fmt(fromD)}T00:00:00Z',
          'toDate': '${_fmt(toD)}T23:59:59Z',
        },
        fromJson: (data) {
          final raw = data is List
              ? data
              : (data as Map<String, dynamic>)['advances'] as List? ?? [];
          return raw
              .map((e) =>
                  DeliverymanAdvance.fromJson(e as Map<String, dynamic>))
              .toList();
        },
      );
      if (!mounted) return;
      state = state.copyWith(advances: list, isLoadingAdvances: false);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
          isLoadingAdvances: false, advancesError: e.toString());
    }
  }

  Future<void> changeDateRange(DateTime from, DateTime to) async {
    await load(from: from, to: to);
  }
}

final analyticsNotifierProvider =
    StateNotifierProvider.autoDispose<AnalyticsNotifier, AnalyticsState>((ref) {
  return AnalyticsNotifier(ref.watch(dioClientProvider));
});
