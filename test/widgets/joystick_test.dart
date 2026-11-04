import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weblink/widgets/joystick.dart';

void main() {
  testWidgets('survives many drag/release cycles and springs back', (
    tester,
  ) async {
    final values = <Offset>[];
    var starts = 0;
    var ends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Joystick(
              onChanged: values.add,
              onStart: () => starts++,
              onEnd: () => ends++,
            ),
          ),
        ),
      ),
    );

    const cycles = 300;
    for (var i = 0; i < cycles; i++) {
      await tester.drag(
        find.byType(Joystick),
        Offset(i.isEven ? 60 : -60, -80),
      );
      // Half the time let the spring finish, otherwise interrupt it.
      await tester.pump(Duration(milliseconds: i.isEven ? 200 : 40));
    }
    await tester.pumpAndSettle();

    expect(starts, cycles);
    expect(ends, cycles);
    expect(values.last, Offset.zero);
    expect(values.any((v) => v.distance > 0.5), isTrue);
    expect(values.every((v) => v.distance <= 1.0 + 1e-9), isTrue);

    // Dispose mid-spring.
    await tester.drag(find.byType(Joystick), const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
