import 'dart:async';

enum BlePresenceProbeStatus { signal, failed, skipped, stuck }

class BlePresenceProbeResult {
  const BlePresenceProbeResult._(this.status, [this.rssi]);

  const BlePresenceProbeResult.signal(int rssi)
    : this._(BlePresenceProbeStatus.signal, rssi);

  const BlePresenceProbeResult.failed() : this._(BlePresenceProbeStatus.failed);

  const BlePresenceProbeResult.skipped()
    : this._(BlePresenceProbeStatus.skipped);

  const BlePresenceProbeResult.stuck() : this._(BlePresenceProbeStatus.stuck);

  final BlePresenceProbeStatus status;
  final int? rssi;
}

enum BlePresenceLossReason { failed, stuck }

typedef BlePresenceProbe = Future<BlePresenceProbeResult> Function();
typedef BlePresenceSignalCallback = void Function(int rssi);
typedef BlePresenceLostCallback =
    Future<void> Function(BlePresenceLossReason reason);

class BlePresenceMonitor {
  BlePresenceMonitor({
    required BlePresenceProbe probe,
    required BlePresenceSignalCallback onSignal,
    required BlePresenceLostCallback onLost,
    required this.foregroundInterval,
    required this.backgroundInterval,
    this.probeTimeout = const Duration(seconds: 5),
    this.maxConsecutiveFailures = 2,
  }) : _probe = probe,
       _onSignal = onSignal,
       _onLost = onLost;

  final BlePresenceProbe _probe;
  final BlePresenceSignalCallback _onSignal;
  final BlePresenceLostCallback _onLost;
  final Duration foregroundInterval;
  final Duration backgroundInterval;
  final Duration probeTimeout;
  final int maxConsecutiveFailures;

  Timer? _timer;
  Future<void>? _activeCheck;
  int _generation = 0;
  int _failures = 0;
  bool _running = false;
  bool _foreground = true;

  bool get isRunning => _running;

  int get failureCount => _failures;

  bool get isForeground => _foreground;

  Duration get interval =>
      _foreground ? foregroundInterval : backgroundInterval;

  void start({required bool foreground}) {
    _generation++;
    _failures = 0;
    _foreground = foreground;
    _running = true;
    _timer?.cancel();
    _scheduleNext();
  }

  void updateForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!_running) return;
    _timer?.cancel();
    _scheduleNext();
  }

  Future<void> checkNow() {
    if (!_running) return Future<void>.value();
    final active = _activeCheck;
    if (active != null) return active;
    _timer?.cancel();
    _timer = null;
    final check = _runCheck();
    _activeCheck = check;
    return check.whenComplete(() {
      if (identical(_activeCheck, check)) {
        _activeCheck = null;
      }
    });
  }

  void stop() {
    _running = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleNext() {
    if (!_running) return;
    _timer?.cancel();
    _timer = Timer(interval, () {
      unawaited(checkNow());
    });
  }

  Future<void> _runCheck() async {
    final generation = _generation;
    BlePresenceProbeResult result;
    try {
      result = await _probe().timeout(probeTimeout);
    } on TimeoutException {
      if (!_running || generation != _generation) return;
      _stopAfterLoss();
      await _onLost(BlePresenceLossReason.stuck);
      return;
    } catch (_) {
      result = const BlePresenceProbeResult.failed();
    }
    if (!_running || generation != _generation) return;

    switch (result.status) {
      case BlePresenceProbeStatus.signal:
        _failures = 0;
        final rssi = result.rssi;
        if (rssi != null) _onSignal(rssi);
        break;
      case BlePresenceProbeStatus.skipped:
        break;
      case BlePresenceProbeStatus.failed:
        _failures++;
        if (_failures >= maxConsecutiveFailures) {
          _stopAfterLoss();
          await _onLost(BlePresenceLossReason.failed);
          return;
        }
        break;
      case BlePresenceProbeStatus.stuck:
        _stopAfterLoss();
        await _onLost(BlePresenceLossReason.stuck);
        return;
    }

    if (_running) _scheduleNext();
  }

  void _stopAfterLoss() {
    _running = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
  }
}
