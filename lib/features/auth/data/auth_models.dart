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

  const AuthUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.branchId,
    this.branchName,
  });

  bool get isDeliveryman => role.toLowerCase() == 'deliveryman';

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: json['id'] as int,
        name: json['name'] as String? ?? '',
        email: json['email'] as String? ?? '',
        role: json['role'] as String? ?? '',
        branchId: json['branchId'] as int?,
        branchName: json['branchName'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'role': role,
        'branchId': branchId,
        'branchName': branchName,
      };

  AuthUser copyWith({
    int? id,
    String? name,
    String? email,
    String? role,
    int? branchId,
    String? branchName,
  }) => AuthUser(
        id: id ?? this.id,
        name: name ?? this.name,
        email: email ?? this.email,
        role: role ?? this.role,
        branchId: branchId ?? this.branchId,
        branchName: branchName ?? this.branchName,
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
