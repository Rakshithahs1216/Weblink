import 'dart:math' as math;

import '../config.dart';

/// Normalised drive axes derived from the joystick knob position.
///
/// * [linear]  – forward positive (stick pushed up).
/// * [angular] – counter-clockwise positive (stick pushed left).
class JoystickAxes {
  const JoystickAxes(this.linear, this.angular);

  static const JoystickAxes zero = JoystickAxes(0, 0);

  final double linear;
  final double angular;

  bool get isZero => linear == 0 && angular == 0;

  /// Converts a knob offset in *screen* coordinates (x right, y down, where
  /// (±1, ±1) is the edge of the base) into drive axes:
  ///
  /// 1. clamp the vector to the unit circle,
  /// 2. apply a radial dead-zone (vectors shorter than [deadZone] become zero),
  /// 3. map y-up → +linear and x-left → +angular,
  /// 4. round both values to 3 decimal places.
  factory JoystickAxes.fromOffset(
    double dx,
    double dy, {
    double deadZone = AppConfig.joystickDeadZone,
  }) {
    var x = dx;
    var y = dy;
    final magnitude = math.sqrt(x * x + y * y);
    if (magnitude.isNaN || magnitude < deadZone) return zero;
    if (magnitude > 1) {
      x /= magnitude;
      y /= magnitude;
    }
    return JoystickAxes(roundTo3(-y), roundTo3(-x));
  }

  /// Rounds to 3 dp and normalises `-0.0` to `0.0` so JSON never shows `-0.0`.
  static double roundTo3(double value) {
    final rounded = (value * 1000).round() / 1000;
    return rounded == 0 ? 0.0 : rounded.clamp(-1.0, 1.0);
  }

  @override
  bool operator ==(Object other) =>
      other is JoystickAxes &&
      other.linear == linear &&
      other.angular == angular;

  @override
  int get hashCode => Object.hash(linear, angular);

  @override
  String toString() => 'JoystickAxes(linear: $linear, angular: $angular)';
}

/// A `{"type": "joystick", ...}` DataChannel message (ARCHITECTURE.md §4).
class JoystickCommand {
  const JoystickCommand({
    required this.linear,
    required this.angular,
    required this.seq,
    required this.ts,
  });

  factory JoystickCommand.fromAxes(
    JoystickAxes axes, {
    required int seq,
    required int ts,
  }) => JoystickCommand(
    linear: axes.linear,
    angular: axes.angular,
    seq: seq,
    ts: ts,
  );

  static const String messageType = 'joystick';

  final double linear;
  final double angular;

  /// Monotonically increasing sequence number.
  final int seq;

  /// Client epoch millis.
  final int ts;

  Map<String, dynamic> toJson() => {
    'type': messageType,
    'linear': linear,
    'angular': angular,
    'seq': seq,
    'ts': ts,
  };
}
