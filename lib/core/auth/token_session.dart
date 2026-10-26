import 'dart:convert';

class TokenSession {
  final String id;
  final String accessToken;
  final String refreshToken;
  final int refreshFailures;
  final int retryRefreshAt;

  const TokenSession({
    required this.id,
    required this.accessToken,
    required this.refreshToken,
    this.refreshFailures = 0,
    this.retryRefreshAt = 0,
  });

  factory TokenSession.fromJson(Map<String, dynamic> json) => TokenSession(
        id: json['id'] as String,
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        refreshFailures: (json['refreshFailures'] as num?)?.toInt() ?? 0,
        retryRefreshAt: (json['retryRefreshAt'] as num?)?.toInt() ?? 0,
      );

  String ownerKey(String baseUrl) {
    final parts = accessToken.split('.');
    final claims =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map;
    final tenant = claims['tenant_id'];
    final user = claims['nameid'] ?? claims[
            'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier'] ??
        claims['sub'];
    if (tenant == null || user == null)
      throw StateError('No se pudo verificar el propietario local.');
    return jsonEncode([baseUrl, tenant.toString(), user.toString()]);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'refreshFailures': refreshFailures,
        'retryRefreshAt': retryRefreshAt,
      };
}
