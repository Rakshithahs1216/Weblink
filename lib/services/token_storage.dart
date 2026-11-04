import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the JWT and the server URL.
///
/// Abstracted so services can be unit-tested with an in-memory fake.
abstract interface class TokenStorage {
  Future<String?> readToken();
  Future<void> writeToken(String token);
  Future<void> deleteToken();

  Future<String?> readServerUrl();
  Future<void> writeServerUrl(String url);
}

/// [TokenStorage] backed by the platform keystore (Android Keystore,
/// iOS/macOS Keychain, libsecret on Linux, DPAPI on Windows, WebCrypto-encrypted
/// localStorage on web).
///
/// The server URL is not secret, but keeping it here avoids pulling in a second
/// persistence package.
class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _tokenKey = 'weblink.jwt';
  static const _serverUrlKey = 'weblink.server_url';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readToken() => _safeRead(_tokenKey);

  @override
  Future<void> writeToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  @override
  Future<void> deleteToken() => _storage.delete(key: _tokenKey);

  @override
  Future<String?> readServerUrl() => _safeRead(_serverUrlKey);

  @override
  Future<void> writeServerUrl(String url) =>
      _storage.write(key: _serverUrlKey, value: url);

  /// A corrupted keystore entry (e.g. after an OS restore) must not brick the
  /// app – treat it as "nothing stored" so the user can simply log in again.
  Future<String?> _safeRead(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      await _storage.delete(key: key).catchError((_) {});
      return null;
    }
  }
}
