import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config.dart';

/// A custom virtual joystick: circular base with a draggable knob.
///
/// Reports the knob position as a *normalised screen-space* vector
/// (x right, y down) clamped to the unit circle. Mapping to drive axes
/// (y-up = +linear, x-left = +angular, dead-zone, rounding) is done by
/// `JoystickAxes.fromOffset` so the math stays unit-testable.
///
/// The knob is painted through a [ValueNotifier] used as the painter's
/// repaint listenable, so dragging repaints only this widget's canvas – no
/// widget rebuilds per pointer event.
class Joystick extends StatefulWidget {
  const Joystick({
    super.key,
    required this.onChanged,
    this.onStart,
    this.onEnd,
    this.size = 240,
    this.enabled = true,
    this.deadZone = AppConfig.joystickDeadZone,
  });

  final ValueChanged<Offset> onChanged;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;
  final double size;

  /// When false the stick is dimmed (it still moves, so users get feedback).
  final bool enabled;

  /// Only used to draw the dead-zone ring.
  final double deadZone;

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<Offset> _knob = ValueNotifier(Offset.zero);
  late final AnimationController _spring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  // One curve for the widget's lifetime: each CurvedAnimation registers a
  // listener on [_spring], so creating one per release would leak listeners.
  late final CurvedAnimation _springCurve = CurvedAnimation(
    parent: _spring,
    curve: Curves.easeOutBack,
  );
  Animation<Offset>? _springAnimation;
  bool _active = false;

  double get _knobRadius => widget.size * 0.17;
  double get _travel => widget.size / 2 - _knobRadius;

  @override
  void initState() {
    super.initState();
    _spring.addListener(() {
      final animation = _springAnimation;
      if (animation != null) _knob.value = animation.value;
    });
  }

  void _start(Offset localPosition) {
    _spring.stop();
    _active = true;
    widget.onStart?.call();
    _update(localPosition);
  }

  void _update(Offset localPosition) {
    if (!_active) return;
    final center = Offset(widget.size / 2, widget.size / 2);
    var v = (localPosition - center) / _travel;
    final length = v.distance;
    if (length > 1) v = v / length;
    _knob.value = v;
    widget.onChanged(v);
  }

  void _release() {
    if (!_active) return;
    _active = false;
    _springAnimation = Tween<Offset>(
      begin: _knob.value,
      end: Offset.zero,
    ).animate(_springCurve);
    _spring.forward(from: 0);
    widget.onChanged(Offset.zero);
    widget.onEnd?.call();
  }

  @override
  void dispose() {
    _springCurve.dispose();
    _spring.dispose();
    _knob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Joystick',
      hint: 'Drag up to drive forward, left or right to turn',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // onPanDown engages immediately on touch (no slop delay).
        onPanDown: (d) => _start(d.localPosition),
        onPanUpdate: (d) => _update(d.localPosition),
        onPanEnd: (_) => _release(),
        onPanCancel: _release,
        child: AnimatedOpacity(
          opacity: widget.enabled ? 1 : 0.55,
          duration: const Duration(milliseconds: 200),
          child: SizedBox.square(
            dimension: widget.size,
            child: CustomPaint(
              painter: _JoystickPainter(
                knob: _knob,
                knobRadius: _knobRadius,
                travel: _travel,
                deadZone: widget.deadZone,
                baseColor: scheme.surfaceContainerHigh,
                ringColor: scheme.outlineVariant,
                guideColor: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                knobColor: scheme.primary,
                knobHighlight: scheme.primaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _JoystickPainter extends CustomPainter {
  _JoystickPainter({
    required this.knob,
    required this.knobRadius,
    required this.travel,
    required this.deadZone,
    required this.baseColor,
    required this.ringColor,
    required this.guideColor,
    required this.knobColor,
    required this.knobHighlight,
  }) : super(repaint: knob);

  final ValueNotifier<Offset> knob;
  final double knobRadius;
  final double travel;
  final double deadZone;
  final Color baseColor;
  final Color ringColor;
  final Color guideColor;
  final Color knobColor;
  final Color knobHighlight;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;

    // Base.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [baseColor, Color.lerp(baseColor, Colors.black, 0.25)!],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ringColor,
    );

    // Travel ring + crosshair guides.
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = guideColor;
    canvas.drawCircle(center, travel, guide);
    canvas.drawLine(
      center.translate(-travel, 0),
      center.translate(travel, 0),
      guide,
    );
    canvas.drawLine(
      center.translate(0, -travel),
      center.translate(0, travel),
      guide,
    );
    // Dead-zone.
    canvas.drawCircle(
      center,
      math.max(travel * deadZone, 3),
      Paint()..color = guideColor,
    );

    // Direction chevrons.
    final chevron = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = guideColor;
    final chevronInset = radius - 12;
    for (var i = 0; i < 4; i++) {
      final angle = i * math.pi / 2;
      final dir = Offset(math.cos(angle), math.sin(angle));
      final normal = Offset(-dir.dy, dir.dx);
      final tip = center + dir * chevronInset;
      final back = tip - dir * 7;
      canvas.drawLine(tip, back + normal * 6, chevron);
      canvas.drawLine(tip, back - normal * 6, chevron);
    }

    // Knob.
    final knobCenter = center + knob.value * travel;
    if (knob.value != Offset.zero) {
      canvas.drawLine(
        center,
        knobCenter,
        Paint()
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = knobColor.withValues(alpha: 0.5),
      );
    }
    canvas.drawCircle(
      knobCenter.translate(0, 3),
      knobRadius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    final knobRect = Rect.fromCircle(center: knobCenter, radius: knobRadius);
    canvas.drawCircle(
      knobCenter,
      knobRadius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: [knobHighlight, knobColor],
        ).createShader(knobRect),
    );
    canvas.drawCircle(
      knobCenter,
      knobRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.25),
    );
  }

  @override
  bool shouldRepaint(_JoystickPainter old) =>
      old.knobRadius != knobRadius ||
      old.travel != travel ||
      old.deadZone != deadZone ||
      old.baseColor != baseColor ||
      old.knobColor != knobColor ||
      old.ringColor != ringColor;
}
