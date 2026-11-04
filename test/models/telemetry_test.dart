import 'package:flutter_test/flutter_test.dart';
import 'package:weblink/models/telemetry.dart';

void main() {
  group('Telemetry.fromJson', () {
    test('parses the contract example', () {
      final t = Telemetry.fromJson({
        'type': 'telemetry',
        'speed': 0.63,
        'battery': 87.4,
        'temperature': 36.2,
        'linear': 0.42,
        'angular': -0.10,
        'ts': 1730551234600,
      });
      expect(t.speed, 0.63);
      expect(t.battery, 87.4);
      expect(t.temperature, 36.2);
      expect(t.linear, 0.42);
      expect(t.angular, -0.10);
      expect(t.ts, 1730551234600);
    });

    test('accepts integers for double fields', () {
      final t = Telemetry.fromJson({
        'speed': 1,
        'battery': 100,
        'temperature': 30,
        'ts': 5,
      });
      expect(t.speed, 1.0);
      expect(t.battery, 100.0);
      expect(t.temperature, 30.0);
      expect(t.linear, 0.0);
      expect(t.angular, 0.0);
    });

    test('throws FormatException when a required field is missing', () {
      expect(
        () => Telemetry.fromJson({'speed': 1, 'battery': 50}),
        throwsFormatException,
      );
      expect(
        () => Telemetry.fromJson({
          'speed': '1',
          'battery': 50,
          'temperature': 30,
        }),
        throwsFormatException,
      );
    });

    test('toJson round-trips', () {
      const t = Telemetry(
        speed: 0.5,
        battery: 40,
        temperature: 33,
        linear: 0.1,
        angular: 0.2,
        ts: 7,
      );
      final copy = Telemetry.fromJson(t.toJson());
      expect(copy.toJson(), t.toJson());
    });
  });

  group('Telemetry.tryParse', () {
    test('parses a telemetry text frame', () {
      final t = Telemetry.tryParse(
        '{"type":"telemetry","speed":0.1,"battery":99,"temperature":31,'
        '"linear":0,"angular":0,"ts":1}',
      );
      expect(t, isNotNull);
      expect(t!.battery, 99);
    });

    test('returns null for other message types and malformed frames', () {
      expect(Telemetry.tryParse('{"type":"joystick","linear":0}'), isNull);
      expect(Telemetry.tryParse('not json'), isNull);
      expect(Telemetry.tryParse('[1,2,3]'), isNull);
      expect(Telemetry.tryParse('{"type":"telemetry","speed":1}'), isNull);
    });
  });
}
