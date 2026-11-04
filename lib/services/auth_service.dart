import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/auth_user.dart';
import 'api_client.dart';
import 'jwt.dart';
import 'token_storage.dart';

enum AuthStatus { unknown, unauthenticated, authenticated }

/// Credentials needed to open the JWT-gated WebSockets.
typedef SessionCredentials = ({String serverUrl, String token});

/// Owns the JWT lifecycle: login, startup validation, expiry and logout.
///
/// Other services register teardown work through [addLogoutHandler] so a
/// logout – manual, on HTTP 401, on WebSocket close code 4401, or on token
/// expiry – always closes the peer connection and sockets before the token is
/// discarded.
class AuthService extends ChangeNotifier {
  AuthService({
    required this._storage,
    required this._api,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const String sessionExpiredMessage =
      'Your session has expired. Please log in again.';

  final TokenStorage _storage;
  final ApiClient _api;
  final DateTime Function() _clock;
  final List<FutureOr<void> Function()> _logoutHandlers = [];

  AuthStatus _status = AuthStatus.unknown;
  AuthUser? _user;
  String? _token;
  String _serverUrl = AppConfig.defaultServerUrl;
  String? _sessionMessage;
  Timer? _expiryTimer;
  bool _loggingOut = false;

  AuthStatus get status => _status;
  bool get isAuthenticated => _status == AuthStatus.authenticated;
  AuthUser? get user => _user;
  String get serverUrl => _serverUrl;

  /// Why the user was sent back to the login screen (expired session, …).
  String? get sessionMessage => _sessionMessage;

  SessionCredentials? get credentials {
    final token = _token;
    if (!isAuthenticated || token == null) return null;
    return (serverUrl: _serverUrl, token: token);
  }

  void addLogoutHandler(FutureOr<void> Function() handler) =>
      _logoutHandlers.add(handler);

  /// Restores the persisted server URL and validates any stored token with
  /// `GET /api/auth/me`. Ends in [AuthStatus.authenticated] or
  /// [AuthStatus.unauthenticated].
  Future<void> bootstrap() async {
    _serverUrl = await _storage.readServerUrl() ?? AppConfig.defaultServerUrl;
    final stored = await _storage.readToken();
    if (stored == null) {
      _setUnauthenticated();
      return;
    }
    if (_isExpired(stored)) {
      await _storage.deleteToken();
      _setUnauthenticated(message: sessionExpiredMessage);
      return;
    }
    try {
      final me = await _api.getJson(
        _serverUrl,
        '/api/auth/me',
        bearerToken: stored,
      );
      _setAuthenticated(stored, AuthUser.fromJson(me));
    } on UnauthorizedException {
      await _storage.deleteToken();
      _setUnauthenticated(message: sessionExpiredMessage);
    } on ApiException catch (e) {
      // Server unreachable: the token may still be fine, so keep it, but we
      // cannot enter the app without a verified session.
      _setUnauthenticated(
        message: 'Could not verify your saved session. ${e.message}',
      );
    } on FormatException {
      await _storage.deleteToken();
      _setUnauthenticated();
    }
  }

  /// Logs in with a username or email. Throws [ApiException] on failure
  /// (including [UnauthorizedException] for bad credentials).
  Future<void> login({
    required String username,
    required String password,
    required String serverUrl,
  }) async {
    final base = AppConfig.normalizeServerUrl(serverUrl);
    _serverUrl = base;
    await _storage.writeServerUrl(base);

    final json = await _api.postJson(base, '/api/auth/login', {
      'username': username.trim(),
      'password': password,
    });

    final token = json['access_token'];
    final userJson = json['user'];
    if (token is! String ||
        token.isEmpty ||
        userJson is! Map<String, dynamic>) {
      throw const ApiException('Unexpected login response from server.');
    }
    final AuthUser user;
    try {
      user = AuthUser.fromJson(userJson);
    } on FormatException {
      throw const ApiException('Unexpected login response from server.');
    }
    await _storage.writeToken(token);

    final expiresIn = json['expires_in'];
    _setAuthenticated(
      token,
      user,
      fallbackExpiry: expiresIn is num
          ? _clock().add(Duration(seconds: expiresIn.toInt()))
          : null,
    );
  }

  /// Re-checks the token with the server. Used when a WebSocket handshake
  /// fails (browsers report a pre-accept close as a generic failure, hiding
  /// close code 4401). Returns false – and logs out – only on HTTP 401.
  Future<bool> verifySession() async {
    final token = _token;
    if (token == null) return false;
    try {
      await _api.getJson(_serverUrl, '/api/auth/me', bearerToken: token);
      return true;
    } on UnauthorizedException {
      await handleUnauthorized();
      return false;
    } on ApiException {
      return true; // network problem – not an auth problem
    }
  }

  /// Called for any HTTP 401 or WebSocket close code 4401.
  Future<void> handleUnauthorized([String message = sessionExpiredMessage]) =>
      logout(message: message);

  /// Tears down every registered session, deletes the token and flips to
  /// [AuthStatus.unauthenticated]. Safe to call repeatedly.
  Future<void> logout({String? message}) async {
    if (_loggingOut || _status != AuthStatus.authenticated) return;
    _loggingOut = true;
    try {
      for (final handler in _logoutHandlers) {
        try {
          await Future.sync(handler).timeout(const Duration(seconds: 3));
        } catch (e) {
          debugPrint('Logout handler failed: $e');
        }
      }
      await _storage.deleteToken();
    } finally {
      _loggingOut = false;
      _setUnauthenticated(message: message);
    }
  }

  void clearSessionMessage() {
    if (_sessionMessage == null) return;
    _sessionMessage = null;
    notifyListeners();
  }

  bool _isExpired(String token) {
    final exp = jwtExpiry(token);
    return exp != null && !exp.isAfter(_clock().toUtc());
  }

  void _setAuthenticated(
    String token,
    AuthUser user, {
    DateTime? fallbackExpiry,
  }) {
    _token = token;
    _user = user;
    _status = AuthStatus.authenticated;
    _sessionMessage = null;
    _scheduleExpiry(jwtExpiry(token) ?? fallbackExpiry);
    notifyListeners();
  }

  void _setUnauthenticated({String? message}) {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _token = null;
    _user = null;
    _status = AuthStatus.unauthenticated;
    _sessionMessage = message;
    notifyListeners();
  }

  void _scheduleExpiry(DateTime? expiry) {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (expiry == null) return;
    final remaining = expiry.difference(_clock());
    _expiryTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      handleUnauthorized,
    );
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }
}
