import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_constants.dart';
import '../../../core/api/dio_client.dart';
import '../models/business_document.dart';

class BusinessDocumentRepository {
  final DioClient _client;

  const BusinessDocumentRepository(this._client);

  Future<BusinessDocumentPage> getDocuments({
    String? search,
    int page = 1,
    int pageSize = 20,
  }) {
    return _client.get<BusinessDocumentPage>(
      ApiConstants.businessDocuments,
      queryParameters: {
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
        'page': page,
        'pageSize': pageSize,
        'sortBy': 'name',
        'sortOrder': 'asc',
      },
      fromJson: (data) => BusinessDocumentPage.fromApi(
        Map<String, dynamic>.from(data as Map),
      ),
    );
  }
}

final businessDocumentRepositoryProvider =
    Provider<BusinessDocumentRepository>((ref) {
  return BusinessDocumentRepository(ref.watch(dioClientProvider));
});
