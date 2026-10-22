import 'dart:async';

import 'package:bechat/services/ble/ble_presence_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two completed failures report the link as lost', () async {
    final lost = Completer<BlePresenceLossReason>();
    var probes = 0;
    final monitor = BlePresenceMonitor(
      probe: () async {
        probes++;
        return const BlePresenceProbeResult.failed();
      },
      onSignal: (_) {},
      onLost: (reason) async {
        lost.complete(reason);
      },
      foregroundInterval: const Duration(milliseconds: 5),
      backgroundInterval: const Duration(milliseconds: 5),
    );
    addTearDown(monitor.stop);

    monitor.start(foreground: true);

    expect(
      await lost.future.timeout(const Duration(seconds: 1)),
      BlePresenceLossReason.failed,
    );
    expect(probes, 2);
    expect(monitor.isRunning, isFalse);
  });

  test('skipped probes do not count as failures', () async {
    final lost = Completer<BlePresenceLossReason>();
    final results = [
      const BlePresenceProbeResult.skipped(),
      const BlePresenceProbeResult.failed(),
      const BlePresenceProbeResult.failed(),
    ];
    var index = 0;
    final monitor = BlePresenceMonitor(
      probe: () async => results[index++],
      onSignal: (_) {},
      onLost: (reason) async {
        lost.complete(reason);
      },
      foregroundInterval: const Duration(milliseconds: 5),
      backgroundInterval: const Duration(milliseconds: 5),
    );
    addTearDown(monitor.stop);

    monitor.start(foreground: true);

    expect(
      await lost.future.timeout(const Duration(seconds: 1)),
      BlePresenceLossReason.failed,
    );
    expect(index, 3);
  });

  test('a successful signal resets the failure count', () async {
    final lost = Completer<BlePresenceLossReason>();
    final signals = <int>[];
    final results = [
      const BlePresenceProbeResult.failed(),
      const BlePresenceProbeResult.signal(-48),
      const BlePresenceProbeResult.failed(),
      const BlePresenceProbeResult.signal(-52),
      const BlePresenceProbeResult.failed(),
      const BlePresenceProbeResult.failed(),
    ];
    var index = 0;
    final monitor = BlePresenceMonitor(
      probe: () async => results[index++],
      onSignal: signals.add,
      onLost: (reason) async {
        lost.complete(reason);
      },
      foregroundInterval: const Duration(milliseconds: 5),
      backgroundInterval: const Duration(milliseconds: 5),
    );
    addTearDown(monitor.stop);

    monitor.start(foreground: true);

    expect(
      await lost.future.timeout(const Duration(seconds: 1)),
      BlePresenceLossReason.failed,
    );
    expect(signals, [-48, -52]);
    expect(index, 6);
  });

  test('a stuck probe times out and requests immediate teardown', () async {
    final lost = Completer<BlePresenceLossReason>();
    final never = Completer<BlePresenceProbeResult>();
    final monitor = BlePresenceMonitor(
      probe: () => never.future,
      onSignal: (_) {},
      onLost: (reason) async {
        lost.complete(reason);
      },
      foregroundInterval: const Duration(seconds: 1),
      backgroundInterval: const Duration(seconds: 1),
      probeTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(monitor.stop);

    monitor.start(foreground: true);
    unawaited(monitor.checkNow());

    expect(
      await lost.future.timeout(const Duration(seconds: 1)),
      BlePresenceLossReason.stuck,
    );
    expect(monitor.isRunning, isFalse);
  });

  test(
    'checkNow runs immediately and then resumes the configured cadence',
    () async {
      final signals = <int>[];
      var probes = 0;
      final monitor = BlePresenceMonitor(
        probe: () async {
          probes++;
          return BlePresenceProbeResult.signal(-40 - probes);
        },
        onSignal: signals.add,
        onLost: (_) async {},
        foregroundInterval: const Duration(milliseconds: 40),
        backgroundInterval: const Duration(milliseconds: 80),
      );
      addTearDown(monitor.stop);

      monitor.start(foreground: true);
      await monitor.checkNow();
      expect(probes, 1);
      expect(signals, [-41]);

      await Future<void>.delayed(const Duration(milliseconds: 55));
      expect(probes, 2);
      expect(monitor.isForeground, isTrue);
    },
  );
}
