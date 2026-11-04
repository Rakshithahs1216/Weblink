import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Renders the remote video track with `contain` fit on black, plus a
/// placeholder until the first frame arrives.
class RemoteVideo extends StatelessWidget {
  const RemoteVideo({super.key, required this.renderer, this.placeholder});

  final RTCVideoRenderer? renderer;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final renderer = this.renderer;
    return ColoredBox(
      color: Colors.black,
      child: renderer == null
          ? Center(child: placeholder)
          : ValueListenableBuilder<RTCVideoValue>(
              valueListenable: renderer,
              builder: (context, value, _) => Stack(
                fit: StackFit.expand,
                children: [
                  RTCVideoView(
                    renderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  ),
                  if (!value.renderVideo && placeholder != null)
                    Center(child: placeholder),
                ],
              ),
            ),
    );
  }
}
