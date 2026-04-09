import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/empty_state_widget.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/widgets/order_card.dart';
import '../../orders/models/order_models.dart';
import 'history_notifier.dart';

final _currencyFormat =
    NumberFormat.currency(locale: 'es_CO', symbol: '\$', decimalDigits: 0);
final _dateDisplayFormat = DateFormat('dd/MM/yyyy');

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(historyNotifierProvider.notifier).load();
    });
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(historyNotifierProvider.notifier).loadMore();
    }
  }

  Future<void> _pickDateRange() async {
    final state = ref.read(historyNotifierProvider);
    final fromParts = state.fromDate.split('-');
    final toParts = state.toDate.split('-');

    final initial = DateTimeRange(
      start: DateTime(int.parse(fromParts[0]), int.parse(fromParts[1]),
          int.parse(fromParts[2])),
      end: DateTime(int.parse(toParts[0]), int.parse(toParts[1]),
          int.parse(toParts[2])),
    );

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: initial,
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: AppColors.primary,
            onPrimary: AppColors.onPrimary,
            surface: AppColors.surface,
          ),
        ),
        child: child!,
      ),
    );

    if (picked != null) {
      final fmt = DateFormat('yyyy-MM-dd');
      ref
          .read(historyNotifierProvider.notifier)
          .changeDateRange(fmt.format(picked.start), fmt.format(picked.end));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(historyNotifierProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: () => ref.read(historyNotifierProvider.notifier).load(),
        color: AppColors.primary,
        backgroundColor: AppColors.card,
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: _DateRangeBar(
                fromDate: state.fromDate,
                toDate: state.toDate,
                onTap: _pickDateRange,
              ),
            ),
            if (state.branchSummaries.isNotEmpty)
              SliverToBoxAdapter(
                child: _BranchSummarySection(summaries: state.branchSummaries),
              ),
            if (state.error != null)
              SliverToBoxAdapter(
                child: ErrorBanner(
                  message: state.error!,
                  onRetry: () =>
                      ref.read(historyNotifierProvider.notifier).load(),
                ),
              ),
            if (state.isLoading && state.orders.isEmpty)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              )
            else if (state.orders.isEmpty && !state.isLoading)
              SliverFillRemaining(
                child: EmptyStateWidget(
                  icon: Icons.history,
                  title: 'Sin pedidos entregados',
                  subtitle: 'No hay entregas en el período seleccionado',
                  onRefresh: () =>
                      ref.read(historyNotifierProvider.notifier).load(),
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.all(AppTheme.spacingMd),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final order = state.orders[index];
                      return Padding(
                        padding:
                            const EdgeInsets.only(bottom: AppTheme.spacingSm),
                        child: OrderCard(order: order),
                      );
                    },
                    childCount: state.orders.length,
                  ),
                ),
              ),
              if (state.isLoadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(AppTheme.spacingMd),
                    child: Center(
                      child: CircularProgressIndicator(
                          color: AppColors.primary),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DateRangeBar extends StatelessWidget {
  final String fromDate;
  final String toDate;
  final VoidCallback onTap;

  const _DateRangeBar({
    required this.fromDate,
    required this.toDate,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    String parseAndFormat(String dateStr) {
      try {
        final parts = dateStr.split('-');
        final d = DateTime(
            int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        return _dateDisplayFormat.format(d);
      } catch (_) {
        return dateStr;
      }
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(AppTheme.spacingMd),
        padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingMd, vertical: AppTheme.spacingSm),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_month_outlined,
                color: AppColors.hint, size: 18),
            const SizedBox(width: 8),
            Text(
              '${parseAndFormat(fromDate)} — ${parseAndFormat(toDate)}',
              style: const TextStyle(
                  color: AppColors.onSurface, fontWeight: FontWeight.w500),
            ),
            const Spacer(),
            const Icon(Icons.arrow_drop_down, color: AppColors.hint),
          ],
        ),
      ),
    );
  }
}

class _BranchSummarySection extends StatelessWidget {
  final List<BranchSummary> summaries;
  const _BranchSummarySection({required this.summaries});

  @override
  Widget build(BuildContext context) {
    final total = summaries.fold(0.0, (s, b) => s + b.totalAmount);
    final totalCount = summaries.fold(0, (s, b) => s + b.deliveredCount);

    return Container(
      margin: const EdgeInsets.fromLTRB(
          AppTheme.spacingMd, 0, AppTheme.spacingMd, AppTheme.spacingMd),
      padding: const EdgeInsets.all(AppTheme.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Resumen',
                  style: TextStyle(
                      color: AppColors.onBackground,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(
                '$totalCount entrega${totalCount != 1 ? 's' : ''}',
                style: const TextStyle(
                    color: AppColors.hint, fontSize: 12),
              ),
              const SizedBox(width: 8),
              Text(
                _currencyFormat.format(total),
                style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          if (summaries.length > 1) ...[
            const SizedBox(height: AppTheme.spacingSm),
            const Divider(height: 1),
            const SizedBox(height: AppTheme.spacingSm),
            ...summaries.map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.store_outlined,
                          size: 13, color: AppColors.hint),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(s.branchName,
                            style: const TextStyle(
                                color: AppColors.onSurface, fontSize: 12)),
                      ),
                      Text('${s.deliveredCount}',
                          style: const TextStyle(
                              color: AppColors.hint, fontSize: 12)),
                      const SizedBox(width: 8),
                      Text(_currencyFormat.format(s.totalAmount),
                          style: const TextStyle(
                              color: AppColors.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }
}
