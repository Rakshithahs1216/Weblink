import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config.dart';
import '../models/joystick_command.dart';
import '../models/signaling_message.dart';
import '../models/telemetry.dart';
import 'auth_service.dart';
import 'signaling_client.dart';

enum RobotConnectionState { idle, connecting, connected, failed }

/// Counters for the joystick readout. Published through a separate
/// [ValueListenable] so 20 Hz sends don't rebuild every session listener.
@immutable
class CommandStats {
  const CommandStats({this.sent = 0, this.lastSeq = 0, this.lastCommand});

  final int sent;
  final int lastSeq;
  final JoystickCommand? lastCommand;
}

/// The app's single WebRTC session: one [RTCPeerConnection] with a recvonly
/// video transceiver and the `control` DataChannel, negotiated over
/// `/ws/signaling` (ARCHITECTURE.md §3–4).
///
/// The session outlives individual screens: the video and joystick screens
/// both attach to it, and only [disconnect] (or logout) tears it down.
class RobotSession extends ChangeNotifier {
  RobotSession({
    required this._credentials,
    required this._onUnauthorized,
    required this._verifySession,
    this._connector = defaultWebSocketConnector,
    this.connectTimeout = AppConfig.webRtcConnectTimeout,
  });

  final SessionCredentials? Function() _credentials;
  final Future<void> Function() _onUnauthorized;
  final Future<bool> Function() _verifySession;
  final WebSocketConnector _connector;
  final Duration connectTimeout;

  RobotConnectionState _state = RobotConnectionState.idle;
  String? _error;
  bool _dataChannelOpen = false;
  bool _hasRemoteVideo = false;

  RTCVideoRenderer? _renderer;
  bool _rendererReady = false;
  SignalingClient? _signaling;
  RTCPeerConnection? _pc;
  RTCDataChannel? _dataChannel;
  Timer? _connectTimer;

  bool _remoteDescriptionSet = false;
  bool _offerSent = false;
  final List<IceCandidateData> _pendingLocalIce = [];
  final List<RTCIceCandidate> _pendingRemoteIce = [];

  /// Incremented on every connect/disconnect so callbacks from a previous
  /// peer connection are ignored.
  int _generation = 0;
  int _seq = 0;
  bool _disposed = false;

  final StreamController<Telemetry> _telemetry =
      StreamController<Telemetry>.broadcast();
  final ValueNotifier<CommandStats> _commandStats = ValueNotifier(
    const CommandStats(),
  );

  RobotConnectionState get state => _state;
  bool get isConnected => _state == RobotConnectionState.connected;
  bool get isBusy =>
      _state == RobotConnectionState.connecting ||
      _state == RobotConnectionState.connected;

  /// Human-readable reason for the last failure / interruption.
  String? get error => _error;

  /// True once the `control` DataChannel is open (joystick can send).
  bool get dataChannelOpen => _dataChannelOpen;

  /// True once a remote video track has been attached to [renderer].
  bool get hasRemoteVideo => _hasRemoteVideo;

  /// Renderer holding the remote video stream; null until the first connect.
  RTCVideoRenderer? get renderer => _rendererReady ? _renderer : null;

  /// Telemetry received on the DataChannel.
  Stream<Telemetry> get telemetry => _telemetry.stream;

  ValueListenable<CommandStats> get commandStats => _commandStats;

  /// Starts a new session. No-op if one is already connecting/connected.
  Future<void> connect() async {
    if (_disposed || isBusy) return;
    final credentials = _credentials();
    if (credentials == null) {
      _fail('You are not logged in.');
      return;
    }

    final generation = ++_generation;
    _error = null;
    _setState(RobotConnectionState.connecting);
    bool isCurrent() => generation == _generation && !_disposed;

    // 1. Signaling socket (JWT-gated).
    final signaling = SignalingClient(
      uri: AppConfig.webSocketUri(
        credentials.serverUrl,
        '/ws/signaling',
        credentials.token,
      ),
      connector: _connector,
      onMessage: (message) {
        if (isCurrent()) _onSignalingMessage(message, isCurrent);
      },
      onClosed: (code, reason) {
        if (isCurrent()) _onSignalingClosed(code, reason);
      },
    );
    _signaling = signaling;

    // Covers the whole attempt, including the socket handshake, which can
    // hang indefinitely on an unreachable host.
    _connectTimer?.cancel();
    _connectTimer = Timer(connectTimeout, () {
      if (isCurrent() && _state == RobotConnectionState.connecting) {
        _abort('Timed out connecting to the robot.');
      }
    });

    try {
      await signaling.connect();
    } catch (_) {
      if (!isCurrent()) return;
      await _teardown();
      // A rejected token closes the socket before `accept`, which most
      // clients surface as a failed handshake rather than code 4401, so ask
      // the REST API whether the token is still valid.
      if (!await _verifySession()) return;
      if (isCurrent()) {
        _fail(
          "Couldn't open the signaling connection to "
          '${credentials.serverUrl}. Is the backend running?',
        );
      }
      return;
    }
    if (!isCurrent()) return;

    // 2. Peer connection: recvonly video + "control" DataChannel, then offer.
    try {
      if (!_rendererReady) {
        _renderer ??= RTCVideoRenderer();
        await _renderer!.initialize();
        _rendererReady = true;
      }

      final pc = await createPeerConnection({
        'iceServers': [
          {'urls': AppConfig.stunServer},
        ],
        'sdpSemantics': 'unified-plan',
      });
      if (!isCurrent()) {
        await pc.close();
        return;
      }
      _pc = pc;
      pc.onIceCandidate = (candidate) {
        if (isCurrent()) _onLocalIceCandidate(candidate);
      };
      pc.onConnectionState = (s) {
        if (isCurrent()) _onPeerConnectionState(s);
      };
      pc.onIceConnectionState = (s) {
        if (isCurrent()) _onIceConnectionState(s);
      };
      pc.onTrack = (event) {
        if (isCurrent()) _onTrack(event, isCurrent);
      };

      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      final channel = await pc.createDataChannel(
        AppConfig.controlChannelLabel,
        RTCDataChannelInit()..ordered = true, // ordered + reliable (default)
      );
      _attachDataChannel(channel, isCurrent);

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      if (!isCurrent()) return;
      signaling.send(OfferMessage(offer.sdp!));
      _offerSent = true;
      _pendingLocalIce.forEach(_sendLocalIce);
      _pendingLocalIce.clear();
    } catch (e) {
      if (!isCurrent()) return;
      await _teardown();
      _fail('Could not start the WebRTC session: $e');
    }
  }

  /// Ends the session (sends `bye`, closes the peer connection and socket).
  Future<void> disconnect() async {
    _generation++;
    _error = null;
    _signaling?.send(const ByeMessage());
    await _teardown();
    _setState(RobotConnectionState.idle);
  }

  /// Next joystick sequence number (monotonic for the app's lifetime).
  int nextSeq() => ++_seq;

  /// Sends [command] on the DataChannel. Returns false if it isn't open.
  bool sendJoystick(JoystickCommand command) {
    final channel = _dataChannel;
    if (!_dataChannelOpen || channel == null) return false;
    try {
      channel.send(RTCDataChannelMessage(jsonEncode(command.toJson())));
    } catch (e) {
      debugPrint('DataChannel send failed: $e');
      return false;
    }
    final stats = _commandStats.value;
    _commandStats.value = CommandStats(
      sent: stats.sent + 1,
      lastSeq: command.seq,
      lastCommand: command,
    );
    return true;
  }

  // ---------------------------------------------------------------- signaling

  Future<void> _onSignalingMessage(
    SignalingMessage message,
    bool Function() isCurrent,
  ) async {
    // Disconnect/reconnect can happen while we await; re-check after each
    // await so a stale answer never touches (or aborts) a newer session.
    final pc = _pc;
    switch (message) {
      case AnswerMessage(:final sdp):
        if (pc == null) return;
        try {
          await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        } catch (e) {
          if (isCurrent()) _abort('The robot sent an invalid answer: $e');
          return;
        }
        if (!isCurrent()) return;
        _remoteDescriptionSet = true;
        // Later candidates go straight to the pc, so take the queue now;
        // teardown may clear the list while we await.
        final pending = List.of(_pendingRemoteIce);
        _pendingRemoteIce.clear();
        for (final candidate in pending) {
          await pc.addCandidate(candidate).catchError((Object e) {
            debugPrint('addCandidate failed: $e');
          });
          if (!isCurrent()) return;
        }
      case IceMessage(:final candidate):
        final ice = RTCIceCandidate(
          candidate.candidate,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        );
        if (pc != null && _remoteDescriptionSet) {
          await pc.addCandidate(ice).catchError((Object e) {
            debugPrint('addCandidate failed: $e');
          });
        } else {
          _pendingRemoteIce.add(ice);
        }
      case ErrorMessage(:final message):
        // Most server errors are per-message (e.g. one bad ICE candidate)
        // and the socket stays open. Fatal ones are followed by the server
        // closing the socket, which _onSignalingClosed handles; otherwise
        // the pc state or the connect timeout ends a stuck attempt.
        debugPrint('Signaling error from server: $message');
        _error = 'Server error: $message';
        _notify();
      case OfferMessage() || ByeMessage() || UnknownSignalingMessage():
        break; // not expected from the server
    }
  }

  Future<void> _onSignalingClosed(int? code, String? reason) async {
    _generation++;
    await _teardown();
    if (code == AppConfig.unauthorizedCloseCode) {
      _setState(RobotConnectionState.idle);
      await _onUnauthorized();
      return;
    }
    // The server closes the peer connection together with the socket.
    _fail('Connection to the robot was closed${_describeClose(code, reason)}.');
  }

  void _onLocalIceCandidate(RTCIceCandidate candidate) {
    final value = candidate.candidate;
    if (value == null || value.isEmpty) return; // end-of-candidates
    final data = IceCandidateData(
      candidate: value,
      sdpMid: candidate.sdpMid,
      sdpMLineIndex: candidate.sdpMLineIndex,
    );
    if (_offerSent) {
      _sendLocalIce(data);
    } else {
      _pendingLocalIce.add(data);
    }
  }

  void _sendLocalIce(IceCandidateData data) =>
      _signaling?.send(IceMessage(data));

  // ------------------------------------------------------------ peer + media

  void _onPeerConnectionState(RTCPeerConnectionState s) {
    switch (s) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _markConnected();
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _abort('The peer connection failed (network or firewall issue).');
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _error = 'Connection interrupted – trying to recover…';
        _notify();
      default:
        break;
    }
  }

  /// Fallback for platforms that don't emit `connectionstatechange`.
  void _onIceConnectionState(RTCIceConnectionState s) {
    switch (s) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _markConnected();
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        _abort('ICE negotiation failed (network or firewall issue).');
      default:
        break;
    }
  }

  void _markConnected() {
    _connectTimer?.cancel();
    _error = null;
    _setState(RobotConnectionState.connected);
  }

  Future<void> _onTrack(RTCTrackEvent event, bool Function() isCurrent) async {
    if (event.track.kind != 'video') return;
    final MediaStream stream;
    if (event.streams.isNotEmpty) {
      stream = event.streams.first;
    } else {
      stream = await createLocalMediaStream('weblink-remote');
      if (isCurrent()) await stream.addTrack(event.track);
      if (!isCurrent()) {
        await stream.dispose(); // went stale during either await
        return;
      }
    }
    final renderer = _renderer;
    if (renderer == null || !isCurrent()) return;
    renderer.srcObject = stream;
    _hasRemoteVideo = true;
    _notify();
  }

  void _attachDataChannel(RTCDataChannel channel, bool Function() isCurrent) {
    _dataChannel = channel;
    channel.onDataChannelState = (s) {
      if (!isCurrent()) return;
      final open = s == RTCDataChannelState.RTCDataChannelOpen;
      if (open != _dataChannelOpen) {
        _dataChannelOpen = open;
        _notify();
      }
    };
    channel.onMessage = (message) {
      if (!isCurrent() || message.isBinary) return;
      final sample = Telemetry.tryParse(message.text);
      if (sample != null && !_telemetry.isClosed) _telemetry.add(sample);
    };
  }

  // ------------------------------------------------------------------ helpers

  Future<void> _teardown() async {
    _connectTimer?.cancel();
    _connectTimer = null;
    final channel = _dataChannel;
    final pc = _pc;
    final signaling = _signaling;
    _dataChannel = null;
    _pc = null;
    _signaling = null;
    _dataChannelOpen = false;
    _hasRemoteVideo = false;
    _remoteDescriptionSet = false;
    _offerSent = false;
    _pendingLocalIce.clear();
    _pendingRemoteIce.clear();
    if (_rendererReady) _renderer?.srcObject = null;

    try {
      await channel?.close();
    } catch (_) {}
    try {
      await pc?.close();
      await pc?.dispose();
    } catch (_) {}
    await signaling?.close();
  }

  /// Fails the current attempt from inside a callback: invalidates the
  /// generation so late events from the dying connection are ignored.
  void _abort(String message) {
    _generation++;
    _teardown();
    _fail(message);
  }

  void _fail(String message) {
    _error = message;
    _setState(RobotConnectionState.failed);
  }

  void _setState(RobotConnectionState next) {
    if (_state == next) {
      _notify();
      return;
    }
    _state = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _describeClose(int? code, String? reason) {
    if (reason != null && reason.isNotEmpty) return ': $reason';
    if (code != null) return ' (code $code)';
    return '';
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _teardown().whenComplete(() {
      if (_rendererReady) _renderer?.dispose();
    });
    _telemetry.close();
    _commandStats.dispose();
    super.dispose();
  }
}
