import 'package:sqflite/sqflite.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/database/database_helper.dart';

class MessageRepository {
  Future<Database> get _db => DatabaseHelper.database;

  Future<void> insertMessage(Message message) async {
    final db = await _db;
    await db.insert(
      'messages',
      message.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Message>> getMessagesByChatId(String chatId, {int limit = 50, int offset = 0}) async {
    final db = await _db;
    final maps = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp ASC',
      limit: limit,
      offset: offset,
    );
    return maps.map((m) => Message.fromMap(m)).toList();
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

  Future<void> updateMessageStatus(String messageId, MessageStatus status) async {
    final db = await _db;
    await db.update(
      'messages',
      {
        'status': status.name,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> updateMessageTransport(String messageId, MessageTransport transport) async {
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
    await db.delete('messages', where: 'message_id = ?', whereArgs: [messageId]);
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
