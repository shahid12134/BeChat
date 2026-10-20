import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/mock/mock_data.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/data/repositories/mock_peer_discovery_repository.dart';
import 'package:bechat/data/repositories/unavailable_peer_discovery_repository.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_database.dart';

void main() {
  test('demo data is disabled by default', () {
    expect(AppConstants.demoDataEnabled, isFalse);
  });

  test('discovery factory uses simulated peers only when demo is enabled', () {
    final unavailable = createPeerDiscoveryRepository(demoEnabled: false);
    expect(unavailable, isA<UnavailablePeerDiscoveryRepository>());

    final mock = createPeerDiscoveryRepository(demoEnabled: true);
    expect(mock, isA<MockPeerDiscoveryRepository>());
    (mock as MockPeerDiscoveryRepository).dispose();
  });

  test('demo seeding is idempotent and keeps the real identity', () async {
    final db = await openTestDatabase();
    addTearDown(db.close);

    final identity = await IdentityRepository(
      database: () async => db,
    ).ensureIdentity();

    await MockData.seedDemoData(identity, database: () async => db);

    expect(await db.query('identity'), hasLength(1));
    expect((await db.query('identity')).single['device_id'], identity.deviceId);
    final seededPeers = await db.query('peers');
    final seededChats = await db.query('chats');
    final seededMessages = await db.query('messages');
    expect(seededPeers, hasLength(5));
    expect(seededChats, hasLength(3));
    expect(seededMessages, hasLength(10));
    expect(seededPeers.every((row) => row['id'] != null), isTrue);
    expect(seededChats.every((row) => row['id'] != null), isTrue);
    expect(seededMessages.every((row) => row['id'] != null), isTrue);
    expect((await db.query('identity')).single['id'], identity.deviceId);
    expect(
      seededMessages.any((row) => row['sender_id'] == identity.deviceId),
      isTrue,
    );
    expect(
      seededMessages.any(
        (row) => row['sender_id'] == AppConstants.legacyPlaceholderDeviceId,
      ),
      isFalse,
    );

    await MockData.seedDemoData(identity, database: () async => db);

    expect(await db.query('peers'), hasLength(5));
    expect(await db.query('chats'), hasLength(3));
    expect(await db.query('messages'), hasLength(10));
  });
}
