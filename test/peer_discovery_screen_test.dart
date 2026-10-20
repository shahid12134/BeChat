import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/features/peers/screens/peer_discovery_screen.dart';
import 'package:bechat/providers/peer_providers.dart';
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
}

class _EmptyPeerRepository extends PeerRepository {
  @override
  Future<List<Peer>> getAllPeers() async => const [];
}
