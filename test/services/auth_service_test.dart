import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weblink/services/api_client.dart';
import 'package:weblink/services/auth_service.dart';
import 'package:weblink/services/jwt.dart';

import '../support/fakes.dart';

/// Builds an unsigned JWT-shaped token with the given `exp` (epoch seconds).
String fakeJwt(int exp) {
  String part(Map<String, Object> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${part({'sub': 'demo', 'iss': 'weblink', 'exp': exp})}.sig';
}

void main() {
  late InMemoryTokenStorage storage;
  late List<http.Request> requests;

  AuthService build({http.Client? client, DateTime Function()? clock}) =>
      AuthService(
        storage: storage,
        api: ApiClient(httpClient: client ?? fakeBackend(log: requests)),
        clock: clock,
      );

  setUp(() {
    storage = InMemoryTokenStorage();
    requests = [];
  });

  group('login', () {
    test('stores the JWT and server URL and becomes authenticated', () async {
      final auth = build();
      await auth.login(
        username: ' demo ',
        password: 'demo1234',
        serverUrl: 'localhost:8010/',
      );

      expect(auth.status, AuthStatus.authenticated);
      expect(auth.user!.displayName, 'Demo Operator');
      expect(storage.token, 'valid-token');
      expect(storage.serverUrl, 'http://localhost:8010');
      expect(auth.credentials, (
        serverUrl: 'http://localhost:8010',
        token: 'valid-token',
      ));

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'http://localhost:8010/api/auth/login');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(request.body), {
        'username': 'demo',
        'password': 'demo1234',
      });
      auth.dispose();
    });

    test('accepts email as username', () async {
      final auth = build();
      await auth.login(
        username: 'demo@weblink.local',
        password: 'demo1234',
        serverUrl: 'http://localhost:8010',
      );
      expect(auth.isAuthenticated, isTrue);
      auth.dispose();
    });

    test(
      'bad credentials throw UnauthorizedException with server detail',
      () async {
        final auth = build();
        await expectLater(
          auth.login(
            username: 'demo',
            password: 'wrong',
            serverUrl: 'http://localhost:8010',
          ),
          throwsA(
            isA<UnauthorizedException>().having(
              (e) => e.message,
              'message',
              'Invalid username or password',
            ),
          ),
        );
        expect(auth.isAuthenticated, isFalse);
        expect(storage.token, isNull);
      },
    );

    test('network failure surfaces a readable ApiException', () async {
      final auth = build(
        client: MockClient((_) async => throw http.ClientException('down')),
      );
      await expectLater(
        auth.login(
          username: 'demo',
          password: 'demo1234',
          serverUrl: 'http://localhost:8010',
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains("Can't reach the server"),
          ),
        ),
      );
    });
  });

  group('bootstrap', () {
    test(
      'without a stored token goes to unauthenticated, no request',
      () async {
        final auth = build();
        await auth.bootstrap();
        expect(auth.status, AuthStatus.unauthenticated);
        expect(requests, isEmpty);
      },
    );

    test('validates a stored token with GET /api/auth/me', () async {
      storage
        ..token = 'valid-token'
        ..serverUrl = 'http://robot.local:8010';
      final auth = build();
      await auth.bootstrap();

      expect(auth.status, AuthStatus.authenticated);
      expect(auth.user!.username, 'demo');
      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.url.toString(), 'http://robot.local:8010/api/auth/me');
      expect(request.headers['Authorization'], 'Bearer valid-token');
      auth.dispose();
    });

    test('a rejected token (401) is deleted', () async {
      storage.token = 'stale-token';
      final auth = build();
      await auth.bootstrap();
      expect(auth.status, AuthStatus.unauthenticated);
      expect(storage.token, isNull);
      expect(auth.sessionMessage, AuthService.sessionExpiredMessage);
    });

    test('a locally expired JWT is deleted without a network call', () async {
      final now = DateTime.utc(2026, 1, 1, 12);
      storage.token = fakeJwt(
        now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000,
      );
      final auth = build(clock: () => now);
      await auth.bootstrap();
      expect(auth.status, AuthStatus.unauthenticated);
      expect(storage.token, isNull);
      expect(requests, isEmpty);
    });

    test('server unreachable keeps the token but requires login', () async {
      storage.token = 'valid-token';
      final auth = build(
        client: MockClient((_) async => throw http.ClientException('down')),
      );
      await auth.bootstrap();
      expect(auth.status, AuthStatus.unauthenticated);
      expect(storage.token, 'valid-token');
      expect(auth.sessionMessage, contains('Could not verify'));
    });

    test(
      'a non-http transport error (e.g. TLS) still requires login',
      () async {
        storage.token = 'valid-token';
        final auth = build(
          client: MockClient((_) async => throw const FakeTlsException()),
        );
        await auth.bootstrap();
        expect(auth.status, AuthStatus.unauthenticated);
        expect(storage.token, 'valid-token');
        expect(auth.sessionMessage, contains('Could not verify'));
      },
    );
  });

  group('logout', () {
    test('runs teardown handlers, deletes the token and notifies', () async {
      final auth = build();
      await auth.login(
        username: 'demo',
        password: 'demo1234',
        serverUrl: 'http://localhost:8010',
      );
      final calls = <String>[];
      auth
        ..addLogoutHandler(() async => calls.add('webrtc'))
        ..addLogoutHandler(() => calls.add('sockets'));
      var notified = 0;
      auth.addListener(() => notified++);

      await auth.logout();

      expect(calls, ['webrtc', 'sockets']);
      expect(storage.token, isNull);
      expect(auth.status, AuthStatus.unauthenticated);
      expect(auth.credentials, isNull);
      expect(notified, greaterThan(0));

      await auth.logout(); // idempotent
      expect(calls, hasLength(2));
    });

    test('verifySession logs out on 401', () async {
      final backend = fakeBackendHandler(validToken: 'valid-token');
      var revoke = false;
      final client = MockClient((request) async {
        if (revoke && request.url.path == '/api/auth/me') {
          return http.Response('{"detail":"Token expired"}', 401);
        }
        return backend(request);
      });
      final auth = build(client: client);
      await auth.login(
        username: 'demo',
        password: 'demo1234',
        serverUrl: 'http://localhost:8010',
      );
      expect(await auth.verifySession(), isTrue);

      revoke = true;
      expect(await auth.verifySession(), isFalse);
      expect(auth.status, AuthStatus.unauthenticated);
      expect(storage.token, isNull);
    });
  });

  test('jwtExpiry reads the exp claim', () {
    expect(
      jwtExpiry(fakeJwt(1700000000)),
      DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    );
    expect(jwtExpiry('not-a-jwt'), isNull);
  });
}
