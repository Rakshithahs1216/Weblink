import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weblink/services/token_storage.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// In-memory [TokenStorage] for tests.
class InMemoryTokenStorage implements TokenStorage {
  InMemoryTokenStorage({this.token, this.serverUrl});

  String? token;
  String? serverUrl;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async => token = value;

  @override
  Future<void> deleteToken() async => token = null;

  @override
  Future<String?> readServerUrl() async => serverUrl;

  @override
  Future<void> writeServerUrl(String url) async => serverUrl = url;
}

const demoUser = {'username': 'demo', 'display_name': 'Demo Operator'};

/// A fake backend implementing the REST contract from ARCHITECTURE.md §2.
MockClient fakeBackend({
  String validToken = 'valid-token',
  List<http.Request>? log,
}) => MockClient(fakeBackendHandler(validToken: validToken, log: log));

/// The request handler behind [fakeBackend], reusable to wrap in other mocks.
MockClientHandler fakeBackendHandler({
  String validToken = 'valid-token',
  List<http.Request>? log,
}) {
  return (request) async {
    log?.add(request);
    http.Response json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

    switch (request.url.path) {
      case '/api/auth/login':
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final user = body['username'];
        final ok =
            (user == 'demo' || user == 'demo@weblink.local') &&
            body['password'] == 'demo1234';
        if (!ok) return json({'detail': 'Invalid username or password'}, 401);
        return json({
          'access_token': validToken,
          'token_type': 'bearer',
          'expires_in': 3600,
          'user': demoUser,
        }, 200);
      case '/api/auth/me':
        if (request.headers['Authorization'] != 'Bearer $validToken') {
          return json({'detail': 'Invalid or expired token'}, 401);
        }
        return json(demoUser, 200);
      default:
        return json({'detail': 'Not Found'}, 404);
    }
  };
}

/// Scriptable in-memory [WebSocketChannel].
class FakeWebSocketChannel implements WebSocketChannel {
  FakeWebSocketChannel(this.uri, {bool failHandshake = false})
    : _ready = failHandshake
          ? Future<void>.error(WebSocketChannelException('refused'))
          : Future<void>.value() {
    _ready.catchError((_) {}); // avoid unhandled-error noise
  }

  final Uri uri;
  final Future<void> _ready;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final List<dynamic> sent = [];
  late final _FakeSink _sink = _FakeSink(this);
  int? _closeCode;
  String? _closeReason;

  /// Server → client frame.
  void serverSend(String data) => _incoming.add(data);

  /// Server closes the socket with [code].
  void serverClose(int code, [String? reason]) {
    _closeCode = code;
    _closeReason = reason;
    unawaited(_incoming.close());
  }

  bool get closedByClient => _sink.closed;

  @override
  Future<void> get ready => _ready;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  String? get protocol => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._channel);

  final FakeWebSocketChannel _channel;
  bool closed = false;

  @override
  void add(dynamic data) => _channel.sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
    // Don't await: the done event is only delivered if someone listens.
    if (!_channel._incoming.isClosed) unawaited(_channel._incoming.close());
  }

  @override
  Future<void> get done async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stands in for dart:io's HandshakeException/TlsException/SocketException:
/// an [Exception] that is not an http `ClientException`.
class FakeTlsException implements Exception {
  const FakeTlsException();

  @override
  String toString() => 'FakeTlsException: certificate verify failed';
}
