import 'dart:convert';

import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

enum BleIncomingResult { stored, duplicate, blocked }

class BleIncomingReceipt {
  const BleIncomingReceipt({
    required this.result,
    required this.chatId,
    required this.peerId,
  });

  final BleIncomingResult result;
  final String chatId;
  final String peerId;
}

class BleMessageStore {
  BleMessageStore({Future<Database> Function()? database})
    : _openDatabase = database ?? (() => DatabaseHelper.database);

  final Future<Database> Function() _openDatabase;

  Future<BleIncomingReceipt> storeIncoming({
    required BleMessagePayload payload,
    required Peer peer,
  }) async {
    final db = await _openDatabase();
    return db.transaction<BleIncomingReceipt>((txn) async {
      final existingPeer = await txn.query(
        'peers',
        columns: [
          'id',
          'display_name',
          'device_name',
          'avatar_path',
          'public_key',
          'is_blocked',
          'status',
          'first_seen',
        ],
        where: 'peer_id = ?',
        whereArgs: [peer.peerId],
        limit: 1,
      );

      final now = DateTime.now();
      if (existingPeer.isNotEmpty) {
        final row = existingPeer.first;
        if ((row['is_blocked'] as int?) == 1 ||
            row['status'] == PeerStatus.blocked.name) {
          return BleIncomingReceipt(
            result: BleIncomingResult.blocked,
            chatId: '',
            peerId: peer.peerId,
          );
        }
        await txn.update(
          'peers',
          {
            'display_name': peer.displayName,
            'device_name': peer.deviceName,
            'status': PeerStatus.online.name,
            'last_seen': now.toIso8601String(),
            'updated_at': now.toIso8601String(),
          },
          where: 'peer_id = ?',
          whereArgs: [peer.peerId],
        );
      } else {
        final insert = Peer(
          id: const Uuid().v4(),
          peerId: peer.peerId,
          displayName: peer.displayName,
          deviceName: peer.deviceName,
          status: PeerStatus.online,
          firstSeen: now,
          lastSeen: now,
          createdAt: now,
          updatedAt: now,
          isBlocked: false,
        );
        await txn.insert('peers', insert.toMap());
      }

      var chatRows = await txn.query(
        'chats',
        where: 'peer_id = ?',
        whereArgs: [peer.peerId],
        orderBy: 'created_at ASC',
        limit: 1,
      );
      if (chatRows.isEmpty) {
        final chat = {
          'id': const Uuid().v4(),
          'chat_id': 'chat-${const Uuid().v4()}',
          'peer_id': peer.peerId,
          'title': peer.displayName,
          'unread_count': 0,
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        };
        await txn.insert('chats', chat);
        chatRows = await txn.query(
          'chats',
          where: 'peer_id = ?',
          whereArgs: [peer.peerId],
          limit: 1,
        );
      }
      final chatId = chatRows.first['chat_id'] as String;

      final message = Message(
        id: const Uuid().v4(),
        messageId: payload.metadata.messageId,
        chatId: chatId,
        senderId: payload.metadata.senderId,
        receiverId: payload.metadata.receiverId,
        content: payload.content,
        messageType: MessageType.text,
        timestamp: payload.metadata.timestamp,
        status: MessageStatus.delivered,
        transport: MessageTransport.ble,
        ttl: payload.metadata.ttl,
        isEncrypted: false,
        createdAt: now,
        updatedAt: now,
      );
      final inserted = await txn.insert(
        'messages',
        message.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (inserted == 0) {
        return BleIncomingReceipt(
          result: BleIncomingResult.duplicate,
          chatId: chatId,
          peerId: peer.peerId,
        );
      }

      await txn.update(
        'chats',
        {
          'last_message': payload.content,
          'last_message_time': payload.metadata.timestamp.toIso8601String(),
          'unread_count': (chatRows.first['unread_count'] as int? ?? 0) + 1,
          'updated_at': now.toIso8601String(),
        },
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );

      return BleIncomingReceipt(
        result: BleIncomingResult.stored,
        chatId: chatId,
        peerId: peer.peerId,
      );
    });
  }
}

class BleIncomingMessageHandler {
  BleIncomingMessageHandler({
    required this.identity,
    required BleMessageStore store,
  }) : _store = store;

  final Identity identity;
  final BleMessageStore _store;

  Future<BleAckResult> handle(
    BleMessagePayload payload, {
    required Peer peer,
    required String linkedPeerId,
  }) async {
    if (payload.metadata.receiverId != identity.deviceId) {
      throw const BleProtocolException(
        'Incoming message receiver does not match local identity',
      );
    }
    if (payload.metadata.senderId != linkedPeerId ||
        peer.peerId != linkedPeerId) {
      throw const BleProtocolException(
        'Incoming message sender does not match linked peer',
      );
    }
    if (payload.metadata.isEncrypted) {
      throw const BleProtocolException(
        'Encrypted messages are not supported in Phase 2',
      );
    }
    if (utf8.encode(payload.content).length >
        BleProtocol.maxMessageContentBytes) {
      throw const BleProtocolException('Incoming message is too large');
    }

    final receipt = await _store.storeIncoming(payload: payload, peer: peer);
    return switch (receipt.result) {
      BleIncomingResult.stored => BleAckResult.stored,
      BleIncomingResult.duplicate => BleAckResult.duplicate,
      BleIncomingResult.blocked => BleAckResult.rejected,
    };
  }
}
