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

  Map<String, dynamic> toJson() => {
        'id': id,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'refreshFailures': refreshFailures,
        'retryRefreshAt': retryRefreshAt,
      };
}
