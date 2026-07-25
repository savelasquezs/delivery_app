import 'package:delivery_app/features/documents/models/business_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parsea el sobre paginado de documentos del API', () {
    final page = BusinessDocumentPage.fromApi({
      'isSuccess': true,
      'data': {
        'items': [
          {
            'id': 4,
            'publicId': 'b3c4c2de-bfef-4d37-a13a-351e38dbd749',
            'name': 'Reglamento interno',
            'downloadUrl': 'https://firebase.test/file.pdf?token=abc',
            'publicDownloadUrl':
                '/api/public/business-documents/b3c4c2de-bfef-4d37-a13a-351e38dbd749/download',
            'originalFileName': 'reglamento.pdf',
            'contentType': 'application/pdf',
            'fileSizeBytes': 2048,
            'createdAt': '2026-07-25T12:00:00Z',
            'updatedAt': '2026-07-25T13:00:00Z',
          }
        ],
        'totalCount': 21,
        'page': 1,
        'pageSize': 20,
        'totalPages': 2,
      }
    });

    expect(page.items, hasLength(1));
    expect(page.items.single.name, 'Reglamento interno');
    expect(page.items.single.fileSizeBytes, 2048);
    expect(page.totalCount, 21);
    expect(page.hasNextPage, isTrue);
  });
}
