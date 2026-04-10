class LoginRequest {
  final String email;
  final String password;

  const LoginRequest({required this.email, required this.password});

  Map<String, dynamic> toJson() => {'email': email, 'password': password};
}

class AuthUser {
  final int id;
  final String name;
  final String email;
  final String role;
  final int? branchId;
  final String? branchName;
  final String? phone;
  final String? profileImageUrl;

  const AuthUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.branchId,
    this.branchName,
    this.phone,
    this.profileImageUrl,
  });

  bool get isDeliveryman => role.toLowerCase() == 'deliveryman';

  static int _idFromJson(dynamic v) =>
      v is int ? v : (v as num).toInt();

  static String _roleFromJson(Map<String, dynamic> json) {
    final r = json['role'];
    if (r is String) return r;
    final name = json['roleName'];
    if (name is String) return name;
    return '';
  }

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: _idFromJson(json['id']),
        name: json['name'] as String? ?? '',
        email: json['email'] as String? ?? '',
        role: _roleFromJson(json),
        branchId: json['branchId'] != null
            ? _idFromJson(json['branchId'])
            : null,
        branchName: json['branchName'] as String?,
        phone: _emptyToNull(json['phone'] as String?),
        profileImageUrl: _emptyToNull(json['profileImageUrl'] as String?),
      );

  static String? _emptyToNull(String? s) {
    if (s == null || s.isEmpty) return null;
    return s;
  }

  /// Respuesta de `GET/PUT /users/...` (`UserDto`).
  factory AuthUser.fromUserApi(Map<String, dynamic> json, AuthUser current) =>
      AuthUser(
        id: current.id,
        name: json['name'] as String? ?? current.name,
        email: json['email'] as String? ?? current.email,
        role: current.role,
        branchId: json['branchId'] != null
            ? _idFromJson(json['branchId'])
            : current.branchId,
        branchName: json['branchName'] as String? ?? current.branchName,
        phone: _emptyToNull(json['phone'] as String?) ?? current.phone,
        profileImageUrl:
            _emptyToNull(json['profileImageUrl'] as String?) ??
                current.profileImageUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'role': role,
        'branchId': branchId,
        'branchName': branchName,
        'phone': phone ?? '',
        'profileImageUrl': profileImageUrl,
      };

  AuthUser copyWith({
    int? id,
    String? name,
    String? email,
    String? role,
    int? branchId,
    String? branchName,
    String? phone,
    String? profileImageUrl,
  }) =>
      AuthUser(
        id: id ?? this.id,
        name: name ?? this.name,
        email: email ?? this.email,
        role: role ?? this.role,
        branchId: branchId ?? this.branchId,
        branchName: branchName ?? this.branchName,
        phone: phone ?? this.phone,
        profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      );
}

class LoginResponse {
  final String token;
  final String refreshToken;
  final AuthUser user;

  const LoginResponse({
    required this.token,
    required this.refreshToken,
    required this.user,
  });

  factory LoginResponse.fromJson(Map<String, dynamic> json) => LoginResponse(
        token: json['token'] as String,
        refreshToken: json['refreshToken'] as String,
        user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
      );
}
