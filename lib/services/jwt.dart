import 'dart:convert';

/// Reads the `exp` claim of a JWT **without verifying it** (the server is the
/// authority). Used only to avoid sending an obviously expired token and to log
/// the user out as soon as the token lapses. Returns null if unreadable.
DateTime? jwtExpiry(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final claims = jsonDecode(payload);
    if (claims is! Map<String, dynamic>) return null;
    final exp = claims['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (exp * 1000).round(),
      isUtc: true,
    );
  } on FormatException {
    return null;
  }
}
