import 'dart:async';

import 'package:bechat/services/ble/ble_gatt_operation_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serializes queued GATT operations', () async {
    final gate = BleGattOperationGate();
    final release = Completer<void>();
    final events = <String>[];
    var secondStarted = false;

    final first = gate.run(() async {
      events.add('first-start');
      await release.future;
      events.add('first-end');
      return 1;
    });
    final second = gate.run(() async {
      secondStarted = true;
      events.add('second');
      return 2;
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-start']);
    expect(secondStarted, isFalse);

    release.complete();
    expect(await first, 1);
    expect(await second, 2);
    expect(events, ['first-start', 'first-end', 'second']);
    expect(gate.isBusy, isFalse);
  });

  test('tryRun skips while an operation is active or queued', () async {
    final gate = BleGattOperationGate();
    final release = Completer<void>();
    final first = gate.run(() => release.future);

    await Future<void>.delayed(Duration.zero);
    expect(gate.tryRun(() async => 1), isNull);

    release.complete();
    await first;
    expect(await gate.tryRun(() async => 2), 2);
  });

  test('a closed gate rejects queued work', () async {
    final gate = BleGattOperationGate();
    final release = Completer<void>();
    final first = gate.run(() => release.future);
    final queued = gate.run(() async => 1);

    await Future<void>.delayed(Duration.zero);
    gate.close();
    release.complete();

    await first;
    await expectLater(queued, throwsStateError);
    expect(gate.tryRun(() async => 2), isNull);
  });
}
