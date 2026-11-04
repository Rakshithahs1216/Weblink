import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/signaling_message.dart';

/// Opens a WebSocket. Injectable so socket-based services can be tested.
typedef WebSocketConnector = WebSocketChannel Function(Uri uri);

WebSocketChannel defaultWebSocketConnector(Uri uri) =>
    WebSocketChannel.connect(uri);

/// JSON signaling over `/ws/signaling?token=<jwt>` (ARCHITECTURE.md §3).
///
/// Knows nothing about WebRTC – it only frames [SignalingMessage]s – so it
/// stays testable without the native plugin.
class SignalingClient {
  SignalingClient({
    required this.uri,
    required this.onMessage,
    required this.onClosed,
    this._connector = defaultWebSocketConnector,
  });

  final Uri uri;
  final void Function(SignalingMessage message) onMessage;

  /// Called once when the server (or network) closes the socket. Not called
  /// after [close].
  final void Function(int? code, String? reason) onClosed;

  final WebSocketConnector _connector;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _closedByUs = false;

  bool get isOpen => _channel != null && !_closedByUs;

  /// Completes once the handshake succeeds; throws if it fails (bad URL,
  /// server down, or token rejected before `accept`).
  Future<void> connect() async {
    final channel = _connector(uri);
    _channel = channel;
    await channel.ready;
    _subscription = channel.stream.listen(
      (data) {
        if (data is String) onMessage(SignalingMessage.parse(data));
      },
      onDone: () {
        if (!_closedByUs) onClosed(channel.closeCode, channel.closeReason);
      },
      onError: (Object _) {
        // onDone follows with the close code.
      },
      cancelOnError: false,
    );
  }

  void send(SignalingMessage message) {
    if (!isOpen) return;
    _channel!.sink.add(message.encode());
  }

  Future<void> close() async {
    if (_closedByUs) return;
    _closedByUs = true;
    unawaited(_subscription?.cancel());
    await _channel?.sink.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
  }
}
