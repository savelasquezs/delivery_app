import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/business_document_repository.dart';
import '../models/business_document.dart';

class BusinessDocumentsState {
  final List<BusinessDocument> documents;
  final int totalCount;
  final int currentPage;
  final bool hasMore;
  final bool isLoading;
  final bool isLoadingMore;
  final String search;
  final String? error;

  const BusinessDocumentsState({
    this.documents = const [],
    this.totalCount = 0,
    this.currentPage = 1,
    this.hasMore = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.search = '',
    this.error,
  });

  BusinessDocumentsState copyWith({
    List<BusinessDocument>? documents,
    int? totalCount,
    int? currentPage,
    bool? hasMore,
    bool? isLoading,
    bool? isLoadingMore,
    String? search,
    String? error,
    bool clearError = false,
  }) =>
      BusinessDocumentsState(
        documents: documents ?? this.documents,
        totalCount: totalCount ?? this.totalCount,
        currentPage: currentPage ?? this.currentPage,
        hasMore: hasMore ?? this.hasMore,
        isLoading: isLoading ?? this.isLoading,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        search: search ?? this.search,
        error: clearError ? null : (error ?? this.error),
      );
}

class BusinessDocumentsNotifier extends StateNotifier<BusinessDocumentsState> {
  final BusinessDocumentRepository _repository;

  BusinessDocumentsNotifier(this._repository)
      : super(const BusinessDocumentsState());

  Future<void> load({String? search}) async {
    if (!mounted) return;
    final normalizedSearch = search?.trim() ?? state.search;
    state = state.copyWith(
      documents: const [],
      totalCount: 0,
      currentPage: 1,
      hasMore: false,
      isLoading: true,
      search: normalizedSearch,
      clearError: true,
    );
    try {
      final result = await _repository.getDocuments(search: normalizedSearch);
      if (!mounted) return;
      state = state.copyWith(
        documents: result.items,
        totalCount: result.totalCount,
        currentPage: result.page,
        hasMore: result.hasNextPage,
        isLoading: false,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        error: _message(error),
      );
    }
  }

  Future<void> loadMore() async {
    if (!mounted || !state.hasMore || state.isLoadingMore) return;
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      final result = await _repository.getDocuments(
        search: state.search,
        page: state.currentPage + 1,
      );
      if (!mounted) return;
      state = state.copyWith(
        documents: [...state.documents, ...result.items],
        totalCount: result.totalCount,
        currentPage: result.page,
        hasMore: result.hasNextPage,
        isLoadingMore: false,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        isLoadingMore: false,
        error: _message(error),
      );
    }
  }

  static String _message(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}

final businessDocumentsNotifierProvider = StateNotifierProvider.autoDispose<
    BusinessDocumentsNotifier, BusinessDocumentsState>((ref) {
  return BusinessDocumentsNotifier(
    ref.watch(businessDocumentRepositoryProvider),
  );
});
