import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/app_data_repository.dart';
import 'package:bechat/data/repositories/chat_repository.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/data/repositories/message_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await openTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'clearUserData preserves identity and deletes all user records',
    () async {
      final identity = await IdentityRepository(
        database: () async => db,
      ).ensureIdentity();
      const peer = Peer(
        peerId: 'peer-alice-001',
        displayName: 'Alice',
        deviceName: 'Alice Phone',
      );
      await PeerRepository(database: () async => db).upsertPeer(peer);
      final chat = await ChatRepository(
        database: () async => db,
      ).getOrCreateChatForPeer(peer);
      final now = DateTime.now();
      await MessageRepository(database: () async => db).insertMessage(
        Message(
          messageId: 'msg-001',
          chatId: chat.chatId,
          senderId: identity.deviceId,
          receiverId: peer.peerId,
          content: 'Hello',
          timestamp: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.insert('attachments', {
        'attachment_id': 'att-001',
        'message_id': 'msg-001',
        'file_name': 'file.txt',
        'file_path': '/tmp/file.txt',
        'created_at': now.toIso8601String(),
      });
      await db.insert('message_routes', {
        'message_id': 'msg-001',
        'target_peer': peer.peerId,
        'queued_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });

      await AppDataRepository(database: () async => db).clearUserData();

      expect(
        (await db.query('identity')).single['device_id'],
        identity.deviceId,
      );
      for (final table in [
        'peers',
        'chats',
        'messages',
        'attachments',
        'message_routes',
      ]) {
        expect(
          await db.query(table),
          isEmpty,
          reason: '$table should be empty',
        );
      }
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    },
  );
}
