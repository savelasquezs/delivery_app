import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/dio_client.dart';
import '../../../core/api/api_constants.dart';

class DashboardStats {
  final int deliveredToday;
  final double earningsToday;
  final int totalDeliveries;
  final double totalEarnings;
  final List<DailyDelivery> dailyBreakdown;

  const DashboardStats({
    required this.deliveredToday,
    required this.earningsToday,
    required this.totalDeliveries,
    required this.totalEarnings,
    required this.dailyBreakdown,
  });

  factory DashboardStats.fromJson(Map<String, dynamic> json) {
    final breakdown = (json['dailyBreakdown'] as List<dynamic>? ?? [])
        .map((e) => DailyDelivery.fromJson(e as Map<String, dynamic>))
        .toList();
    return DashboardStats(
      deliveredToday: json['deliveredToday'] as int? ?? 0,
      earningsToday: (json['earningsToday'] as num?)?.toDouble() ?? 0,
      totalDeliveries: json['totalDeliveries'] as int? ?? 0,
      totalEarnings: (json['totalEarnings'] as num?)?.toDouble() ?? 0,
      dailyBreakdown: breakdown,
    );
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

  factory DailyDelivery.fromJson(Map<String, dynamic> json) => DailyDelivery(
        date: json['date'] as String? ?? '',
        count: json['count'] as int? ?? 0,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
      );
}

class DayBlockState {
  final bool isBlocked;
  final String? blockedReason;

  const DayBlockState({this.isBlocked = false, this.blockedReason});

  factory DayBlockState.fromJson(Map<String, dynamic> json) => DayBlockState(
        isBlocked: json['isBlocked'] as bool? ?? json['blocked'] as bool? ?? false,
        blockedReason: json['reason'] as String?,
      );
}

class AnalyticsState {
  final DashboardStats? stats;
  final DayBlockState? dayState;
  final bool isLoading;
  final String? error;

  const AnalyticsState({
    this.stats,
    this.dayState,
    this.isLoading = false,
    this.error,
  });

  AnalyticsState copyWith({
    DashboardStats? stats,
    DayBlockState? dayState,
    bool? isLoading,
    String? error,
  }) => AnalyticsState(
        stats: stats ?? this.stats,
        dayState: dayState ?? this.dayState,
        isLoading: isLoading ?? this.isLoading,
        error: error,
      );
}

class AnalyticsNotifier extends StateNotifier<AnalyticsState> {
  final DioClient _client;

  AnalyticsNotifier(this._client) : super(const AnalyticsState());

  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final now = DateTime.now();
      final from =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-01T00:00:00Z';
      final to =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}T23:59:59Z';

      final results = await Future.wait([
        _client.get<Map<String, dynamic>>(
          ApiConstants.dashboardDeliveryMe,
          queryParameters: {'from': from, 'to': to},
          fromJson: (d) => d as Map<String, dynamic>,
        ),
        _client.get<Map<String, dynamic>>(
          ApiConstants.myDayState,
          fromJson: (d) => d as Map<String, dynamic>,
        ),
      ]);

      state = state.copyWith(
        stats: DashboardStats.fromJson(results[0]),
        dayState: DayBlockState.fromJson(results[1]),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }
}

final analyticsNotifierProvider =
    StateNotifierProvider.autoDispose<AnalyticsNotifier, AnalyticsState>((ref) {
  return AnalyticsNotifier(ref.watch(dioClientProvider));
});
