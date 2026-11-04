import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/telemetry.dart';
import 'telemetry_socket.dart';

/// Merges the two telemetry sources into one view model for the UI.
///
/// * DataChannel samples (WebRTC connected) are preferred. While they are
///   flowing the telemetry WebSocket is closed to save bandwidth.
/// * When DataChannel samples stop for [staleAfter] (or WebRTC was never
///   started) the WebSocket is (re)opened as the fallback source.
///
/// Keeps the last [historyLength] samples of each metric for sparklines.
class TelemetryHub extends ChangeNotifier {
  TelemetryHub({
    required Stream<Telemetry> dataChannelSamples,
    required this.socket,
    this.historyLength = AppConfig.telemetryHistoryLength,
    this.staleAfter = AppConfig.telemetryStaleAfter,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _dcSubscription = dataChannelSamples.listen(
      (s) => _onSample(s, TelemetrySource.dataChannel),
    );
    _wsSubscription = socket.samples.listen(
      (s) => _onSample(s, TelemetrySource.webSocket),
    );
    socket.addListener(notifyListeners);
  }

  final TelemetrySocket socket;
  final int historyLength;
  final Duration staleAfter;
  final DateTime Function() _clock;

  late final StreamSubscription<Telemetry> _dcSubscription;
  late final StreamSubscription<Telemetry> _wsSubscription;
  Timer? _ticker;
  bool _started = false;

  Telemetry? _latest;
  TelemetrySource? _source;
  DateTime? _lastUpdate;
  DateTime? _lastDataChannelAt;
  bool _wasStale = true;

  final ListQueue<Telemetry> _history = ListQueue<Telemetry>();
  List<double> _speedHistory = const [];
  List<double> _batteryHistory = const [];
  List<double> _temperatureHistory = const [];

  Telemetry? get latest => _latest;
  TelemetrySource? get source => _source;

  /// Local time the latest sample was received (device clocks may differ
  /// from the server's `ts`).
  DateTime? get lastUpdate => _lastUpdate;

  bool get isStale =>
      _lastUpdate == null || _clock().difference(_lastUpdate!) > staleAfter;

  SocketLinkState get socketState => socket.state;

  /// Immutable snapshots; a new list instance is created per sample so
  /// painters can cheaply detect changes by identity.
  List<double> get speedHistory => _speedHistory;
  List<double> get batteryHistory => _batteryHistory;
  List<double> get temperatureHistory => _temperatureHistory;

  void start() {
    if (_started) return;
    _started = true;
    socket.start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<void> stop() async {
    _started = false;
    _ticker?.cancel();
    _ticker = null;
    await socket.stop();
    _latest = null;
    _source = null;
    _lastUpdate = null;
    _lastDataChannelAt = null;
    _wasStale = true;
    _history.clear();
    _rebuildSnapshots();
    notifyListeners();
  }

  bool _dataChannelFresh(DateTime now) =>
      _lastDataChannelAt != null &&
      now.difference(_lastDataChannelAt!) <= staleAfter;

  void _onSample(Telemetry sample, TelemetrySource source) {
    if (!_started) return;
    final now = _clock();
    if (source == TelemetrySource.dataChannel) {
      _lastDataChannelAt = now;
      if (socket.isRunning) socket.stop();
    } else if (_dataChannelFresh(now)) {
      return; // DataChannel wins while it is live
    }

    _latest = sample;
    _source = source;
    _lastUpdate = now;
    _wasStale = false;
    _history.addLast(sample);
    while (_history.length > historyLength) {
      _history.removeFirst();
    }
    _rebuildSnapshots();
    notifyListeners();
  }

  void _tick() {
    if (!_started) return;
    final now = _clock();
    if (!_dataChannelFresh(now) && !socket.isRunning) socket.start();
    final stale = isStale;
    if (stale != _wasStale) {
      _wasStale = stale;
      notifyListeners();
    }
  }

  void _rebuildSnapshots() {
    _speedHistory = List.unmodifiable(_history.map((t) => t.speed));
    _batteryHistory = List.unmodifiable(_history.map((t) => t.battery));
    _temperatureHistory = List.unmodifiable(_history.map((t) => t.temperature));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _dcSubscription.cancel();
    _wsSubscription.cancel();
    socket.removeListener(notifyListeners);
    super.dispose();
  }
}
