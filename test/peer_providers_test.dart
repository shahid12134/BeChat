import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_database.dart';

void main() {
  test('saving discovered peers persists them for peer details', () async {
    final db = await openTestDatabase();
    addTearDown(db.close);
    final notifier = PeerListNotifier(PeerRepository(database: () async => db));
    addTearDown(notifier.dispose);

    await notifier.saveDiscoveredPeers([
      const Peer(
        peerId: 'peer-alice-001',
        displayName: 'Alice',
        deviceName: 'Alice Phone',
        status: PeerStatus.online,
      ),
    ]);

    final stored = await PeerRepository(
      database: () async => db,
    ).getPeerByPeerId('peer-alice-001');
    expect(stored, isNotNull);
    expect(stored?.displayName, 'Alice');
    expect(notifier.state.valueOrNull, hasLength(1));
  });
}
