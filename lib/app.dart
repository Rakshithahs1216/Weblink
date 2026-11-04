import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'routes.dart';
import 'screens/home_screen.dart';
import 'screens/joystick_screen.dart';
import 'screens/login_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/telemetry_screen.dart';
import 'screens/video_screen.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/robot_session.dart';
import 'services/signaling_client.dart';
import 'services/telemetry_hub.dart';
import 'services/telemetry_socket.dart';
import 'services/token_storage.dart';
import 'theme.dart';

/// Root widget: builds the service graph, exposes it via provider and acts as
/// the auth gate (protected routes + global redirect to Login on logout/401).
class WeblinkApp extends StatefulWidget {
  const WeblinkApp({
    super.key,
    required this.storage,
    this.httpClient,
    this.webSocketConnector = defaultWebSocketConnector,
  });

  final TokenStorage storage;

  /// Injectable for tests (e.g. `MockClient`).
  final http.Client? httpClient;
  final WebSocketConnector webSocketConnector;

  @override
  State<WeblinkApp> createState() => _WeblinkAppState();
}

class _WeblinkAppState extends State<WeblinkApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  late final ApiClient _api;
  late final AuthService _auth;
  late final RobotSession _session;
  late final TelemetrySocket _telemetrySocket;
  late final TelemetryHub _telemetryHub;
  AuthStatus _lastStatus = AuthStatus.unknown;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(httpClient: widget.httpClient);
    _auth = AuthService(storage: widget.storage, api: _api);
    _session = RobotSession(
      credentials: () => _auth.credentials,
      onUnauthorized: _auth.handleUnauthorized,
      verifySession: _auth.verifySession,
      connector: widget.webSocketConnector,
    );
    _telemetrySocket = TelemetrySocket(
      credentials: () => _auth.credentials,
      onUnauthorized: _auth.handleUnauthorized,
      verifySession: _auth.verifySession,
      connector: widget.webSocketConnector,
    );
    _telemetryHub = TelemetryHub(
      dataChannelSamples: _session.telemetry,
      socket: _telemetrySocket,
    );

    // Logout (manual, 401, 4401 or expiry) tears down every connection.
    _auth
      ..addLogoutHandler(_session.disconnect)
      ..addLogoutHandler(_telemetryHub.stop)
      ..addListener(_onAuthChanged);
  }

  void _onAuthChanged() {
    final status = _auth.status;
    final previous = _lastStatus;
    _lastStatus = status;
    if (status == previous) return;

    if (status == AuthStatus.authenticated) {
      _telemetryHub.start();
    } else if (status == AuthStatus.unauthenticated &&
        previous == AuthStatus.authenticated) {
      // Clear the whole stack so Back can't return to a protected screen.
      _navigatorKey.currentState?.pushNamedAndRemoveUntil(
        Routes.login,
        (_) => false,
      );
    }
  }

  Route<dynamic> _onGenerateRoute(RouteSettings settings) {
    var name = settings.name ?? Routes.splash;
    if (Routes.protected.contains(name) && !_auth.isAuthenticated) {
      name = Routes.login;
    }
    final WidgetBuilder builder = switch (name) {
      Routes.login => (_) => const LoginScreen(),
      Routes.home => (_) => const HomeScreen(),
      Routes.video => (_) => const VideoScreen(),
      Routes.joystick => (_) => const JoystickScreen(),
      Routes.telemetry => (_) => const TelemetryScreen(),
      _ => (_) => const SplashScreen(),
    };
    return MaterialPageRoute<void>(
      builder: builder,
      settings: RouteSettings(name: name, arguments: settings.arguments),
    );
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _telemetryHub.dispose();
    _telemetrySocket.dispose();
    _session.dispose();
    _auth.dispose();
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthService>.value(value: _auth),
        ChangeNotifierProvider<RobotSession>.value(value: _session),
        ChangeNotifierProvider<TelemetryHub>.value(value: _telemetryHub),
      ],
      child: MaterialApp(
        title: 'Weblink',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigatorKey,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        initialRoute: Routes.splash,
        onGenerateRoute: _onGenerateRoute,
      ),
    );
  }
}
