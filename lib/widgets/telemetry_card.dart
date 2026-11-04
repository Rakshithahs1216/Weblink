import 'package:flutter/material.dart';

import '../theme.dart';

/// A metric tile: icon, label, big value + unit, and an optional footer
/// (progress bar, sparkline…).
class TelemetryCard extends StatelessWidget {
  const TelemetryCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    this.footer,
    this.compact = false,
  });

  final IconData icon;
  final String label;

  /// Pre-formatted value, or `–` when unknown.
  final String value;
  final String unit;
  final Color color;
  final Widget? footer;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle =
        (compact ? theme.textTheme.titleLarge : theme.textTheme.displaySmall)
            ?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            );

    return Semantics(
      label: '$label $value $unit',
      container: true,
      excludeSemantics: true,
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: compact ? 16 : 20, color: color),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 8 : 12),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: value, style: valueStyle),
                      TextSpan(
                        text: ' $unit',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (footer != null) ...[
                SizedBox(height: compact ? 8 : 12),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared formatting and colour rules for the three metrics.
abstract final class TelemetryFormat {
  static const double maxSpeed = 1.5;

  static String speed(double? v) => v == null ? '–' : v.toStringAsFixed(2);
  static String battery(double? v) => v == null ? '–' : v.toStringAsFixed(1);
  static String temperature(double? v) =>
      v == null ? '–' : v.toStringAsFixed(1);
  static String axis(double? v) {
    if (v == null) return '–';
    final s = v.toStringAsFixed(3);
    return v > 0 ? '+$s' : (v == 0 ? ' 0.000' : s);
  }

  static Color batteryColor(BuildContext context, double? percent) {
    final c = StatusColors.of(context);
    if (percent == null) return c.neutral;
    if (percent > 50) return c.success;
    if (percent > 20) return c.warning;
    return c.danger;
  }

  static Color temperatureColor(BuildContext context, double? celsius) {
    final c = StatusColors.of(context);
    if (celsius == null) return c.neutral;
    if (celsius < 40) return Theme.of(context).colorScheme.tertiary;
    if (celsius < 50) return c.warning;
    return c.danger;
  }

  static Color speedColor(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
}
