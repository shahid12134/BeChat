import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
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

      final updated = await txn.update(
        'chats',
        {
          'last_message': message.content,
          'last_message_time': message.timestamp.toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'chat_id = ?',
        whereArgs: [message.chatId],
      );
      if (updated != 1) {
        throw StateError('Chat not found for message ${message.messageId}');
      }
      return true;
    });
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
      {'status': status.name, 'updated_at': DateTime.now().toIso8601String()},
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
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
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
