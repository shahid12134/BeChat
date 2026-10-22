import 'dart:async';

import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/utils/timestamp_utils.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/services/ble/ble_message_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

void main() {
  late Database db;
  late PeerRepository peers;
  late BleMessageStore store;

  const local = Identity(deviceId: 'device-local', displayName: 'Local');
  const remote = Peer(
    peerId: 'device-remote',
    displayName: 'Remote',
    deviceName: 'Remote phone',
  );

  setUp(() async {
    db = await openTestDatabase();
    peers = PeerRepository(database: () async => db);
    store = BleMessageStore(database: () async => db);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'stores a new incoming message, chat, unread count, and metadata',
    () async {
      final receipt = await store.storeIncoming(
        payload: _payload(messageId: 'msg-1', content: 'Hello'),
        peer: remote,
      );

      expect(receipt.result, BleIncomingResult.stored);
      expect(receipt.chatId, isNotEmpty);
      final peerRow = (await db.query('peers')).single;
      expect(peerRow['status'], PeerStatus.online.name);
      final chat = (await db.query('chats')).single;
      expect(chat['last_message'], 'Hello');
      expect(chat['unread_count'], 1);
      final message = (await db.query('messages')).single;
      expect(message['status'], MessageStatus.delivered.name);
      expect(message['transport'], MessageTransport.ble.name);
      expect(message['is_encrypted'], 0);
      expect(message['timestamp'], endsWith('Z'));
      expect(DateTime.parse(message['timestamp'] as String).isUtc, isTrue);
    },
  );

  test(
    'an older incoming message does not replace newer chat metadata',
    () async {
      final newer = DateTime.utc(2026, 4, 5, 6, 20);
      final older = DateTime.utc(2026, 4, 5, 6, 7);

      await store.storeIncoming(
        payload: _payload(
          messageId: 'msg-newer',
          content: 'Newer',
          timestamp: newer,
        ),
        peer: remote,
      );
      final receipt = await store.storeIncoming(
        payload: _payload(
          messageId: 'msg-older',
          content: 'Older',
          timestamp: older,
        ),
        peer: remote,
      );

      expect(receipt.result, BleIncomingResult.stored);
      final chat = (await db.query('chats')).single;
      expect(chat['last_message'], 'Newer');
      expect(chat['last_message_time'], TimestampUtils.toUtcIso8601(newer));
      expect(chat['unread_count'], 2);
      expect(await db.query('messages'), hasLength(2));
    },
  );

  test(
    'acknowledges duplicates without inserting or incrementing unread',
    () async {
      await store.storeIncoming(
        payload: _payload(messageId: 'msg-1'),
        peer: remote,
      );
      final receipt = await store.storeIncoming(
        payload: _payload(messageId: 'msg-1'),
        peer: remote,
      );

      expect(receipt.result, BleIncomingResult.duplicate);
      expect(await db.query('messages'), hasLength(1));
      expect((await db.query('chats')).single['unread_count'], 1);
    },
  );

  test('rejects blocked peers without persistence', () async {
    await peers.insertPeer(remote);
    await peers.blockPeer(remote.peerId);

    final receipt = await store.storeIncoming(
      payload: _payload(messageId: 'msg-1'),
      peer: remote,
    );

    expect(receipt.result, BleIncomingResult.blocked);
    expect(await db.query('messages'), isEmpty);
    expect(await db.query('chats'), isEmpty);
  });

  test('handler validates sender, receiver, and encryption flags', () async {
    final handler = BleIncomingMessageHandler(identity: local, store: store);

    expect(
      () => handler.handle(
        _payload(receiverId: 'somebody-else'),
        peer: remote,
        linkedPeerId: remote.peerId,
      ),
      throwsA(isA<BleProtocolException>()),
    );
    expect(
      () => handler.handle(
        _payload(senderId: 'other-peer'),
        peer: remote,
        linkedPeerId: remote.peerId,
      ),
      throwsA(isA<BleProtocolException>()),
    );

    final result = await handler.handle(
      _payload(),
      peer: remote,
      linkedPeerId: remote.peerId,
    );
    expect(result, BleAckResult.stored);
  });

  test('notifies only when a new message is stored', () async {
    var notifications = 0;
    final handler = BleIncomingMessageHandler(
      identity: local,
      store: store,
      onStored: (payload, receipt) async {
        notifications++;
      },
    );

    final first = await handler.handle(
      _payload(messageId: 'msg-notify'),
      peer: remote,
      linkedPeerId: remote.peerId,
    );
    final duplicate = await handler.handle(
      _payload(messageId: 'msg-notify'),
      peer: remote,
      linkedPeerId: remote.peerId,
    );

    expect(first, BleAckResult.stored);
    expect(duplicate, BleAckResult.duplicate);
    expect(notifications, 1);
  });

  test('notification work does not block the delivery ACK', () async {
    final callbackStarted = Completer<void>();
    final callbackFinished = Completer<void>();
    final handler = BleIncomingMessageHandler(
      identity: local,
      store: store,
      onStored: (payload, receipt) {
        callbackStarted.complete();
        return callbackFinished.future;
      },
    );

    final result = await handler
        .handle(
          _payload(messageId: 'msg-nonblocking'),
          peer: remote,
          linkedPeerId: remote.peerId,
        )
        .timeout(const Duration(seconds: 1));

    expect(result, BleAckResult.stored);
    await callbackStarted.future;
    callbackFinished.complete();
  });

  test('a failed database write propagates instead of succeeding', () async {
    await db.execute('''
      CREATE TRIGGER fail_message_insert
      BEFORE INSERT ON messages
      BEGIN
        SELECT RAISE(ABORT, 'message write blocked');
      END
    ''');

    await expectLater(
      store.storeIncoming(
        payload: _payload(messageId: 'msg-fail'),
        peer: remote,
      ),
      throwsA(anything),
    );
    expect(await db.query('messages'), isEmpty);
  });
}

BleMessagePayload _payload({
  String messageId = 'msg-1',
  String senderId = 'device-remote',
  String receiverId = 'device-local',
  String content = 'Hello',
  DateTime? timestamp,
}) {
  return BleMessagePayload(
    metadata: BleMessageMetadata(
      messageId: messageId,
      senderId: senderId,
      receiverId: receiverId,
      messageType: MessageType.text.name,
      timestamp: timestamp ?? DateTime.utc(2026, 4, 5, 6, 7),
      ttl: 3600,
      contentLength: content.length,
      isEncrypted: false,
    ),
    content: content,
  );
}
