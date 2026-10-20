import 'package:bechat/data/models/chat.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/chat_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

void main() {
  late Database db;
  late ChatRepository repository;

  const peer = Peer(
    peerId: 'peer-alice-001',
    displayName: 'Alice',
    deviceName: 'Alice Phone',
    status: PeerStatus.online,
  );

  setUp(() async {
    db = await openTestDatabase();
    repository = ChatRepository(database: () async => db);
    await PeerRepository(database: () async => db).upsertPeer(peer);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'getOrCreateChatForPeer creates one chat and returns it again',
    () async {
      final first = await repository.getOrCreateChatForPeer(peer);
      final second = await repository.getOrCreateChatForPeer(peer);

      expect(first.chatId, second.chatId);
      expect(first.id, isNotNull);
      expect(first.title, 'Alice');
      expect(await db.query('chats'), hasLength(1));
    },
  );

  test(
    'updateChat with a null model id preserves the stored row identity',
    () async {
      final createdAt = DateTime(2025, 10, 1);
      final chat = Chat(
        id: 'chat-row-id',
        chatId: 'chat-001',
        peerId: peer.peerId,
        title: 'Alice',
        unreadCount: 4,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      await repository.insertChat(chat);

      await repository.updateChat(
        const Chat(
          chatId: 'chat-001',
          peerId: 'peer-alice-001',
          title: 'Alice Updated',
          unreadCount: 4,
        ),
      );

      final row = (await db.query('chats')).single;
      expect(row['id'], 'chat-row-id');
      expect(row['created_at'], createdAt.toIso8601String());
      expect(row['title'], 'Alice Updated');
      expect(row['unread_count'], 4);
    },
  );

  test(
    'chat creation does not duplicate or replace an existing chat',
    () async {
      final first = await repository.getOrCreateChatForPeer(peer);
      await repository.insertChat(first);

      expect(await db.query('chats'), hasLength(1));
      expect(
        (await repository.getOrCreateChatForPeer(peer)).chatId,
        first.chatId,
      );
    },
  );
}
