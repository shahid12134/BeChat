import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

void main() {
  late Database db;
  late PeerRepository repository;

  setUp(() async {
    db = await openTestDatabase();
    repository = PeerRepository(database: () async => db);
  });

  tearDown(() async {
    await db.close();
  });

  test('peer upsert preserves existing chat and message history', () async {
    final createdAt = DateTime(2026, 1, 1, 10);
    final firstSeen = DateTime(2026, 1, 2, 10);
    await repository.upsertPeer(
      Peer(
        peerId: 'peer-alice-001',
        displayName: 'Alice',
        deviceName: 'Alice Phone',
        status: PeerStatus.online,
        firstSeen: firstSeen,
        publicKey: 'preserved-public-key',
        avatarPath: '/avatars/alice.png',
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    final peerRow = (await db.query('peers')).single;

    final now = DateTime.now().toIso8601String();
    await db.insert('chats', {
      'chat_id': 'chat-alice-001',
      'peer_id': 'peer-alice-001',
      'title': 'Alice',
      'unread_count': 3,
      'last_message': 'Existing',
      'last_message_time': now,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('messages', {
      'message_id': 'msg-existing',
      'chat_id': 'chat-alice-001',
      'sender_id': 'peer-alice-001',
      'receiver_id': 'local-device',
      'content': 'Existing',
      'message_type': 'text',
      'timestamp': now,
      'status': 'delivered',
      'transport': 'local',
      'ttl': 86400,
      'is_encrypted': 0,
      'created_at': now,
      'updated_at': now,
    });
    await repository.blockPeer('peer-alice-001');

    await repository.upsertPeer(
      Peer(
        peerId: 'peer-alice-001',
        displayName: 'Alice Updated',
        deviceName: 'Alice Phone Updated',
        status: PeerStatus.online,
        signalStrength: -51,
        lastSeen: DateTime(2026, 2, 1),
      ),
    );

    final peers = await db.query('peers');
    expect(peers, hasLength(1));
    expect(peers.single['display_name'], 'Alice Updated');
    expect(peers.single['status'], PeerStatus.blocked.name);
    expect(peers.single['is_blocked'], 1);
    expect(peers.single['created_at'], createdAt.toIso8601String());
    expect(peers.single['first_seen'], firstSeen.toIso8601String());
    expect(peers.single['id'], peerRow['id']);
    expect(peers.single['public_key'], 'preserved-public-key');
    expect(peers.single['avatar_path'], '/avatars/alice.png');

    expect(await db.query('chats'), hasLength(1));
    expect((await db.query('chats')).single['unread_count'], 3);
    expect(await db.query('messages'), hasLength(1));
  });

  test(
    'updatePeer with a null model id does not write a null primary key',
    () async {
      final createdAt = DateTime(2025, 12, 1);
      await repository.upsertPeer(
        Peer(
          peerId: 'peer-rahul-002',
          displayName: 'Rahul',
          deviceName: 'Rahul Phone',
          createdAt: createdAt,
          firstSeen: createdAt,
          updatedAt: createdAt,
        ),
      );
      final before = (await db.query('peers')).single;

      await repository.updatePeer(
        const Peer(
          peerId: 'peer-rahul-002',
          displayName: 'Rahul Updated',
          deviceName: 'Rahul Phone',
          status: PeerStatus.offline,
          isBlocked: false,
        ),
      );

      final after = (await db.query('peers')).single;
      expect(after['id'], before['id']);
      expect(after['id'], isNotNull);
      expect(after['created_at'], createdAt.toIso8601String());
      expect(after['display_name'], 'Rahul Updated');
    },
  );

  test('foreign keys remain valid after peer operations', () async {
    await repository.upsertPeer(
      const Peer(
        peerId: 'peer-maria-005',
        displayName: 'Maria',
        deviceName: 'Maria Phone',
      ),
    );

    final violations = await db.rawQuery('PRAGMA foreign_key_check');
    expect(violations, isEmpty);
  });
}
