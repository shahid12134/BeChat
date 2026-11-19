import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:bechat/core/utils/timestamp_utils.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/database/database_helper.dart';

class MessageRepository {
  MessageRepository({Future<Database> Function()? database})
    : _openDatabase = database ?? (() => DatabaseHelper.database);

  final Future<Database> Function() _openDatabase;

  Future<Database> get _db => _openDatabase();

  Map<String, dynamic> _insertMap(Message message) {
    final insert = message.id == null
        ? message.copyWith(id: const Uuid().v4())
        : message;
    return insert.toMap();
  }

  Future<void> insertMessage(Message message) async {
    final db = await _db;
    await db.insert(
      'messages',
      _insertMap(message),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<bool> insertMessageAndUpdateChat(Message message) async {
    final db = await _db;
    return db.transaction<bool>((txn) async {
      final inserted = await txn.insert(
        'messages',
        _insertMap(message),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (inserted == 0) return false;

      final chatRows = await txn.query(
        'chats',
        columns: ['last_message_time'],
        where: 'chat_id = ?',
        whereArgs: [message.chatId],
        limit: 1,
      );
      if (chatRows.isEmpty) {
        throw StateError('Chat not found for message ${message.messageId}');
      }

      final messageTime = TimestampUtils.toUtcIso8601(message.timestamp);
      final storedTime = chatRows.first['last_message_time'] as String?;
      if (_isNewerThanStored(messageTime, storedTime)) {
        await txn.update(
          'chats',
          {
            'last_message': message.content,
            'last_message_time': messageTime,
            'updated_at': TimestampUtils.nowUtcIso8601(),
          },
          where: 'chat_id = ?',
          whereArgs: [message.chatId],
        );
      }
      return true;
    });
  }

  static bool _isNewerThanStored(String candidate, String? stored) {
    if (stored == null) return true;
    final candidateTime = DateTime.tryParse(candidate);
    final storedTime = DateTime.tryParse(stored);
    if (candidateTime == null || storedTime == null) return true;
    return candidateTime.isAfter(storedTime);
  }

  Future<List<Message>> getMessagesByChatId(
    String chatId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await _db;
    final maps = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp DESC, message_id DESC',
      limit: limit,
      offset: offset,
    );
    return maps.reversed.map((m) => Message.fromMap(m)).toList();
  }

  Future<Message?> getMessageByMessageId(String messageId) async {
    final db = await _db;
    final maps = await db.query(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Message.fromMap(maps.first);
  }

  Future<void> updateMessageStatus(
    String messageId,
    MessageStatus status,
  ) async {
    final db = await _db;
    await db.update(
      'messages',
      {'status': status.name, 'updated_at': TimestampUtils.nowUtcIso8601()},
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> updateMessageTransport(
    String messageId,
    MessageTransport transport,
  ) async {
    final db = await _db;
    await db.update(
      'messages',
      {
        'transport': transport.name,
        'updated_at': TimestampUtils.nowUtcIso8601(),
      },
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> markMessageSending(String messageId) async {
    await _updateDeliveryStatus(
      messageId,
      MessageStatus.sending,
      MessageTransport.ble,
    );
  }

  /// Atomically claims a queued message for one transport, so the online
  /// relay and the BLE outbox can never send the same message at once:
  /// the conditional UPDATE succeeds for exactly one caller.
  Future<bool> tryClaimForSending(String messageId) async {
    final db = await _db;
    final updated = await db.update(
      'messages',
      {
        'status': MessageStatus.sending.name,
        'updated_at': TimestampUtils.nowUtcIso8601(),
      },
      where: 'message_id = ? AND status = ?',
      whereArgs: [messageId, MessageStatus.queued.name],
    );
    return updated == 1;
  }

  Future<void> markMessageSent(String messageId) async {
    await _updateDeliveryStatus(
      messageId,
      MessageStatus.sent,
      MessageTransport.ble,
    );
  }

  Future<void> markMessageDelivered(String messageId) async {
    await _updateDeliveryStatus(
      messageId,
      MessageStatus.delivered,
      MessageTransport.ble,
    );
  }

  Future<void> markMessageFailed(String messageId) async {
    await _updateDeliveryStatus(
      messageId,
      MessageStatus.failed,
      MessageTransport.ble,
    );
  }

  Future<void> requeueMessage(String messageId) async {
    await _updateDeliveryStatus(
      messageId,
      MessageStatus.queued,
      MessageTransport.pending,
    );
  }

  Future<void> _updateDeliveryStatus(
    String messageId,
    MessageStatus status,
    MessageTransport transport,
  ) async {
    final db = await _db;
    await db.update(
      'messages',
      {
        'status': status.name,
        'transport': transport.name,
        'updated_at': TimestampUtils.nowUtcIso8601(),
      },
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> resetOutboxForSender(String senderId) async {
    final db = await _db;
    await db.update(
      'messages',
      {
        'status': MessageStatus.queued.name,
        'transport': MessageTransport.pending.name,
        'updated_at': TimestampUtils.nowUtcIso8601(),
      },
      where: 'sender_id = ? AND status IN (?, ?)',
      whereArgs: [
        senderId,
        MessageStatus.sending.name,
        MessageStatus.sent.name,
      ],
    );
  }

  /// Queued outgoing messages for [senderId].
  ///
  /// [excludeAttachments] lets the BLE drain skip media: attachment bytes
  /// never travel over BLE or the multi-hop relay, so those messages wait for
  /// the online transport instead of being sent as a bare text label.
  Future<List<Message>> getQueuedOutgoingMessages(
    String senderId, {
    bool excludeAttachments = false,
  }) async {
    final db = await _db;
    final maps = await db.query(
      'messages',
      where:
          'sender_id = ? AND status = ? AND receiver_id <> ?'
          '${excludeAttachments ? ' AND attachment_json IS NULL' : ''}',
      whereArgs: [senderId, MessageStatus.queued.name, senderId],
      orderBy: 'timestamp ASC, message_id ASC',
    );
    return maps.map((message) => Message.fromMap(message)).toList();
  }

  Future<void> deleteMessage(String messageId) async {
    final db = await _db;
    await db.delete(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> deleteAllMessagesForChat(String chatId) async {
    final db = await _db;
    await db.delete('messages', where: 'chat_id = ?', whereArgs: [chatId]);
  }

  Future<int> getMessageCountForChat(String chatId) async {
    final db = await _db;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM messages WHERE chat_id = ?',
      [chatId],
    );
    return (result.first['count'] as int?) ?? 0;
  }
}
