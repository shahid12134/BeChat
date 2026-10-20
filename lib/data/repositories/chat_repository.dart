import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:bechat/core/utils/timestamp_utils.dart';
import 'package:bechat/data/models/chat.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/database/database_helper.dart';

class ChatRepository {
  ChatRepository({Future<Database> Function()? database})
    : _openDatabase = database ?? (() => DatabaseHelper.database);

  final Future<Database> Function() _openDatabase;

  Future<Database> get _db => _openDatabase();

  Future<void> insertChat(Chat chat) async {
    final db = await _db;
    final now = DateTime.now();
    await db.insert(
      'chats',
      chat
          .copyWith(
            id: chat.id ?? const Uuid().v4(),
            createdAt: chat.createdAt ?? now,
            updatedAt: chat.updatedAt ?? now,
          )
          .toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<Chat> getOrCreateChatForPeer(Peer peer) async {
    final db = await _db;
    return db.transaction<Chat>((txn) async {
      final existing = await txn.query(
        'chats',
        where: 'peer_id = ?',
        whereArgs: [peer.peerId],
        orderBy: 'created_at ASC',
        limit: 1,
      );
      if (existing.isNotEmpty) return Chat.fromMap(existing.first);

      final now = DateTime.now();
      final chat = Chat(
        id: const Uuid().v4(),
        chatId: 'chat-${const Uuid().v4()}',
        peerId: peer.peerId,
        title: peer.displayName,
        unreadCount: 0,
        createdAt: now,
        updatedAt: now,
      );
      await txn.insert(
        'chats',
        chat.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return chat;
    });
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
      orderBy: 'created_at ASC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Chat.fromMap(maps.first);
  }

  Future<void> updateChat(Chat chat) async {
    final db = await _db;
    final map = chat.toMap()
      ..remove('id')
      ..remove('created_at')
      ..['updated_at'] = TimestampUtils.nowUtcIso8601();
    await db.update(
      'chats',
      map,
      where: 'chat_id = ?',
      whereArgs: [chat.chatId],
    );
  }

  Future<void> updateLastMessage(
    String chatId,
    String message,
    DateTime time,
  ) async {
    final db = await _db;
    await db.update(
      'chats',
      {
        'last_message': message,
        'last_message_time': TimestampUtils.toUtcIso8601(time),
        'updated_at': TimestampUtils.nowUtcIso8601(),
      },
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
  }

  Future<void> incrementUnreadCount(String chatId) async {
    final db = await _db;
    await db.rawUpdate(
      'UPDATE chats SET unread_count = unread_count + 1, updated_at = ? WHERE chat_id = ?',
      [TimestampUtils.nowUtcIso8601(), chatId],
    );
  }

  Future<void> resetUnreadCount(String chatId) async {
    final db = await _db;
    await db.update(
      'chats',
      {'unread_count': 0, 'updated_at': TimestampUtils.nowUtcIso8601()},
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
    final result = await db.rawQuery(
      'SELECT SUM(unread_count) as total FROM chats',
    );
    return (result.first['total'] as int?) ?? 0;
  }
}
