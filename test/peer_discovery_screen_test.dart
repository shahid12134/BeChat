import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/features/peers/screens/peer_discovery_screen.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('normal mode explains that BLE discovery is off until scan', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peerRepositoryProvider.overrideWithValue(_EmptyPeerRepository()),
        ],
        child: const MaterialApp(home: PeerDiscoveryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Scan for Demo Devices'), findsNothing);
    expect(find.text('Direct BLE messaging is off'), findsOneWidget);
    expect(
      find.textContaining('Both phones must be open in the foreground'),
      findsOneWidget,
    );
    expect(find.text('Scan for Peers'), findsOneWidget);
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

class _FakeBleRuntimeController extends BleRuntimeController {
  _FakeBleRuntimeController(super.ref, BleRuntimeState initialState) {
    state = initialState;
  }
}
