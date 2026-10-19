import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api/dio_client.dart';
import '../auth/presentation/auth_notifier.dart';

class EmployeeLunchState {
  final int? lunchId;
  final DateTime? startedAt;
  final Duration clockOffset;
  const EmployeeLunchState(this.lunchId, this.startedAt, this.clockOffset);
  bool get active => lunchId != null;
  factory EmployeeLunchState.fromJson(Map<String, dynamic> json) {
    final lunch = json['activeLunch'] as Map?;
    return EmployeeLunchState(
        lunch?['id'] as int?,
        lunch == null ? null : DateTime.parse(lunch['startedAt'] as String),
        DateTime.parse(json['serverTimeUtc'] as String)
            .difference(DateTime.now().toUtc()));
  }
}

class EmployeeLunchNotifier
    extends StateNotifier<AsyncValue<EmployeeLunchState>> {
  final DioClient client;
  Future<void>? _refreshing;
  bool busy = false;
  EmployeeLunchNotifier(this.client) : super(const AsyncValue.loading()) {
    unawaited(refresh());
  }
  Future<void> refresh() {
    final existing = _refreshing;
    if (existing != null) return existing;
    final operation = _load();
    _refreshing = operation;
    return operation.whenComplete(() {
      if (identical(_refreshing, operation)) _refreshing = null;
    });
  }

  Future<void> _load() async {
    try {
      final value = await client.get<EmployeeLunchState>('/employee-lunch/me',
          fromJson: (data) => EmployeeLunchState.fromJson(
              Map<String, dynamic>.from(data as Map)));
      if (mounted) state = AsyncValue.data(value);
    } catch (error, stack) {
      if (mounted) {
        state = AsyncValue<EmployeeLunchState>.error(error, stack)
            .copyWithPrevious(state);
      }
    }
  }

  Future<void> change(String password) async {
    if (busy || state.hasError || !state.hasValue) return;
    busy = true;
    final lunch = state.requireValue;
    try {
      await client.post<dynamic>(
          '/employee-lunch/${lunch.active ? 'finish' : 'start'}',
          data: {'password': password, 'lunchId': lunch.lunchId});
    } finally {
      await refresh();
      busy = false;
    }
  }
}

final employeeLunchProvider = StateNotifierProvider.autoDispose<
    EmployeeLunchNotifier, AsyncValue<EmployeeLunchState>>((ref) {
  ref.watch(
      authNotifierProvider.select((auth) => (auth.status, auth.user?.id)));
  return EmployeeLunchNotifier(ref.watch(dioClientProvider));
});
