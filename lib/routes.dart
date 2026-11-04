/// Named routes. Everything except [splash] and [login] requires a valid token.
abstract final class Routes {
  static const String splash = '/';
  static const String login = '/login';
  static const String home = '/home';
  static const String video = '/video';
  static const String joystick = '/joystick';
  static const String telemetry = '/telemetry';

  static const Set<String> protected = {home, video, joystick, telemetry};
}
