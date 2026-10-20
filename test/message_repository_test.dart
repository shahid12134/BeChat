import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/chat_repository.dart';
import 'package:bechat/data/repositories/message_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

void main() {
  late Database db;
  late MessageRepository repository;
  late String chatId;

  const peer = Peer(
    peerId: 'peer-alice-001',
    displayName: 'Alice',
    deviceName: 'Alice Phone',
  );

  setUp(() async {
    db = await openTestDatabase();
    repository = MessageRepository(database: () async => db);
    await PeerRepository(database: () async => db).upsertPeer(peer);
    final chat = await ChatRepository(
      database: () async => db,
    ).getOrCreateChatForPeer(peer);
    chatId = chat.chatId;
  });

  tearDown(() async {
    await db.close();
  });

  test('loads the newest 50 messages in chronological display order', () async {
    final start = DateTime(2026, 1, 1);
    for (var i = 0; i < 60; i++) {
      await repository.insertMessage(
        Message(
          messageId: 'msg-${i.toString().padLeft(2, '0')}',
          chatId: chatId,
          senderId: 'device-local',
          receiverId: peer.peerId,
          content: 'Message $i',
          timestamp: start.add(Duration(minutes: i)),
          status: MessageStatus.queued,
          createdAt: start.add(Duration(minutes: i)),
          updatedAt: start.add(Duration(minutes: i)),
        ),
      );
    }

    final messages = await repository.getMessagesByChatId(chatId);

    expect(messages, hasLength(50));
    expect(messages.first.messageId, 'msg-10');
    expect(messages.last.messageId, 'msg-59');
    expect(
      messages.map((message) => message.messageId),
      orderedEquals(List.generate(50, (index) => 'msg-${index + 10}')),
    );
  });

  test(
    'duplicate message insert does not delete attachments or routes',
    () async {
      final now = DateTime.now();
      final message = Message(
        messageId: 'msg-duplicate',
        chatId: chatId,
        senderId: 'device-local',
        receiverId: peer.peerId,
        content: 'Original',
        timestamp: now,
        status: MessageStatus.queued,
        createdAt: now,
        updatedAt: now,
      );
      await repository.insertMessage(message);

      await db.insert('attachments', {
        'attachment_id': 'att-001',
        'message_id': message.messageId,
        'file_name': 'file.txt',
        'file_path': '/tmp/file.txt',
        'transfer_status': 'pending',
        'created_at': now.toIso8601String(),
      });
      await db.insert('message_routes', {
        'message_id': message.messageId,
        'target_peer': peer.peerId,
        'ttl': 3600,
        'attempt_count': 0,
        'status': 'queued',
        'queued_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });

      await repository.insertMessage(
        message.copyWith(content: 'Replacement should be ignored'),
      );

      expect(await db.query('messages'), hasLength(1));
      expect(await db.query('attachments'), hasLength(1));
      expect(await db.query('message_routes'), hasLength(1));
      expect((await db.query('messages')).single['content'], 'Original');
    },
  );

  test('message insert and chat metadata update are atomic', () async {
    final now = DateTime.now();
    final message = Message(
      messageId: 'msg-atomic',
      chatId: chatId,
      senderId: 'device-local',
      receiverId: peer.peerId,
      content: 'Atomic',
      timestamp: now,
      status: MessageStatus.queued,
      createdAt: now,
      updatedAt: now,
    );
    await db.execute('''
      CREATE TRIGGER fail_chat_update
      BEFORE UPDATE ON chats
      BEGIN
        SELECT RAISE(ABORT, 'chat update blocked');
      END
    ''');

    await expectLater(
      repository.insertMessageAndUpdateChat(message),
      throwsA(anything),
    );

    expect(await db.query('messages'), isEmpty);
  });

  test(
    'successful local send persists queued state and chat metadata',
    () async {
      final now = DateTime.now();
      final message = Message(
        messageId: 'msg-queued',
        chatId: chatId,
        senderId: 'device-local',
        receiverId: peer.peerId,
        content: 'Queued message',
        timestamp: now,
        status: MessageStatus.queued,
        createdAt: now,
        updatedAt: now,
      );

      expect(await repository.insertMessageAndUpdateChat(message), isTrue);

      final stored = await repository.getMessageByMessageId('msg-queued');
      expect(stored?.status, MessageStatus.queued);
      expect(stored?.senderId, 'device-local');

      final chat = (await db.query('chats')).single;
      expect(chat['last_message'], 'Queued message');
      expect(chat['last_message_time'], now.toIso8601String());
    },
  );

  test('inserted rows receive non-null primary keys', () async {
    final now = DateTime.now();
    await repository.insertMessage(
      Message(
        messageId: 'msg-id-check',
        chatId: chatId,
        senderId: 'device-local',
        receiverId: peer.peerId,
        content: 'ID check',
        timestamp: now,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final row = (await db.query('messages')).single;
    expect(row['id'], isNotNull);
  });

  test(
    'BLE outbox selects queued outgoing messages and tracks ACK states',
    () async {
      final now = DateTime.now();
      for (final entry in {
        'msg-queued': MessageStatus.queued,
        'msg-sending': MessageStatus.sending,
        'msg-sent': MessageStatus.sent,
        'msg-delivered': MessageStatus.delivered,
        'msg-failed': MessageStatus.failed,
      }.entries) {
        await repository.insertMessage(
          Message(
            messageId: entry.key,
            chatId: chatId,
            senderId: 'device-local',
            receiverId: peer.peerId,
            content: entry.key,
            timestamp: now,
            status: entry.value,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }

      final queued = await repository.getQueuedOutgoingMessages('device-local');
      expect(queued.map((message) => message.messageId), ['msg-queued']);

      await repository.markMessageSending('msg-queued');
      var stored = await repository.getMessageByMessageId('msg-queued');
      expect(stored?.status, MessageStatus.sending);
      expect(stored?.transport, MessageTransport.ble);

      await repository.markMessageSent('msg-queued');
      stored = await repository.getMessageByMessageId('msg-queued');
      expect(stored?.status, MessageStatus.sent);

      await repository.markMessageDelivered('msg-queued');
      stored = await repository.getMessageByMessageId('msg-queued');
      expect(stored?.status, MessageStatus.delivered);

      await repository.resetOutboxForSender('device-local');
      expect(
        (await repository.getMessageByMessageId('msg-queued'))?.status,
        MessageStatus.delivered,
      );
      expect(
        (await repository.getMessageByMessageId('msg-sending'))?.status,
        MessageStatus.queued,
      );
      expect(
        (await repository.getMessageByMessageId('msg-sent'))?.status,
        MessageStatus.queued,
      );
      expect(
        (await repository.getMessageByMessageId('msg-delivered'))?.status,
        MessageStatus.delivered,
      );
    },
  );
}
