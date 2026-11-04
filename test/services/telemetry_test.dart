import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:weblink/models/telemetry.dart';
import 'package:weblink/services/telemetry_hub.dart';
import 'package:weblink/services/telemetry_socket.dart';

import '../support/fakes.dart';

const _frame =
    '{"type":"telemetry","speed":0.5,"battery":80,"temperature":35,'
    '"linear":0.2,"angular":0,"ts":1}';

void main() {
  late List<FakeWebSocketChannel> channels;
  late int unauthorizedCalls;

  TelemetrySocket buildSocket({bool failHandshake = false}) => TelemetrySocket(
    credentials: () => (serverUrl: 'http://localhost:8010', token: 'jwt'),
    onUnauthorized: () async => unauthorizedCalls++,
    verifySession: () async => true,
    connector: (uri) {
      final channel = FakeWebSocketChannel(uri, failHandshake: failHandshake);
      channels.add(channel);
      return channel;
    },
  );

  setUp(() {
    channels = [];
    unauthorizedCalls = 0;
  });

  group('TelemetrySocket', () {
    testWidgets('connects with the token and emits parsed samples', (
      tester,
    ) async {
      final socket = buildSocket();
      final samples = <Telemetry>[];
      final sub = socket.samples.listen(samples.add);

      socket.start();
      await tester.pump();
      expect(
        channels.single.uri.toString(),
        'ws://localhost:8010/ws/telemetry?token=jwt',
      );
      expect(socket.state, SocketLinkState.connected);

      channels.single
        ..serverSend(_frame)
        ..serverSend('{"type":"something-else"}');
      await tester.pump();
      expect(samples, hasLength(1));
      expect(samples.single.speed, 0.5);

      await tester.runAsync(socket.stop);
      expect(channels.single.closedByClient, isTrue);
      expect(socket.state, SocketLinkState.stopped);
      unawaited(sub.cancel());
      socket.dispose();
    });

    testWidgets('close code 4401 forces logout and stops reconnecting', (
      tester,
    ) async {
      final socket = buildSocket();
      socket.start();
      await tester.pump();
      channels.single.serverClose(4401);
      await tester.pump();

      expect(unauthorizedCalls, 1);
      expect(socket.state, SocketLinkState.stopped);
      await tester.pump(const Duration(seconds: 15));
      expect(channels, hasLength(1)); // no reconnect
      socket.dispose();
    });

    testWidgets('other closes reconnect with backoff', (tester) async {
      final socket = buildSocket();
      socket.start();
      await tester.pump();
      channels.single.serverClose(1011);
      await tester.pump();
      expect(socket.state, SocketLinkState.reconnecting);

      await tester.pump(const Duration(seconds: 1));
      expect(channels, hasLength(2));
      expect(unauthorizedCalls, 0);
      socket.dispose();
    });
  });

  group('TelemetryHub', () {
    testWidgets('prefers DataChannel, pauses the WebSocket, caps history', (
      tester,
    ) async {
      final dataChannel = StreamController<Telemetry>.broadcast();
      final socket = buildSocket();
      var now = DateTime(2026, 11, 2, 12);
      final hub = TelemetryHub(
        dataChannelSamples: dataChannel.stream,
        socket: socket,
        historyLength: 5,
        clock: () => now,
      );
      hub.start();
      await tester.pump();
      expect(socket.isRunning, isTrue);

      channels.single.serverSend(_frame);
      await tester.pump();
      expect(hub.source, TelemetrySource.webSocket);
      expect(hub.latest!.battery, 80);

      for (var i = 0; i < 8; i++) {
        dataChannel.add(
          Telemetry(speed: i / 10, battery: 90, temperature: 30, ts: i),
        );
      }
      await tester.pump();
      expect(hub.source, TelemetrySource.dataChannel);
      expect(socket.isRunning, isFalse, reason: 'WS paused while DC is live');
      expect(hub.speedHistory, [0.3, 0.4, 0.5, 0.6, 0.7]);

      // DataChannel goes quiet → WebSocket fallback is reopened.
      now = now.add(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 4));
      expect(socket.isRunning, isTrue);
      expect(hub.isStale, isTrue);

      await tester.runAsync(hub.stop);
      expect(hub.latest, isNull);
      expect(hub.speedHistory, isEmpty);
      hub.dispose();
      socket.dispose();
      unawaited(dataChannel.close());
    });
  });
}
