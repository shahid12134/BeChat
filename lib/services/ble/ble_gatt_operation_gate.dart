import 'dart:async';

/// Serializes GATT operations on one central link.
///
/// Android exposes one GATT client per physical connection. Probes must not
/// overlap characteristic writes, and a queued write must not start after the
/// link has been closed.
class BleGattOperationGate {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;
  bool _closed = false;

  bool get isBusy => _pending > 0;

  bool get isClosed => _closed;

  Future<T> run<T>(Future<T> Function() operation) {
    if (_closed) {
      return Future<T>.error(
        StateError('The BLE GATT operation gate is closed'),
      );
    }
    _pending++;
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      if (_closed) {
        _pending--;
        completer.completeError(
          StateError('The BLE GATT operation gate is closed'),
        );
        return;
      }
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _pending--;
      }
    });
    return completer.future;
  }

  /// Runs [operation] only when no operation is active or queued.
  ///
  /// Returns `null` when the gate is busy. That is an inconclusive probe, not
  /// a failed health check.
  Future<T>? tryRun<T>(Future<T> Function() operation) {
    if (_closed || isBusy) return null;
    return run(operation);
  }

  void close() {
    _closed = true;
  }
}
