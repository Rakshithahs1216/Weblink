import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/telemetry_hub.dart';
import 'telemetry_card.dart';

/// Compact translucent telemetry strip for use over video.
class TelemetryOverlay extends StatelessWidget {
  const TelemetryOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<TelemetryHub>();
    final t = hub.latest;
    final textStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget item(IconData icon, String text, Color color) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(text, style: textStyle),
        ],
      ),
    );

    return AnimatedOpacity(
      opacity: hub.isStale ? 0.6 : 1,
      duration: const Duration(milliseconds: 300),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            item(
              Icons.speed,
              '${TelemetryFormat.speed(t?.speed)} m/s',
              Colors.white,
            ),
            item(
              Icons.battery_std,
              '${TelemetryFormat.battery(t?.battery)} %',
              TelemetryFormat.batteryColor(context, t?.battery),
            ),
            item(
              Icons.thermostat,
              '${TelemetryFormat.temperature(t?.temperature)} °C',
              TelemetryFormat.temperatureColor(context, t?.temperature),
            ),
          ],
        ),
      ),
    );
  }
}
