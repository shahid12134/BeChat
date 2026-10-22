import 'package:bechat/data/models/app_settings.dart';
import 'package:bechat/data/models/ble_candidate.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/app_settings_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/features/peers/screens/peer_discovery_screen.dart';
import 'package:bechat/providers/app_settings_providers.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('normal mode shows the new connection approval setting', (
    tester,
  ) async {
    final settings = _FakeAppSettingsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peerRepositoryProvider.overrideWithValue(_EmptyPeerRepository()),
          appSettingsRepositoryProvider.overrideWithValue(settings),
        ],
        child: const MaterialApp(home: PeerDiscoveryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Scan for Demo Devices'), findsNothing);
    expect(find.text('Allow New Connections'), findsOneWidget);
    expect(
      find.text(
        'Allow unknown nearby devices to request a connection while '
        'BeChat is on.',
      ),
      findsOneWidget,
    );
    expect(find.text('Direct BLE messaging is off'), findsNothing);
    expect(find.text('Scan for Peers'), findsNothing);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('BeChat is offline'), findsOneWidget);
    expect(find.text('Nearby Scan'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('scan with BeChat off asks before enabling anything', (
    tester,
  ) async {
    final settings = _FakeAppSettingsRepository();
    late _FakeBleRuntimeController runtime;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peerRepositoryProvider.overrideWithValue(_EmptyPeerRepository()),
          appSettingsRepositoryProvider.overrideWithValue(settings),
          bleRuntimeProvider.overrideWith((ref) {
            runtime = _FakeBleRuntimeController(ref, const BleRuntimeState());
            return runtime;
          }),
        ],
        child: const MaterialApp(home: PeerDiscoveryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();

    expect(find.text('Turn on BeChat?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(settings.bleEnabled, isFalse);
    expect(runtime.scanCalls, 0);
  });

  testWidgets('scanning shows candidates, thin progress, and a stop control', (
    tester,
  ) async {
    final settings = _FakeAppSettingsRepository(bleEnabled: true);
    late _FakeBleRuntimeController runtime;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peerRepositoryProvider.overrideWithValue(_EmptyPeerRepository()),
          appSettingsRepositoryProvider.overrideWithValue(settings),
          bleRuntimeProvider.overrideWith((ref) {
            runtime = _FakeBleRuntimeController(
              ref,
              BleRuntimeState(
                status: BleRuntimeStatus.scanning,
                candidates: [
                  BleCandidate(
                    id: 'candidate-1',
                    displayName: 'Nearby Bob',
                    rssi: -42,
                    lastSeen: DateTime.utc(2026, 1, 1),
                  ),
                ],
              ),
            );
            return runtime;
          }),
        ],
        child: const MaterialApp(home: PeerDiscoveryScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Nearby Bob'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Stop Scanning'), findsOneWidget);

    await tester.tap(find.text('Stop Scanning'));
    await tester.pump();
    expect(runtime.stopCalls, 1);
  });

  testWidgets('turning new connections off is persisted', (tester) async {
    final settings = _FakeAppSettingsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peerRepositoryProvider.overrideWithValue(_EmptyPeerRepository()),
          appSettingsRepositoryProvider.overrideWithValue(settings),
        ],
        child: const MaterialApp(home: PeerDiscoveryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Allow New Connections'));
    await tester.pumpAndSettle();

    expect(settings.allowNewConnections, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('a failed setting save keeps the previous value', (tester) async {
    final settings = _FakeAppSettingsRepository(failWrites: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peerRepositoryProvider.overrideWithValue(_EmptyPeerRepository()),
          appSettingsRepositoryProvider.overrideWithValue(settings),
        ],
        child: const MaterialApp(home: PeerDiscoveryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Allow New Connections'));
    await tester.pumpAndSettle();

    expect(settings.allowNewConnections, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(
      find.textContaining('Could not save the connection setting'),
      findsOneWidget,
    );
  });

  testWidgets('a long BLE error scrolls instead of overflowing', (
    tester,
  ) async {
    final error =
        'Connection failed: Write descriptor failed with status: 129. '
        '${'The peer rejected the Bluetooth link setup. ' * 400}';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peerRepositoryProvider.overrideWithValue(_EmptyPeerRepository()),
          appSettingsRepositoryProvider.overrideWithValue(
            _FakeAppSettingsRepository(),
          ),
          bleRuntimeProvider.overrideWith(
            (ref) => _FakeBleRuntimeController(
              ref,
              BleRuntimeState(status: BleRuntimeStatus.error, error: error),
            ),
          ),
        ],
        child: const MaterialApp(home: PeerDiscoveryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Bluetooth error'), findsOneWidget);
    expect(find.text(error), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}

class _EmptyPeerRepository extends PeerRepository {
  @override
  Future<List<Peer>> getAllPeers() async => const [];
}

class _FakeAppSettingsRepository extends AppSettingsRepository {
  _FakeAppSettingsRepository({
    this.failWrites = false,
    this.bleEnabled = false,
  });

  final bool failWrites;
  bool allowNewConnections = true;
  bool bleEnabled;

  @override
  Future<AppSettings> loadSettings() async {
    return AppSettings(
      allowNewConnections: allowNewConnections,
      bleEnabled: bleEnabled,
    );
  }

  @override
  Future<bool> getBleEnabled() async => bleEnabled;

  @override
  Future<void> setBleEnabled(bool value) async {
    if (failWrites) throw Exception('database unavailable');
    bleEnabled = value;
  }

  @override
  Future<void> setAllowNewConnections(bool value) async {
    if (failWrites) throw Exception('database unavailable');
    allowNewConnections = value;
  }
}

class _FakeBleRuntimeController extends BleRuntimeController {
  _FakeBleRuntimeController(super.ref, BleRuntimeState initialState) {
    state = initialState;
  }

  int scanCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> startScan() async {
    scanCalls++;
  }

  @override
  Future<void> stopScan() async {
    stopCalls++;
  }

  @override
  Future<void> setAvailabilityEnabled(bool enabled) async {}
}
