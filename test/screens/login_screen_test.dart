import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:weblink/routes.dart';
import 'package:weblink/screens/login_screen.dart';
import 'package:weblink/services/api_client.dart';
import 'package:weblink/services/auth_service.dart';
import 'package:weblink/theme.dart';

import '../support/fakes.dart';

void main() {
  late InMemoryTokenStorage storage;
  late AuthService auth;

  Future<void> pumpLogin(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthService>.value(
        value: auth,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          initialRoute: Routes.login,
          routes: {
            Routes.login: (_) => const LoginScreen(),
            Routes.home: (_) => const Scaffold(body: Text('HOME SCREEN')),
          },
        ),
      ),
    );
  }

  setUp(() {
    storage = InMemoryTokenStorage(serverUrl: 'http://localhost:8010');
    auth = AuthService(
      storage: storage,
      api: ApiClient(httpClient: fakeBackend()),
    );
  });

  tearDown(() => auth.dispose());

  testWidgets('shows validation errors for empty fields', (tester) async {
    await pumpLogin(tester);
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pump();

    expect(find.text('Enter your username or email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
    expect(find.text('HOME SCREEN'), findsNothing);
  });

  testWidgets('invalid server URL expands server settings with an error', (
    tester,
  ) async {
    await pumpLogin(tester);
    // Expand, enter a bad URL, collapse again: submit must re-expand it.
    await tester.tap(find.text('Server settings'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('login.server')), 'ftp://x');
    await tester.tap(find.text('Server settings'));
    await tester.pump();
    expect(find.byKey(const Key('login.server')), findsNothing);
    await tester.enterText(find.byKey(const Key('login.username')), 'demo');
    await tester.enterText(find.byKey(const Key('login.password')), 'demo1234');
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login.server')), findsOneWidget);
    expect(find.textContaining('Enter a valid http(s) URL'), findsOneWidget);
    expect(find.text('HOME SCREEN'), findsNothing);
  });

  testWidgets('password visibility can be toggled', (tester) async {
    await pumpLogin(tester);
    EditableText passwordField() => tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('login.password')),
        matching: find.byType(EditableText),
      ),
    );
    expect(passwordField().obscureText, isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(passwordField().obscureText, isFalse);
  });

  testWidgets('wrong password shows the server error message', (tester) async {
    await pumpLogin(tester);
    await tester.enterText(find.byKey(const Key('login.username')), 'demo');
    await tester.enterText(find.byKey(const Key('login.password')), 'nope');
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pumpAndSettle();

    expect(find.text('Invalid username or password'), findsOneWidget);
    expect(find.text('HOME SCREEN'), findsNothing);
    expect(storage.token, isNull);
  });

  testWidgets('successful login stores the token and navigates home', (
    tester,
  ) async {
    await pumpLogin(tester);
    await tester.enterText(find.byKey(const Key('login.username')), 'demo');
    await tester.enterText(find.byKey(const Key('login.password')), 'demo1234');
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pumpAndSettle();

    expect(find.text('HOME SCREEN'), findsOneWidget);
    expect(storage.token, 'valid-token');
    expect(auth.isAuthenticated, isTrue);
    await auth.logout(); // cancels the token-expiry timer
  });
}
