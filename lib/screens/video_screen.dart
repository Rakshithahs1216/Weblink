import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../routes.dart';
import '../services/robot_session.dart';
import '../widgets/remote_video.dart';
import '../widgets/status_chip.dart';
import '../widgets/telemetry_overlay.dart';

/// Full-screen remote video. Attaches to the shared [RobotSession]; leaving the
/// screen keeps the session alive (the joystick uses it) – use Disconnect to
/// end it explicitly.
class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key});

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final session = context.read<RobotSession>();
      if (!session.isBusy) session.connect();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<RobotSession>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Live video'),
        actions: [
          IconButton(
            tooltip: 'Joystick control',
            icon: const Icon(Icons.gamepad_outlined),
            onPressed: () => Navigator.of(context).pushNamed(Routes.joystick),
          ),
          if (session.state != RobotConnectionState.idle)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: session.disconnect,
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect'),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            RemoteVideo(
              renderer: session.renderer,
              placeholder: session.isConnected
                  ? const _CenterMessage(
                      busy: true,
                      text: 'Waiting for the first video frame…',
                    )
                  : null,
            ),
            if (!session.isConnected) Center(child: _StateOverlay(session)),
            Positioned(
              top: 12,
              left: 12,
              child: StatusChip.session(session.state, dense: true),
            ),
            const Positioned(left: 12, bottom: 12, child: TelemetryOverlay()),
          ],
        ),
      ),
    );
  }
}

class _StateOverlay extends StatelessWidget {
  const _StateOverlay(this.session);
  final RobotSession session;

  @override
  Widget build(BuildContext context) {
    switch (session.state) {
      case RobotConnectionState.connecting:
        return const _CenterMessage(busy: true, text: 'Connecting to robot…');
      case RobotConnectionState.failed:
        return _CenterMessage(
          icon: Icons.error_outline,
          iconColor: Theme.of(context).colorScheme.error,
          text: session.error ?? 'Connection failed.',
          action: FilledButton.icon(
            onPressed: session.connect,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        );
      case RobotConnectionState.idle:
        return _CenterMessage(
          icon: Icons.videocam_off_outlined,
          text: 'Disconnected',
          action: FilledButton.icon(
            onPressed: session.connect,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Connect'),
          ),
        );
      case RobotConnectionState.connected:
        return const SizedBox.shrink();
    }
  }
}

class _CenterMessage extends StatelessWidget {
  const _CenterMessage({
    required this.text,
    this.busy = false,
    this.icon,
    this.iconColor,
    this.action,
  });

  final String text;
  final bool busy;
  final IconData? icon;
  final Color? iconColor;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox.square(
              dimension: 36,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.white,
              ),
            )
          else if (icon != null)
            Icon(icon, size: 48, color: iconColor ?? Colors.white70),
          const SizedBox(height: 16),
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: Colors.white),
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}
