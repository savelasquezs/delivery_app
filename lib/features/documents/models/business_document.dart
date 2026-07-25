class BusinessDocument {
  final int id;
  final String publicId;
  final String name;
  final String downloadUrl;
  final String publicDownloadUrl;
  final String originalFileName;
  final String contentType;
  final int fileSizeBytes;
  final DateTime createdAt;
  final DateTime updatedAt;

  const BusinessDocument({
    required this.id,
    required this.publicId,
    required this.name,
    required this.downloadUrl,
    required this.publicDownloadUrl,
    required this.originalFileName,
    required this.contentType,
    required this.fileSizeBytes,
    required this.createdAt,
    required this.updatedAt,
  });

  factory BusinessDocument.fromJson(Map<String, dynamic> json) =>
      BusinessDocument(
        id: (json['id'] as num).toInt(),
        publicId: json['publicId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        downloadUrl: json['downloadUrl'] as String? ?? '',
        publicDownloadUrl: json['publicDownloadUrl'] as String? ?? '',
        originalFileName: json['originalFileName'] as String? ?? '',
        contentType: json['contentType'] as String? ?? 'application/pdf',
        fileSizeBytes: (json['fileSizeBytes'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
        updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      );
}

class BusinessDocumentPage {
  final List<BusinessDocument> items;
  final int totalCount;
  final int page;
  final int pageSize;
  final int totalPages;

  const BusinessDocumentPage({
    required this.items,
    required this.totalCount,
    required this.page,
    required this.pageSize,
    required this.totalPages,
  });

  bool get hasNextPage => page < totalPages;

  factory BusinessDocumentPage.fromApi(Map<String, dynamic> json) {
    final envelopeData = json['data'];
    final data = envelopeData is Map<String, dynamic>
        ? envelopeData
        : Map<String, dynamic>.from(envelopeData as Map);
    final rawItems = data['items'] as List<dynamic>? ?? const [];
    return BusinessDocumentPage(
      items: rawItems
          .map((item) => BusinessDocument.fromJson(
                Map<String, dynamic>.from(item as Map),
              ))
          .toList(),
      totalCount: (data['totalCount'] as num?)?.toInt() ?? rawItems.length,
      page: (data['page'] as num?)?.toInt() ?? 1,
      pageSize: (data['pageSize'] as num?)?.toInt() ?? 20,
      totalPages: (data['totalPages'] as num?)?.toInt() ?? 1,
    );
  }
}
