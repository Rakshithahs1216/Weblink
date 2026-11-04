import 'dart:convert';

/// Where a telemetry sample came from.
enum TelemetrySource {
  dataChannel('DataChannel'),
  webSocket('WebSocket');

  const TelemetrySource(this.label);
  final String label;
}

/// One `{"type": "telemetry", ...}` sample (ARCHITECTURE.md §4/§5).
class Telemetry {
  const Telemetry({
    required this.speed,
    required this.battery,
    required this.temperature,
    this.linear = 0,
    this.angular = 0,
    this.ts = 0,
  });

  /// Speed in m/s (0–1.5).
  final double speed;

  /// Battery charge in percent (0–100).
  final double battery;

  /// Temperature in °C.
  final double temperature;

  /// Echo of the last joystick command applied by the robot.
  final double linear;
  final double angular;

  /// Server epoch millis.
  final int ts;

  static const String messageType = 'telemetry';

  /// Throws [FormatException] when a required numeric field is missing.
  factory Telemetry.fromJson(Map<String, dynamic> json) {
    double required(String key) {
      final value = json[key];
      if (value is num) return value.toDouble();
      throw FormatException(
        'Telemetry field "$key" is missing or not a number',
      );
    }

    double optional(String key) {
      final value = json[key];
      return value is num ? value.toDouble() : 0;
    }

    final ts = json['ts'];
    return Telemetry(
      speed: required('speed'),
      battery: required('battery'),
      temperature: required('temperature'),
      linear: optional('linear'),
      angular: optional('angular'),
      ts: ts is num ? ts.toInt() : 0,
    );
  }

  /// Parses a raw text frame. Returns null for anything that is not a
  /// well-formed telemetry message, so callers can ignore unrelated frames.
  static Telemetry? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['type'] != messageType) return null;
      return Telemetry.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'type': messageType,
    'speed': speed,
    'battery': battery,
    'temperature': temperature,
    'linear': linear,
    'angular': angular,
    'ts': ts,
  };
}
