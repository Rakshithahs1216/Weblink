import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weblink/app.dart';

import 'support/fakes.dart';

/// End-to-end smoke tests of the app shell with a fake backend.
void main() {
  late List<FakeWebSocketChannel> sockets;

  Widget app(InMemoryTokenStorage storage) => WeblinkApp(
    storage: storage,
    httpClient: fakeBackend(),
    webSocketConnector: (uri) {
      final channel = FakeWebSocketChannel(uri);
      sockets.add(channel);
      return channel;
    },
  );

  setUp(() => sockets = []);

  testWidgets('without a stored token the app opens on Login', (tester) async {
    await tester.pumpWidget(app(InMemoryTokenStorage()));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Weblink'), findsOneWidget);
    expect(sockets, isEmpty);
  });

  testWidgets(
    'a valid stored token skips Login, streams telemetry, logout clears it',
    (tester) async {
      // Tall viewport so the whole Home list is laid out.
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final storage = InMemoryTokenStorage(
        token: 'valid-token',
        serverUrl: 'http://localhost:8010',
      );
      await tester.pumpWidget(app(storage));
      await tester.pumpAndSettle();

      expect(find.text('Demo Operator'), findsOneWidget);
      expect(find.text('Start WebRTC Stream'), findsOneWidget);

      // Telemetry WebSocket was opened with the JWT; push one sample.
      final telemetry = sockets.single;
      expect(telemetry.uri.path, '/ws/telemetry');
      expect(telemetry.uri.queryParameters['token'], 'valid-token');
      telemetry.serverSend(
        '{"type":"telemetry","speed":0.63,"battery":87.4,"temperature":36.2,'
        '"linear":0.42,"angular":-0.1,"ts":1}',
      );
      await tester.pump(); // deliver the frame through socket → hub
      await tester.pump(); // rebuild Home
      expect(find.textContaining('0.63'), findsOneWidget);
      expect(find.textContaining('87.4'), findsOneWidget);
      expect(find.textContaining('36.2'), findsOneWidget);

      // Logout with confirmation.
      await tester.tap(find.text('Log out').first);
      await tester.pumpAndSettle();
      expect(find.text('Log out?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
      // Teardown is a chain of futures (bye, socket close, token delete);
      // give fake async a few turns before settling the navigation.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();

      expect(find.text('Welcome to Weblink'), findsOneWidget);
      expect(storage.token, isNull);
      expect(telemetry.closedByClient, isTrue);

      await tester.pumpWidget(const SizedBox()); // dispose services/timers
    },
  );
}
