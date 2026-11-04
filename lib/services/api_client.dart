import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Any failure talking to the REST API, with a user-presentable [message].
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// HTTP 401 – bad credentials on login, or a missing/expired token elsewhere.
class UnauthorizedException extends ApiException {
  const UnauthorizedException(super.message) : super(statusCode: 401);
}

/// Thin JSON-over-HTTP wrapper. Stateless with respect to auth: callers pass
/// the base URL and bearer token explicitly.
class ApiClient {
  ApiClient({http.Client? httpClient, this.timeout = AppConfig.httpTimeout})
    : _http = httpClient ?? http.Client();

  final http.Client _http;
  final Duration timeout;

  Future<Map<String, dynamic>> getJson(
    String baseUrl,
    String path, {
    String? bearerToken,
  }) => _send(
    baseUrl,
    () => _http.get(_uri(baseUrl, path), headers: _headers(bearerToken)),
  );

  Future<Map<String, dynamic>> postJson(
    String baseUrl,
    String path,
    Map<String, dynamic> body, {
    String? bearerToken,
  }) => _send(
    baseUrl,
    () => _http.post(
      _uri(baseUrl, path),
      headers: {..._headers(bearerToken), 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ),
  );

  void close() => _http.close();

  Uri _uri(String baseUrl, String path) =>
      Uri.parse('${AppConfig.normalizeServerUrl(baseUrl)}$path');

  Map<String, String> _headers(String? token) => {
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<Map<String, dynamic>> _send(
    String baseUrl,
    Future<http.Response> Function() request,
  ) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      throw ApiException('The server at $baseUrl did not respond in time.');
    } on http.ClientException {
      throw ApiException(
        "Can't reach the server at $baseUrl. Check the server URL and that "
        'the backend is running.',
      );
    } on FormatException {
      throw ApiException('"$baseUrl" is not a valid server URL.');
    } on ArgumentError {
      throw ApiException('"$baseUrl" is not a valid server URL.');
    } on Exception catch (e) {
      // dart:io SocketException/HandshakeException/TlsException etc. are not
      // always wrapped in ClientException; matched generically so this file
      // still builds for web.
      throw ApiException(
        "Can't reach the server at $baseUrl (${e.runtimeType}). Check the "
        'server URL, that the backend is running, and http vs https.',
      );
    }

    final body = _decode(response);
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (body == null) {
        throw ApiException(
          'Unexpected response from server.',
          statusCode: status,
        );
      }
      return body;
    }

    final detail = _detail(body);
    if (status == 401) {
      throw UnauthorizedException(detail ?? 'Your session has expired.');
    }
    throw ApiException(detail ?? 'Server error ($status).', statusCode: status);
  }

  static Map<String, dynamic>? _decode(http.Response response) {
    if (response.body.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// FastAPI errors look like `{"detail": "..."}` (or a list for 422s).
  static String? _detail(Map<String, dynamic>? body) {
    final detail = body?['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    if (detail is List && detail.isNotEmpty) {
      final first = detail.first;
      if (first is Map && first['msg'] is String) return first['msg'] as String;
    }
    return null;
  }
}
