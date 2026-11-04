import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/telemetry_hub.dart';
import '../widgets/sparkline.dart';
import '../widgets/status_chip.dart';
import '../widgets/telemetry_card.dart';

/// Detailed telemetry with a rolling ~60-sample history per metric.
class TelemetryScreen extends StatelessWidget {
  const TelemetryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<TelemetryHub>();
    final t = hub.latest;
    final theme = Theme.of(context);

    final batteryColor = TelemetryFormat.batteryColor(context, t?.battery);
    final tempColor = TelemetryFormat.temperatureColor(context, t?.temperature);
    final speedColor = TelemetryFormat.speedColor(context);

    final cards = <Widget>[
      TelemetryCard(
        icon: Icons.speed,
        label: 'Speed',
        value: TelemetryFormat.speed(t?.speed),
        unit: 'm/s',
        color: speedColor,
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: t == null
                    ? 0
                    : (t.speed / TelemetryFormat.maxSpeed).clamp(0.0, 1.0),
                minHeight: 6,
                color: speedColor,
              ),
            ),
            const SizedBox(height: 12),
            Sparkline(
              values: hub.speedHistory,
              color: speedColor,
              min: 0,
              max: TelemetryFormat.maxSpeed,
            ),
          ],
        ),
      ),
      TelemetryCard(
        icon: Icons.battery_charging_full,
        label: 'Battery',
        value: TelemetryFormat.battery(t?.battery),
        unit: '%',
        color: batteryColor,
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: t == null ? 0 : (t.battery / 100).clamp(0.0, 1.0),
                minHeight: 6,
                color: batteryColor,
              ),
            ),
            const SizedBox(height: 12),
            Sparkline(values: hub.batteryHistory, color: batteryColor),
          ],
        ),
      ),
      TelemetryCard(
        icon: Icons.thermostat,
        label: 'Temperature',
        value: TelemetryFormat.temperature(t?.temperature),
        unit: '°C',
        color: tempColor,
        footer: Sparkline(values: hub.temperatureHistory, color: tempColor),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Telemetry')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusChip.telemetry(
                      source: hub.source,
                      stale: hub.isStale,
                      socketState: hub.socketState,
                    ),
                    if (hub.lastUpdate != null)
                      _LastUpdated(time: hub.lastUpdate!),
                  ],
                ),
                const SizedBox(height: 16),
                if (t == null)
                  const _EmptyState()
                else ...[
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 720
                          ? 3
                          : constraints.maxWidth >= 480
                          ? 2
                          : 1;
                      final width =
                          (constraints.maxWidth - 12 * (columns - 1)) / columns;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final card in cards)
                            SizedBox(width: width, child: card),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.sync_alt),
                      title: const Text('Last command applied by robot'),
                      subtitle: Text(
                        'linear ${TelemetryFormat.axis(t.linear)}   '
                        'angular ${TelemetryFormat.axis(t.angular)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'History shows the last ${hub.speedHistory.length} '
                    'samples (5 Hz).',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Updated 14:02:31 · 0 s ago" – ticks every second on its own so the age
/// stays correct even when no samples arrive.
class _LastUpdated extends StatefulWidget {
  const _LastUpdated({required this.time});
  final DateTime time;

  @override
  State<_LastUpdated> createState() => _LastUpdatedState();
}

class _LastUpdatedState extends State<_LastUpdated> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final t = widget.time;
    final age = DateTime.now().difference(t).inSeconds;
    return Text(
      'Updated ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}'
      ' · ${age <= 0 ? 'just now' : '$age s ago'}',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Column(
        children: [
          const SizedBox.square(
            dimension: 32,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 16),
          Text('Waiting for telemetry…', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Samples arrive over the WebRTC DataChannel when connected, '
            'otherwise over the telemetry WebSocket.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
