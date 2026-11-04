import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weblink/services/api_client.dart';

import '../support/fakes.dart';

void main() {
  const base = 'http://robot.local:8010';

  Future<Map<String, dynamic>> requestFailingWith(Object error) =>
      ApiClient(httpClient: MockClient((_) async => throw error))
          .getJson(base, '/api/auth/me');

  Matcher apiException(String messagePart) => throwsA(
    isA<ApiException>().having(
      (e) => e.message,
      'message',
      contains(messagePart),
    ),
  );

  test('maps a non-http transport exception to ApiException', () async {
    // Stands in for dart:io HandshakeException/SocketException, which the
    // http package does not always wrap in ClientException.
    await expectLater(
      requestFailingWith(const FakeTlsException()),
      throwsA(
        isA<ApiException>()
            .having((e) => e, 'type', isNot(isA<UnauthorizedException>()))
            .having((e) => e.statusCode, 'statusCode', isNull)
            .having(
              (e) => e.message,
              'message',
              allOf(
                contains("Can't reach the server at $base"),
                contains('FakeTlsException'),
              ),
            ),
      ),
    );
  });

  test('maps ClientException to ApiException', () async {
    await expectLater(
      requestFailingWith(http.ClientException('down')),
      apiException("Can't reach"),
    );
  });

  test('maps a timeout to ApiException', () async {
    await expectLater(
      requestFailingWith(TimeoutException('slow')),
      apiException('did not respond'),
    );
  });

  test('does not swallow programming errors', () async {
    await expectLater(
      requestFailingWith(StateError('bug')),
      throwsA(isA<StateError>()),
    );
  });
}
