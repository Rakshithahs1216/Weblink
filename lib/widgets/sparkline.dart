import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Minimal line chart for a short rolling history, drawn with a
/// [CustomPainter] (no chart dependency).
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.min,
    this.max,
    this.height = 48,
  });

  /// Expected to be an immutable snapshot: repaint is decided by identity.
  final List<double> values;
  final Color color;

  /// Fixed axis bounds; when null the range is derived from [values].
  final double? min;
  final double? max;
  final double height;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: SparklinePainter(
            values: values,
            color: color,
            min: min,
            max: max,
            gridColor: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
    );
  }
}

class SparklinePainter extends CustomPainter {
  SparklinePainter({
    required this.values,
    required this.color,
    required this.gridColor,
    this.min,
    this.max,
  });

  final List<double> values;
  final Color color;
  final Color gridColor;
  final double? min;
  final double? max;

  @override
  void paint(Canvas canvas, Size size) {
    // Baseline grid.
    final grid = Paint()
      ..color = gridColor.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      grid,
    );
    if (values.length < 2) return;

    var lo = min ?? values.reduce(math.min);
    var hi = max ?? values.reduce(math.max);
    if (hi - lo < 1e-6) {
      // Flat line: give it some vertical room so it sits mid-height.
      lo -= 1;
      hi += 1;
    }
    const pad = 3.0;
    final drawHeight = size.height - pad * 2;
    final dx = size.width / (values.length - 1);
    Offset point(int i) {
      final t = ((values[i] - lo) / (hi - lo)).clamp(0.0, 1.0);
      return Offset(i * dx, pad + drawHeight * (1 - t));
    }

    final line = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < values.length; i++) {
      final p = point(i);
      line.lineTo(p.dx, p.dy);
    }

    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    final last = point(values.length - 1);
    canvas.drawCircle(last, 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(SparklinePainter old) =>
      !identical(old.values, values) ||
      old.color != color ||
      old.gridColor != gridColor ||
      old.min != min ||
      old.max != max;
}
