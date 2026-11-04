/// The signed-in user as returned by `/api/auth/login` and `/api/auth/me`.
class AuthUser {
  const AuthUser({required this.username, required this.displayName});

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    final username = json['username'];
    if (username is! String || username.isEmpty) {
      throw const FormatException('User payload is missing "username"');
    }
    final displayName = json['display_name'];
    return AuthUser(
      username: username,
      displayName: displayName is String && displayName.isNotEmpty
          ? displayName
          : username,
    );
  }

  final String username;
  final String displayName;
}
