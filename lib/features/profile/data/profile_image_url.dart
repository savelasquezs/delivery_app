import '../../../core/api/api_constants.dart';

/// URL absoluta para [profileImageUrl] del API (relativa o absoluta).
String? resolveProfileImageUrl(String? path) {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('http://') || path.startsWith('https://')) {
    return path;
  }
  final origin = ApiConstants.originUrl;
  final p = path.startsWith('/') ? path : '/$path';
  return '$origin$p';
}
