import 'package:flutter/foundation.dart';

/// App-wide constants. Values that are part of the backend contract are taken
/// verbatim from docs/ARCHITECTURE.md.
abstract final class AppConfig {
  /// Default backend URL: the Android emulator reaches the host machine via
  /// 10.0.2.2; every other platform (web, desktop, iOS simulator) uses localhost.
  static String get defaultServerUrl =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? 'http://10.0.2.2:8010'
      : 'http://localhost:8010';

  static const String stunServer = 'stun:stun.l.google.com:19302';

  /// Name of the DataChannel used for joystick commands and telemetry.
  static const String controlChannelLabel = 'control';

  /// WebSocket close code the backend uses for a missing/invalid JWT.
  static const int unauthorizedCloseCode = 4401;

  /// Joystick commands are sent at 20 Hz while the stick is held.
  static const Duration joystickSendInterval = Duration(milliseconds: 50);
  static const double joystickDeadZone = 0.08;

  static const int telemetryHistoryLength = 60;

  /// Telemetry is pushed every 200 ms; anything older than this is "stale".
  static const Duration telemetryStaleAfter = Duration(seconds: 2);

  static const Duration httpTimeout = Duration(seconds: 10);
  static const Duration webRtcConnectTimeout = Duration(seconds: 20);

  /// Normalises user input such as `localhost:8010/` into `http://localhost:8010`.
  static String normalizeServerUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return url;
    if (!url.contains('://')) url = 'http://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Returns null when [input] is a usable http(s) base URL, else an error.
  static String? validateServerUrl(String? input) {
    final value = normalizeServerUrl(input ?? '');
    if (value.isEmpty) return 'Enter the server URL';
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return 'Enter a valid http(s) URL, e.g. http://localhost:8010';
    }
    return null;
  }

  /// Builds `ws(s)://<host>/<path>?token=<jwt>` from an http(s) base URL.
  static Uri webSocketUri(String serverUrl, String path, String token) {
    final base = Uri.parse(normalizeServerUrl(serverUrl));
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '$basePath$path',
      queryParameters: {'token': token},
    );
  }
}
