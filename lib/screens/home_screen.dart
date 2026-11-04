import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/telemetry.dart';
import '../routes.dart';
import '../services/auth_service.dart';
import '../services/robot_session.dart';
import '../services/telemetry_hub.dart';
import '../services/telemetry_socket.dart';
import '../widgets/status_chip.dart';
import '../widgets/telemetry_card.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Weblink'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: () => confirmLogout(context),
              icon: const Icon(Icons.logout),
              label: const Text('Log out'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: const [
                _GreetingCard(),
                SizedBox(height: 24),
                _SectionTitle('Controls'),
                SizedBox(height: 12),
                _Controls(),
                SizedBox(height: 24),
                _SectionTitle('Live telemetry'),
                SizedBox(height: 12),
                _TelemetrySummary(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for confirmation, then logs out (which tears down WebRTC + sockets
/// and returns to Login via the app-level auth listener).
Future<void> confirmLogout(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.logout),
      title: const Text('Log out?'),
      content: const Text(
        'This ends the video stream, joystick control and telemetry, and '
        'removes your saved session from this device.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Log out'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await context.read<AuthService>().logout();
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.titleMedium
        ?.copyWith(fontWeight: FontWeight.w700),
  );
}

class _GreetingCard extends StatelessWidget {
  const _GreetingCard();

  static String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.select<AuthService, ({String name, String username})?>(
      (a) => a.user == null
          ? null
          : (name: a.user!.displayName, username: a.user!.username),
    );
    final session = context.watch<RobotSession>();
    // Select only what the chips need so 5 Hz telemetry doesn't rebuild this.
    final (source, stale, socketState) = context
        .select<TelemetryHub, (TelemetrySource?, bool, SocketLinkState)>(
          (h) => (h.source, h.isStale, h.socketState),
        );

    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_greeting()},',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              user?.name ?? '',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (user != null)
              Text(
                '@${user.username}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusChip.session(session.state),
                StatusChip.telemetry(
                  source: source,
                  stale: stale,
                  socketState: socketState,
                ),
                if (session.state != RobotConnectionState.idle)
                  TextButton.icon(
                    onPressed: session.disconnect,
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text('Disconnect'),
                  ),
              ],
            ),
            if (session.state == RobotConnectionState.failed &&
                session.error != null) ...[
              const SizedBox(height: 8),
              Text(
                session.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    final connected = context.select<RobotSession, bool>((s) => s.isConnected);
    final tiles = [
      _ActionTile(
        icon: Icons.videocam_outlined,
        title: connected ? 'Open WebRTC Stream' : 'Start WebRTC Stream',
        subtitle: 'Live video from the robot camera',
        primary: true,
        onTap: () => Navigator.of(context).pushNamed(Routes.video),
      ),
      _ActionTile(
        icon: Icons.gamepad_outlined,
        title: 'Open Joystick Control',
        subtitle: 'Drive over the WebRTC DataChannel',
        onTap: () => Navigator.of(context).pushNamed(Routes.joystick),
      ),
      _ActionTile(
        icon: Icons.monitor_heart_outlined,
        title: 'Telemetry',
        subtitle: 'Speed, battery and temperature history',
        onTap: () => Navigator.of(context).pushNamed(Routes.telemetry),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          return Column(
            children: [
              for (final tile in tiles) ...[tile, const SizedBox(height: 12)],
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: tiles[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = primary ? scheme.primary : scheme.surfaceContainerHigh;
    final foreground = primary ? scheme.onPrimary : scheme.onSurface;

    return Semantics(
      button: true,
      label: title,
      hint: subtitle,
      excludeSemantics: true,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: foreground.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: foreground),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: foreground.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: foreground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TelemetrySummary extends StatelessWidget {
  const _TelemetrySummary();

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<TelemetryHub>();
    final t = hub.latest;
    final cards = [
      TelemetryCard(
        compact: true,
        icon: Icons.speed,
        label: 'Speed',
        value: TelemetryFormat.speed(t?.speed),
        unit: 'm/s',
        color: TelemetryFormat.speedColor(context),
      ),
      TelemetryCard(
        compact: true,
        icon: Icons.battery_charging_full,
        label: 'Battery',
        value: TelemetryFormat.battery(t?.battery),
        unit: '%',
        color: TelemetryFormat.batteryColor(context, t?.battery),
        footer: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: t == null ? 0 : (t.battery / 100).clamp(0.0, 1.0),
            minHeight: 6,
            color: TelemetryFormat.batteryColor(context, t?.battery),
          ),
        ),
      ),
      TelemetryCard(
        compact: true,
        icon: Icons.thermostat,
        label: 'Temperature',
        value: TelemetryFormat.temperature(t?.temperature),
        unit: '°C',
        color: TelemetryFormat.temperatureColor(context, t?.temperature),
      ),
    ];

    return Semantics(
      button: true,
      label: 'Open telemetry details',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.of(context).pushNamed(Routes.telemetry),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(child: cards[i]),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t == null
                  ? 'Waiting for telemetry from the robot…'
                  : 'Source: ${hub.source?.label ?? '–'}'
                        '${hub.isStale ? ' (stale)' : ''} · tap for details',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
