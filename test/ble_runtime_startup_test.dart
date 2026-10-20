import 'dart:async';

import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/settings_providers.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:bechat/services/ble/ble_status_probe.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';

void main() {
  test(
    'native granted status overrides stale plugin unauthorized cache',
    () async {
      final harness = _Harness(_FakeStatusProbe(_status()));
      addTearDown(harness.dispose);

      await harness.controller.ensureStarted();

      expect(harness.controller.state.status, BleRuntimeStatus.ready);
      expect(harness.controller.state.isAdvertising, isTrue);
      verify(harness.peripheral.startAdvertising(any)).called(1);
      verifyNever(harness.central.authorize());
      verifyNever(harness.peripheral.authorize());
    },
  );

  test('startup proceeds after authorization and a granted re-probe', () async {
    final probe = _FakeStatusProbe(_status(permissions: false));
    final harness = _Harness(probe);
    addTearDown(harness.dispose);
    when(harness.central.authorize()).thenAnswer((_) async {
      probe.status = _status();
      return true;
    });

    await harness.controller.ensureStarted();

    expect(harness.controller.state.status, BleRuntimeStatus.ready);
    expect(probe.calls, 2);
    verify(harness.central.authorize()).called(1);
    verify(harness.peripheral.authorize()).called(1);
  });

  test(
    'startup reports unauthorized when permissions remain missing',
    () async {
      final probe = _FakeStatusProbe(_status(permissions: false));
      final harness = _Harness(probe);
      addTearDown(harness.dispose);

      await harness.controller.ensureStarted();

      expect(harness.controller.state.status, BleRuntimeStatus.unauthorized);
      expect(harness.controller.state.canOpenSettings, isTrue);
      expect(
        harness.controller.state.error,
        contains('permissions are required'),
      );
      expect(probe.calls, 2);
      verifyNever(harness.peripheral.addService(any));
    },
  );

  test('retry after permission grant starts discovery', () async {
    final probe = _FakeStatusProbe(_status(permissions: false));
    final harness = _Harness(probe);
    addTearDown(harness.dispose);

    await harness.controller.ensureStarted();
    expect(harness.controller.state.status, BleRuntimeStatus.unauthorized);

    probe.status = _status();
    await harness.controller.retry();

    expect(harness.controller.state.status, BleRuntimeStatus.scanning);
    verify(
      harness.central.startDiscovery(serviceUUIDs: anyNamed('serviceUUIDs')),
    ).called(1);
  });

  test('resume after failed startup rechecks status and recovers', () async {
    final probe = _FakeStatusProbe(_status(permissions: false));
    final harness = _Harness(probe);
    addTearDown(harness.dispose);

    await harness.controller.ensureStarted();
    expect(harness.controller.state.status, BleRuntimeStatus.unauthorized);

    probe.status = _status();
    await harness.controller.resumeFromBackground();

    expect(harness.controller.state.status, BleRuntimeStatus.ready);
    expect(harness.controller.state.isAdvertising, isTrue);
    verify(harness.peripheral.startAdvertising(any)).called(1);
  });

  test('resume does not start BLE before the workflow is entered', () async {
    final probe = _FakeStatusProbe(_status());
    final harness = _Harness(probe);
    addTearDown(harness.dispose);

    await harness.controller.resumeFromBackground();

    expect(harness.controller.state.status, BleRuntimeStatus.idle);
    expect(probe.calls, 0);
    verifyNever(harness.peripheral.startAdvertising(any));
  });

  test('Bluetooth disabled is reported separately from permissions', () async {
    final harness = _Harness(
      _FakeStatusProbe(_status(enabled: false, advertising: false)),
    );
    addTearDown(harness.dispose);

    await harness.controller.ensureStarted();

    expect(harness.controller.state.status, BleRuntimeStatus.bluetoothOff);
    expect(harness.controller.state.error, contains('turned off'));
    verifyNever(harness.central.authorize());
  });

  test('unsupported LE hardware reports unsupported', () async {
    final harness = _Harness(_FakeStatusProbe(_status(le: false)));
    addTearDown(harness.dispose);

    await harness.controller.ensureStarted();

    expect(harness.controller.state.status, BleRuntimeStatus.unsupported);
    verifyNever(harness.central.authorize());
    verifyNever(harness.peripheral.authorize());
  });

  test('unavailable advertising capability reports unsupported', () async {
    final harness = _Harness(_FakeStatusProbe(_status(advertising: false)));
    addTearDown(harness.dispose);

    await harness.controller.ensureStarted();

    expect(harness.controller.state.status, BleRuntimeStatus.unsupported);
  });

  test('stale unauthorized event does not break a verified runtime', () async {
    final harness = _Harness(_FakeStatusProbe(_status()));
    addTearDown(harness.dispose);

    await harness.controller.ensureStarted();
    expect(harness.controller.state.status, BleRuntimeStatus.ready);

    harness.centralStates.add(
      BluetoothLowEnergyStateChangedEventArgs(
        BluetoothLowEnergyState.unauthorized,
      ),
    );
    await pumpEventQueue();

    expect(harness.controller.state.status, BleRuntimeStatus.ready);
  });

  test('permission revocation is reflected after a plugin event', () async {
    final probe = _FakeStatusProbe(_status());
    final harness = _Harness(probe);
    addTearDown(harness.dispose);

    await harness.controller.ensureStarted();
    expect(harness.controller.state.status, BleRuntimeStatus.ready);

    probe.status = _status(permissions: false);
    harness.centralStates.add(
      BluetoothLowEnergyStateChangedEventArgs(
        BluetoothLowEnergyState.unauthorized,
      ),
    );
    await pumpEventQueue();

    expect(harness.controller.state.status, BleRuntimeStatus.unauthorized);
    expect(harness.controller.state.canOpenSettings, isTrue);
  });

  test('simultaneous startup calls share one operation', () async {
    final probe = _DeferredStatusProbe();
    final harness = _Harness(probe);
    addTearDown(harness.dispose);

    final first = harness.controller.ensureStarted();
    final second = harness.controller.ensureStarted();
    expect(probe.calls, 1);

    probe.complete(_status());
    await Future.wait([first, second]);

    expect(harness.controller.state.status, BleRuntimeStatus.ready);
    verify(harness.peripheral.removeAllServices()).called(1);
    verify(harness.peripheral.addService(any)).called(1);
  });

  test('native status probe failure is a diagnostic error', () async {
    final probe = _FakeStatusProbe(_status())
      ..error = const BleStatusProbeException('Native status check failed.');
    final harness = _Harness(probe);
    addTearDown(harness.dispose);

    await harness.controller.ensureStarted();

    expect(harness.controller.state.status, BleRuntimeStatus.error);
    expect(
      harness.controller.state.status,
      isNot(BleRuntimeStatus.unauthorized),
    );
    expect(
      harness.controller.state.error,
      contains('Native status check failed'),
    );
    verifyNever(harness.central.authorize());
  });

  test(
    'retry after Bluetooth is enabled recovers and starts discovery',
    () async {
      final probe = _FakeStatusProbe(
        _status(enabled: false, advertising: false),
      );
      final harness = _Harness(probe);
      addTearDown(harness.dispose);

      await harness.controller.ensureStarted();
      expect(harness.controller.state.status, BleRuntimeStatus.bluetoothOff);

      probe.status = _status();
      await harness.controller.retry();

      expect(harness.controller.state.status, BleRuntimeStatus.scanning);
      verify(
        harness.central.startDiscovery(serviceUUIDs: anyNamed('serviceUUIDs')),
      ).called(1);
    },
  );

  test('authorization timeout does not leave startup stuck', () async {
    final probe = _FakeStatusProbe(_status(permissions: false));
    final harness = _Harness(
      probe,
      permissionTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(harness.dispose);
    when(
      harness.central.authorize(),
    ).thenAnswer((_) => Completer<bool>().future);

    await harness.controller.ensureStarted();

    expect(harness.controller.state.status, BleRuntimeStatus.unauthorized);

    probe.status = _status();
    await harness.controller.retry();

    expect(harness.controller.state.status, BleRuntimeStatus.scanning);
  });
}

BlePlatformStatus _status({
  bool permissions = true,
  bool enabled = true,
  bool le = true,
  bool advertising = true,
  int sdkInt = 31,
}) {
  final nearby = permissions && sdkInt >= 31;
  return BlePlatformStatus(
    sdkInt: sdkInt,
    scan: nearby,
    connect: nearby,
    advertise: nearby,
    location: permissions && sdkInt < 31,
    permissionsGranted: permissions,
    bluetoothEnabled: enabled,
    leSupported: le,
    advertisingSupported: advertising,
  );
}

class _FakeStatusProbe implements BleStatusProbe {
  _FakeStatusProbe(this.status);

  BlePlatformStatus status;
  Object? error;
  int calls = 0;

  @override
  Future<BlePlatformStatus> getStatus() async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return status;
  }
}

class _DeferredStatusProbe implements BleStatusProbe {
  final _completer = Completer<BlePlatformStatus>();
  int calls = 0;

  @override
  Future<BlePlatformStatus> getStatus() {
    calls++;
    return _completer.future;
  }

  void complete(BlePlatformStatus status) {
    _completer.complete(status);
  }
}

class _Harness {
  _Harness(
    BleStatusProbe probe, {
    Duration permissionTimeout = const Duration(milliseconds: 100),
  }) {
    _stubManagers();
    container = ProviderContainer(
      overrides: [
        localDeviceIdProvider.overrideWithValue(null),
        bleRuntimeProvider.overrideWith(
          (ref) => BleRuntimeController(
            ref,
            centralManager: central,
            peripheralManager: peripheral,
            statusProbe: probe,
            permissionTimeout: permissionTimeout,
            isAndroidOverride: true,
          ),
        ),
      ],
    );
    controller = container.read(bleRuntimeProvider.notifier);
  }

  final central = _MockCentralManager();
  final peripheral = _MockPeripheralManager();
  final centralStates =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();
  final peripheralStates =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();

  late final ProviderContainer container;
  late final BleRuntimeController controller;

  void _stubManagers() {
    when(central.state).thenReturn(BluetoothLowEnergyState.unauthorized);
    when(peripheral.state).thenReturn(BluetoothLowEnergyState.unauthorized);
    when(central.stateChanged).thenAnswer((_) => centralStates.stream);
    when(peripheral.stateChanged).thenAnswer((_) => peripheralStates.stream);
    when(
      central.discovered,
    ).thenAnswer((_) => const Stream<DiscoveredEventArgs>.empty());
    when(central.connectionStateChanged).thenAnswer(
      (_) => const Stream<PeripheralConnectionStateChangedEventArgs>.empty(),
    );
    when(central.characteristicNotified).thenAnswer(
      (_) => const Stream<GATTCharacteristicNotifiedEventArgs>.empty(),
    );
    when(peripheral.characteristicWriteRequested).thenAnswer(
      (_) => const Stream<GATTCharacteristicWriteRequestedEventArgs>.empty(),
    );
    when(peripheral.characteristicNotifyStateChanged).thenAnswer(
      (_) =>
          const Stream<GATTCharacteristicNotifyStateChangedEventArgs>.empty(),
    );
    when(peripheral.connectionStateChanged).thenAnswer(
      (_) => const Stream<CentralConnectionStateChangedEventArgs>.empty(),
    );

    when(central.authorize()).thenAnswer((_) async => true);
    when(peripheral.authorize()).thenAnswer((_) async => true);
    when(
      central.startDiscovery(serviceUUIDs: anyNamed('serviceUUIDs')),
    ).thenAnswer((_) async {});
    when(central.stopDiscovery()).thenAnswer((_) async {});
    when(peripheral.removeAllServices()).thenAnswer((_) async {});
    when(peripheral.addService(any)).thenAnswer((_) async {});
    when(peripheral.startAdvertising(any)).thenAnswer((_) async {});
    when(peripheral.stopAdvertising()).thenAnswer((_) async {});
  }

  Future<void> dispose() async {
    container.dispose();
    await centralStates.close();
    await peripheralStates.close();
  }
}

class _MockCentralManager extends Mock implements CentralManager {
  @override
  BluetoothLowEnergyState get state =>
      super.noSuchMethod(
            Invocation.getter(#state),
            returnValue: BluetoothLowEnergyState.unknown,
          )
          as BluetoothLowEnergyState;

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      super.noSuchMethod(
            Invocation.getter(#stateChanged),
            returnValue:
                const Stream<BluetoothLowEnergyStateChangedEventArgs>.empty(),
          )
          as Stream<BluetoothLowEnergyStateChangedEventArgs>;

  @override
  Stream<DiscoveredEventArgs> get discovered =>
      super.noSuchMethod(
            Invocation.getter(#discovered),
            returnValue: const Stream<DiscoveredEventArgs>.empty(),
          )
          as Stream<DiscoveredEventArgs>;

  @override
  Stream<PeripheralConnectionStateChangedEventArgs>
  get connectionStateChanged =>
      super.noSuchMethod(
            Invocation.getter(#connectionStateChanged),
            returnValue:
                const Stream<PeripheralConnectionStateChangedEventArgs>.empty(),
          )
          as Stream<PeripheralConnectionStateChangedEventArgs>;

  @override
  Stream<GATTCharacteristicNotifiedEventArgs> get characteristicNotified =>
      super.noSuchMethod(
            Invocation.getter(#characteristicNotified),
            returnValue:
                const Stream<GATTCharacteristicNotifiedEventArgs>.empty(),
          )
          as Stream<GATTCharacteristicNotifiedEventArgs>;

  @override
  Future<bool> authorize() =>
      super.noSuchMethod(
            Invocation.method(#authorize, []),
            returnValue: Future<bool>.value(false),
          )
          as Future<bool>;

  @override
  Future<void> startDiscovery({List<UUID>? serviceUUIDs}) =>
      super.noSuchMethod(
            Invocation.method(#startDiscovery, [], {
              #serviceUUIDs: serviceUUIDs,
            }),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> stopDiscovery() =>
      super.noSuchMethod(
            Invocation.method(#stopDiscovery, []),
            returnValue: Future<void>.value(),
          )
          as Future<void>;
}

class _MockPeripheralManager extends Mock implements PeripheralManager {
  @override
  BluetoothLowEnergyState get state =>
      super.noSuchMethod(
            Invocation.getter(#state),
            returnValue: BluetoothLowEnergyState.unknown,
          )
          as BluetoothLowEnergyState;

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      super.noSuchMethod(
            Invocation.getter(#stateChanged),
            returnValue:
                const Stream<BluetoothLowEnergyStateChangedEventArgs>.empty(),
          )
          as Stream<BluetoothLowEnergyStateChangedEventArgs>;

  @override
  Stream<GATTCharacteristicWriteRequestedEventArgs>
  get characteristicWriteRequested =>
      super.noSuchMethod(
            Invocation.getter(#characteristicWriteRequested),
            returnValue:
                const Stream<GATTCharacteristicWriteRequestedEventArgs>.empty(),
          )
          as Stream<GATTCharacteristicWriteRequestedEventArgs>;

  @override
  Stream<GATTCharacteristicNotifyStateChangedEventArgs>
  get characteristicNotifyStateChanged =>
      super.noSuchMethod(
            Invocation.getter(#characteristicNotifyStateChanged),
            returnValue:
                const Stream<
                  GATTCharacteristicNotifyStateChangedEventArgs
                >.empty(),
          )
          as Stream<GATTCharacteristicNotifyStateChangedEventArgs>;

  @override
  Stream<CentralConnectionStateChangedEventArgs> get connectionStateChanged =>
      super.noSuchMethod(
            Invocation.getter(#connectionStateChanged),
            returnValue:
                const Stream<CentralConnectionStateChangedEventArgs>.empty(),
          )
          as Stream<CentralConnectionStateChangedEventArgs>;

  @override
  Future<bool> authorize() =>
      super.noSuchMethod(
            Invocation.method(#authorize, []),
            returnValue: Future<bool>.value(false),
          )
          as Future<bool>;

  @override
  Future<void> removeAllServices() =>
      super.noSuchMethod(
            Invocation.method(#removeAllServices, []),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> addService(GATTService? service) =>
      super.noSuchMethod(
            Invocation.method(#addService, [service]),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> startAdvertising(Advertisement? advertisement) =>
      super.noSuchMethod(
            Invocation.method(#startAdvertising, [advertisement]),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> stopAdvertising() =>
      super.noSuchMethod(
            Invocation.method(#stopAdvertising, []),
            returnValue: Future<void>.value(),
          )
          as Future<void>;
}
