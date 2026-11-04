import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import '../models/telemetry.dart';
import 'auth_service.dart';
import 'signaling_client.dart'
    show WebSocketConnector, defaultWebSocketConnector;

enum SocketLinkState { stopped, connecting, connected, reconnecting }

/// `/ws/telemetry?token=<jwt>` client with exponential-backoff reconnect
/// (ARCHITECTURE.md §5). Close code 4401 triggers [onUnauthorized].
class TelemetrySocket extends ChangeNotifier {
  TelemetrySocket({
    required this._credentials,
    required this._onUnauthorized,
    required this._verifySession,
    this._connector = defaultWebSocketConnector,
  });

  final SessionCredentials? Function() _credentials;
  final Future<void> Function() _onUnauthorized;
  final Future<bool> Function() _verifySession;
  final WebSocketConnector _connector;

  final StreamController<Telemetry> _samples =
      StreamController<Telemetry>.broadcast();

  SocketLinkState _state = SocketLinkState.stopped;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retryTimer;
  int _failures = 0;
  int _generation = 0;
  bool _wanted = false;
  bool _disposed = false;

  SocketLinkState get state => _state;
  bool get isRunning => _wanted;
  Stream<Telemetry> get samples => _samples.stream;

  void start() {
    if (_wanted || _disposed) return;
    _wanted = true;
    _failures = 0;
    _connect();
  }

  Future<void> stop() async {
    _wanted = false;
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _closeChannel();
    _setState(SocketLinkState.stopped);
  }

  Future<void> _connect() async {
    final credentials = _credentials();
    if (!_wanted || credentials == null) return;
    final generation = ++_generation;
    bool isCurrent() => generation == _generation && _wanted && !_disposed;

    _setState(
      _failures == 0
          ? SocketLinkState.connecting
          : SocketLinkState.reconnecting,
    );
    final WebSocketChannel channel;
    try {
      channel = _connector(
        AppConfig.webSocketUri(
          credentials.serverUrl,
          '/ws/telemetry',
          credentials.token,
        ),
      );
      _channel = channel;
      await channel.ready;
    } catch (_) {
      if (!isCurrent()) return;
      _channel = null;
      // Handshake failures hide close code 4401 – confirm the token via REST.
      if (!await _verifySession()) return;
      if (isCurrent()) _scheduleRetry();
      return;
    }
    if (!isCurrent()) {
      await channel.sink.close();
      return;
    }

    _setState(SocketLinkState.connected);
    _subscription = channel.stream.listen(
      (data) {
        if (data is! String) return;
        final sample = Telemetry.tryParse(data);
        if (sample == null) return;
        _failures = 0;
        if (!_samples.isClosed) _samples.add(sample);
      },
      onDone: () {
        if (!isCurrent()) return;
        _channel = null;
        if (channel.closeCode == AppConfig.unauthorizedCloseCode) {
          _wanted = false;
          _setState(SocketLinkState.stopped);
          _onUnauthorized();
          return;
        }
        _scheduleRetry();
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  void _scheduleRetry() {
    _failures++;
    final seconds = math.min(10, 1 << math.min(_failures - 1, 4));
    _setState(SocketLinkState.reconnecting);
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds), _connect);
  }

  Future<void> _closeChannel() async {
    // Not awaited: cancelling can wait on pending deliveries, and closing the
    // sink below is what actually ends the connection.
    unawaited(_subscription?.cancel());
    _subscription = null;
    final channel = _channel;
    _channel = null;
    await channel?.sink.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
  }

  void _setState(SocketLinkState next) {
    if (_state == next || _disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _wanted = false;
    _retryTimer?.cancel();
    _closeChannel();
    _samples.close();
    super.dispose();
  }
}
