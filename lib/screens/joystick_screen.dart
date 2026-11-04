import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/joystick_command.dart';
import '../services/robot_session.dart';
import '../services/telemetry_hub.dart';
import '../theme.dart';
import '../widgets/joystick.dart';
import '../widgets/remote_video.dart';
import '../widgets/status_chip.dart';
import '../widgets/telemetry_card.dart';

/// Drives the robot over the `control` DataChannel.
///
/// Pan events only update [_axes]; a [Timer] samples it at 20 Hz while the
/// stick is held, and one final zero command is sent on release.
class JoystickScreen extends StatefulWidget {
  const JoystickScreen({super.key});

  @override
  State<JoystickScreen> createState() => _JoystickScreenState();
}

class _JoystickScreenState extends State<JoystickScreen> {
  late final RobotSession _session;
  final ValueNotifier<JoystickAxes> _axes = ValueNotifier(JoystickAxes.zero);
  Timer? _sendTimer;

  @override
  void initState() {
    super.initState();
    _session = context.read<RobotSession>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_session.isBusy) _session.connect();
    });
  }

  void _onStickStart() {
    _sendTimer?.cancel();
    _sendTimer = Timer.periodic(AppConfig.joystickSendInterval, (_) => _send());
  }

  void _onStickChanged(Offset offset) {
    _axes.value = JoystickAxes.fromOffset(offset.dx, offset.dy);
  }

  void _onStickEnd() {
    _stopAndZero();
  }

  /// Cancels the 20 Hz timer and sends the final zero command.
  void _stopAndZero() {
    if (_sendTimer == null) return;
    _sendTimer!.cancel();
    _sendTimer = null;
    _axes.value = JoystickAxes.zero;
    _send();
  }

  void _send() {
    if (!_session.dataChannelOpen) return; // don't burn sequence numbers
    _session.sendJoystick(
      JoystickCommand.fromAxes(
        _axes.value,
        seq: _session.nextSeq(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  void dispose() {
    _stopAndZero(); // never leave the robot driving
    _axes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.select<RobotSession, RobotConnectionState>(
      (s) => s.state,
    );
    final channelOpen = context.select<RobotSession, bool>(
      (s) => s.dataChannelOpen,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Joystick control'),
        actions: [
          if (state != RobotConnectionState.idle)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: _session.disconnect,
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect'),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final landscape = constraints.maxWidth > constraints.maxHeight;
            final stick = LayoutBuilder(
              builder: (context, box) {
                final size = (box.biggest.shortestSide - 24).clamp(
                  140.0,
                  340.0,
                );
                return Center(
                  child: Joystick(
                    size: size,
                    enabled: channelOpen,
                    onStart: _onStickStart,
                    onChanged: _onStickChanged,
                    onEnd: _onStickEnd,
                  ),
                );
              },
            );
            final info = [
              _ConnectionBanner(session: _session),
              const _VideoPreview(),
              _Readout(axes: _axes, session: _session),
            ];

            if (landscape) {
              return Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: _spaced(info),
                    ),
                  ),
                  Expanded(flex: 4, child: stick),
                ],
              );
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * 0.55,
                    ),
                    child: SingleChildScrollView(
                      child: Column(children: _spaced(info)),
                    ),
                  ),
                ),
                Expanded(child: stick),
              ],
            );
          },
        ),
      ),
    );
  }

  static List<Widget> _spaced(List<Widget> children) => [
    for (final child in children) ...[child, const SizedBox(height: 12)],
  ];
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.session});
  final RobotSession session;

  @override
  Widget build(BuildContext context) {
    final state = context.select<RobotSession, RobotConnectionState>(
      (s) => s.state,
    );
    final channelOpen = context.select<RobotSession, bool>(
      (s) => s.dataChannelOpen,
    );
    final error = context.select<RobotSession, String?>((s) => s.error);
    final theme = Theme.of(context);

    final String message;
    Widget? action;
    switch (state) {
      case RobotConnectionState.connected:
        message = channelOpen
            ? 'DataChannel "control" open – drag the stick to drive.'
            : 'Connected – waiting for the control channel…';
      case RobotConnectionState.connecting:
        message = 'Connecting to the robot…';
      case RobotConnectionState.failed:
        message = error ?? 'Connection failed.';
        action = FilledButton.tonalIcon(
          onPressed: session.connect,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
        );
      case RobotConnectionState.idle:
        message = 'Not connected. Commands are not being sent.';
        action = FilledButton.tonalIcon(
          onPressed: session.connect,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Connect'),
        );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusChip.session(state, dense: true),
            const SizedBox(height: 8),
            Text(message, style: theme.textTheme.bodyMedium),
            if (action != null) ...[const SizedBox(height: 8), action],
          ],
        ),
      ),
    );
  }
}

class _VideoPreview extends StatelessWidget {
  const _VideoPreview();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<RobotSession>();
    if (!session.isConnected || !session.hasRemoteVideo) {
      return const SizedBox.shrink();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: RemoteVideo(renderer: session.renderer),
        ),
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({required this.axes, required this.session});

  final ValueListenable<JoystickAxes> axes;
  final RobotSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final label = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final echo = context.select<TelemetryHub, (double, double)?>(
      (h) => h.latest == null ? null : (h.latest!.linear, h.latest!.angular),
    );

    Widget metric(String name, String value, {TextStyle? style}) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: label),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: style ?? mono),
          ),
        ],
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<JoystickAxes>(
              valueListenable: axes,
              builder: (context, value, _) => Row(
                children: [
                  metric('Linear', TelemetryFormat.axis(value.linear)),
                  metric('Angular', TelemetryFormat.axis(value.angular)),
                ],
              ),
            ),
            const Divider(height: 24),
            ValueListenableBuilder<CommandStats>(
              valueListenable: session.commandStats,
              builder: (context, stats, _) => Row(
                children: [
                  metric(
                    'Sent',
                    '${stats.sent}',
                    style: theme.textTheme.titleMedium,
                  ),
                  metric(
                    'Last seq',
                    '${stats.lastSeq}',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.sync_alt,
                  size: 16,
                  color: echo == null
                      ? StatusColors.of(context).neutral
                      : StatusColors.of(context).success,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    echo == null
                        ? 'Robot echo: waiting for telemetry'
                        : 'Robot echo  linear ${TelemetryFormat.axis(echo.$1)}'
                              '  angular ${TelemetryFormat.axis(echo.$2)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
