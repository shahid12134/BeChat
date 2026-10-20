import 'package:sqflite/sqflite.dart';
import 'package:bechat/data/models/chat.dart';
import 'package:bechat/data/database/database_helper.dart';

class ChatRepository {
  Future<Database> get _db => DatabaseHelper.database;

  Future<void> insertChat(Chat chat) async {
    final db = await _db;
    await db.insert(
      'chats',
      chat.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Chat>> getAllChats() async {
    final db = await _db;
    final maps = await db.query('chats', orderBy: 'last_message_time DESC');
    return maps.map((m) => Chat.fromMap(m)).toList();
  }

  Future<Chat?> getChatByChatId(String chatId) async {
    final db = await _db;
    final maps = await db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Chat.fromMap(maps.first);
  }

  Future<Chat?> getChatByPeerId(String peerId) async {
    final db = await _db;
    final maps = await db.query(
      'chats',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Chat.fromMap(maps.first);
  }

  Future<void> updateChat(Chat chat) async {
    final db = await _db;
    await db.update(
      'chats',
      chat.toMap(),
      where: 'chat_id = ?',
      whereArgs: [chat.chatId],
    );
  }

  Future<void> updateLastMessage(String chatId, String message, DateTime time) async {
    final db = await _db;
    await db.update(
      'chats',
      {
        'last_message': message,
        'last_message_time': time.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
  }

  Future<void> incrementUnreadCount(String chatId) async {
    final db = await _db;
    await db.rawUpdate(
      'UPDATE chats SET unread_count = unread_count + 1, updated_at = ? WHERE chat_id = ?',
      [DateTime.now().toIso8601String(), chatId],
    );
  }

  Future<void> resetUnreadCount(String chatId) async {
    final db = await _db;
    await db.update(
      'chats',
      {
        'unread_count': 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
  }

  Future<void> deleteChat(String chatId) async {
    final db = await _db;
    await db.delete('chats', where: 'chat_id = ?', whereArgs: [chatId]);
  }

  Future<int> getTotalUnreadCount() async {
    final db = await _db;
    final result = await db.rawQuery('SELECT SUM(unread_count) as total FROM chats');
    return (result.first['total'] as int?) ?? 0;
  }
}
