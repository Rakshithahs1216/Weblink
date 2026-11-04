import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:weblink/models/joystick_command.dart';

void main() {
  group('JoystickAxes.fromOffset', () {
    test('centre and anything inside the 0.08 dead-zone is zero', () {
      expect(JoystickAxes.fromOffset(0, 0), JoystickAxes.zero);
      expect(
        JoystickAxes.fromOffset(0.05, -0.05),
        JoystickAxes.zero,
      ); // |v|≈0.071
      expect(JoystickAxes.fromOffset(0, 0.079), JoystickAxes.zero);
    });

    test('just outside the dead-zone passes through', () {
      final axes = JoystickAxes.fromOffset(0, -0.08);
      expect(axes.linear, 0.08);
      expect(axes.angular, 0.0);
    });

    test('y up (negative screen y) is +linear, y down is -linear', () {
      expect(JoystickAxes.fromOffset(0, -1).linear, 1.0);
      expect(JoystickAxes.fromOffset(0, 1).linear, -1.0);
    });

    test('x left (negative screen x) is +angular, x right is -angular', () {
      expect(JoystickAxes.fromOffset(-1, 0).angular, 1.0);
      expect(JoystickAxes.fromOffset(1, 0).angular, -1.0);
    });

    test('vectors beyond the edge are clamped to the unit circle', () {
      final axes = JoystickAxes.fromOffset(-3, -3); // up-left, far outside
      expect(axes.linear, closeTo(0.707, 1e-9));
      expect(axes.angular, closeTo(0.707, 1e-9));
      final length = axes.linear * axes.linear + axes.angular * axes.angular;
      expect(length, lessThanOrEqualTo(1.0 + 1e-6));

      expect(JoystickAxes.fromOffset(0, -5), const JoystickAxes(1.0, 0.0));
    });

    test('values are rounded to 3 decimal places', () {
      final axes = JoystickAxes.fromOffset(0.123456, -0.654321);
      expect(axes.linear, 0.654);
      expect(axes.angular, -0.123);
    });

    test('never produces negative zero', () {
      final axes = JoystickAxes.fromOffset(0.0004, -0.5);
      expect(axes.angular, 0.0);
      expect(axes.angular.isNegative, isFalse);
      final json = jsonEncode(
        JoystickCommand.fromAxes(axes, seq: 1, ts: 0).toJson(),
      );
      expect(json, isNot(contains('-0.0')));
    });

    test('roundTo3 keeps values inside [-1, 1]', () {
      expect(JoystickAxes.roundTo3(1.00049), 1.0);
      expect(JoystickAxes.roundTo3(-1.2), -1.0);
    });
  });

  group('JoystickCommand.toJson', () {
    test('matches the DataChannel contract', () {
      const command = JoystickCommand(
        linear: 0.42,
        angular: -0.1,
        seq: 17,
        ts: 1730551234567,
      );
      expect(command.toJson(), {
        'type': 'joystick',
        'linear': 0.42,
        'angular': -0.1,
        'seq': 17,
        'ts': 1730551234567,
      });
      expect(
        jsonEncode(command.toJson()),
        '{"type":"joystick","linear":0.42,"angular":-0.1,"seq":17,'
        '"ts":1730551234567}',
      );
    });

    test('fromAxes copies axes, seq and ts', () {
      final command = JoystickCommand.fromAxes(
        const JoystickAxes(0.5, -0.25),
        seq: 3,
        ts: 99,
      );
      expect(command.linear, 0.5);
      expect(command.angular, -0.25);
      expect(command.seq, 3);
      expect(command.ts, 99);
    });
  });
}
