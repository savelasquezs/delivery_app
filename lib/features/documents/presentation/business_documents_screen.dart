import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/api/api_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/empty_state_widget.dart';
import '../../../core/widgets/error_banner.dart';
import '../models/business_document.dart';
import 'business_documents_notifier.dart';

class BusinessDocumentsScreen extends ConsumerStatefulWidget {
  const BusinessDocumentsScreen({super.key});

  @override
  ConsumerState<BusinessDocumentsScreen> createState() =>
      _BusinessDocumentsScreenState();
}

class _BusinessDocumentsScreenState
    extends ConsumerState<BusinessDocumentsScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(businessDocumentsNotifierProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openDocument(BusinessDocument document) async {
    final uri = _resolveUrl(document.publicDownloadUrl);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted || opened) return;
    ErrorBanner.show(context, 'No se pudo abrir el documento.');
  }

  static Uri _resolveUrl(String pathOrUrl) {
    final uri = Uri.parse(pathOrUrl);
    if (uri.hasScheme) return uri;
    return Uri.parse(ApiConstants.baseUrl).resolve(pathOrUrl);
  }

  void _search() {
    ref
        .read(businessDocumentsNotifierProvider.notifier)
        .load(search: _searchController.text);
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(businessDocumentsNotifierProvider.notifier).load(search: '');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(businessDocumentsNotifierProvider);
    final notifier = ref.read(businessDocumentsNotifierProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Documentos'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingMd,
              AppTheme.spacingMd,
              AppTheme.spacingMd,
              AppTheme.spacingSm,
            ),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Buscar documento...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: state.search.isNotEmpty
                    ? IconButton(
                        tooltip: 'Limpiar búsqueda',
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.close),
                      )
                    : IconButton(
                        tooltip: 'Buscar',
                        onPressed: _search,
                        icon: const Icon(Icons.arrow_forward),
                      ),
              ),
            ),
          ),
          if (state.error != null)
            ErrorBanner(message: state.error!, onRetry: () => notifier.load()),
          Expanded(
            child: state.isLoading
                ? const Center(child: CircularProgressIndicator())
                : state.documents.isEmpty
                    ? EmptyStateWidget(
                        icon: Icons.description_outlined,
                        title: 'No hay documentos',
                        subtitle: state.search.isEmpty
                            ? 'Aún no se han publicado documentos corporativos.'
                            : 'No hay resultados para esta búsqueda.',
                        onRefresh: () => notifier.load(),
                      )
                    : RefreshIndicator(
                        onRefresh: () => notifier.load(),
                        child: ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(AppTheme.spacingMd),
                          itemCount:
                              state.documents.length + (state.hasMore ? 1 : 0),
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: AppTheme.spacingSm),
                          itemBuilder: (context, index) {
                            if (index == state.documents.length) {
                              return Padding(
                                padding:
                                    const EdgeInsets.all(AppTheme.spacingMd),
                                child: OutlinedButton(
                                  onPressed: state.isLoadingMore
                                      ? null
                                      : notifier.loadMore,
                                  child: state.isLoadingMore
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Text(
                                          'Cargar más (${state.documents.length} de ${state.totalCount})',
                                        ),
                                ),
                              );
                            }
                            final document = state.documents[index];
                            return _DocumentCard(
                              document: document,
                              onOpen: () => _openDocument(document),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _DocumentCard extends StatelessWidget {
  final BusinessDocument document;
  final VoidCallback onOpen;

  const _DocumentCard({required this.document, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final localUpdatedAt = document.updatedAt.toLocal();
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(AppTheme.spacingSm),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: const Icon(
                  Icons.picture_as_pdf_outlined,
                  color: AppColors.error,
                  size: 28,
                ),
              ),
              const SizedBox(width: AppTheme.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppTheme.spacingXs),
                    Text(
                      document.originalFileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppTheme.spacingXs),
                    Text(
                      '${_formatBytes(document.fileSizeBytes)} · ${DateFormat.yMMMd('es_CO').add_Hm().format(localUpdatedAt)}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.hint),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.spacingSm),
              const Icon(Icons.open_in_new, color: AppColors.primaryLight),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
