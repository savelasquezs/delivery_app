import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/business_document_repository.dart';
import '../models/business_document.dart';
import '../../../core/errors/user_facing_error.dart';

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
  int _generation = 0;
  final BusinessDocumentRepository _repository;

  BusinessDocumentsNotifier(this._repository)
      : super(const BusinessDocumentsState());

  Future<void> load({String? search}) async {
    if (!mounted) return;
    final generation = ++_generation;
    final normalizedSearch = search?.trim() ?? state.search;
    state = state.copyWith(
      currentPage: 1,
      isLoadingMore: false,
      isLoading: true,
      search: normalizedSearch,
      clearError: true,
    );
    try {
      final result = await _repository.getDocuments(search: normalizedSearch);
      if (!mounted || generation != _generation) return;
      state = state.copyWith(
        documents: result.items,
        totalCount: result.totalCount,
        currentPage: result.page,
        hasMore: result.hasNextPage,
        isLoading: false,
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      state = state.copyWith(
        isLoading: false,
        error: userFacingErrorMessage(
          error,
          fallback: 'No pudimos cargar los documentos.',
        ),
      );
    }
  }

  Future<void> loadMore() async {
    if (!mounted || !state.hasMore || state.isLoadingMore) return;
    final generation = _generation;
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      final result = await _repository.getDocuments(
        search: state.search,
        page: state.currentPage + 1,
      );
      if (!mounted || generation != _generation) return;
      state = state.copyWith(
        documents: [...state.documents, ...result.items],
        totalCount: result.totalCount,
        currentPage: result.page,
        hasMore: result.hasNextPage,
        isLoadingMore: false,
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      state = state.copyWith(
        isLoadingMore: false,
        error: userFacingErrorMessage(
          error,
          fallback: 'No pudimos cargar más documentos.',
        ),
      );
    }
  }
}

final businessDocumentsNotifierProvider = StateNotifierProvider.autoDispose<
    BusinessDocumentsNotifier, BusinessDocumentsState>((ref) {
  return BusinessDocumentsNotifier(
    ref.watch(businessDocumentRepositoryProvider),
  );
});
