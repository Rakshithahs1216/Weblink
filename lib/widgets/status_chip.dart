import 'package:flutter/material.dart';

import '../models/telemetry.dart';
import '../services/robot_session.dart';
import '../services/telemetry_socket.dart';
import '../theme.dart';

enum StatusTone { ok, busy, warning, error, neutral }

/// Compact pill showing a coloured status dot (or spinner) and a label.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
    this.dense = false,
  });

  /// Status of the shared WebRTC session.
  factory StatusChip.session(RobotConnectionState state, {bool dense = false}) {
    return switch (state) {
      RobotConnectionState.idle => StatusChip(
        label: 'WebRTC idle',
        tone: StatusTone.neutral,
        icon: Icons.videocam_off_outlined,
        dense: dense,
      ),
      RobotConnectionState.connecting => StatusChip(
        label: 'Connecting…',
        tone: StatusTone.busy,
        dense: dense,
      ),
      RobotConnectionState.connected => StatusChip(
        label: 'WebRTC connected',
        tone: StatusTone.ok,
        dense: dense,
      ),
      RobotConnectionState.failed => StatusChip(
        label: 'Connection failed',
        tone: StatusTone.error,
        icon: Icons.error_outline,
        dense: dense,
      ),
    };
  }

  /// Status of the telemetry feed (source + liveness).
  factory StatusChip.telemetry({
    required TelemetrySource? source,
    required bool stale,
    required SocketLinkState socketState,
    bool dense = false,
  }) {
    if (source != null && !stale) {
      return StatusChip(
        label: 'Telemetry · ${source.label}',
        tone: StatusTone.ok,
        dense: dense,
      );
    }
    return switch (socketState) {
      SocketLinkState.connecting || SocketLinkState.reconnecting => StatusChip(
        label: 'Telemetry connecting…',
        tone: StatusTone.busy,
        dense: dense,
      ),
      SocketLinkState.connected => StatusChip(
        label: 'Waiting for telemetry',
        tone: StatusTone.warning,
        dense: dense,
      ),
      SocketLinkState.stopped => StatusChip(
        label: source == null ? 'Telemetry offline' : 'Telemetry stale',
        tone: source == null ? StatusTone.neutral : StatusTone.warning,
        icon: Icons.sensors_off_outlined,
        dense: dense,
      ),
    };
  }

  final String label;
  final StatusTone tone;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = StatusColors.of(context);
    final color = switch (tone) {
      StatusTone.ok => status.success,
      StatusTone.busy => scheme.primary,
      StatusTone.warning => status.warning,
      StatusTone.error => status.danger,
      StatusTone.neutral => status.neutral,
    };
    final indicatorSize = dense ? 10.0 : 12.0;

    final Widget indicator;
    if (tone == StatusTone.busy) {
      indicator = SizedBox.square(
        dimension: indicatorSize,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );
    } else if (icon != null) {
      indicator = Icon(icon, size: indicatorSize + 4, color: color);
    } else {
      indicator = Container(
        width: indicatorSize - 2,
        height: indicatorSize - 2,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6),
          ],
        ),
      );
    }

    return Semantics(
      label: 'Status: $label',
      container: true,
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 12,
          vertical: dense ? 4 : 6,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            indicator,
            SizedBox(width: dense ? 6 : 8),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style:
                    (dense
                            ? Theme.of(context).textTheme.labelSmall
                            : Theme.of(context).textTheme.labelMedium)
                        ?.copyWith(color: color, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
