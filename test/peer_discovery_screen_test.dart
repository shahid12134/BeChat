import 'package:bechat/data/models/app_settings.dart';
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
      find.text('Allow unknown nearby devices to request a connection.'),
      findsOneWidget,
    );
    expect(find.text('Direct BLE messaging is off'), findsNothing);
    expect(find.text('Scan for Peers'), findsNothing);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
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
  _FakeAppSettingsRepository({this.failWrites = false});

  final bool failWrites;
  bool allowNewConnections = true;

  @override
  Future<AppSettings> loadSettings() async {
    return AppSettings(allowNewConnections: allowNewConnections);
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
}
