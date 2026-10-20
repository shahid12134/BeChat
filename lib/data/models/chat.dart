import 'package:bechat/core/utils/timestamp_utils.dart';

class Chat {
  final String? id;
  final String chatId;
  final String peerId;
  final String? title;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Chat({
    this.id,
    required this.chatId,
    required this.peerId,
    this.title,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
    this.createdAt,
    this.updatedAt,
  });

  Chat copyWith({
    String? id,
    String? chatId,
    String? peerId,
    String? title,
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Chat(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      peerId: peerId ?? this.peerId,
      title: title ?? this.title,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'chat_id': chatId,
      'peer_id': peerId,
      'title': title,
      'last_message': lastMessage,
      'last_message_time': lastMessageTime == null
          ? null
          : TimestampUtils.toUtcIso8601(lastMessageTime!),
      'unread_count': unreadCount,
      'created_at': createdAt == null
          ? null
          : TimestampUtils.toUtcIso8601(createdAt!),
      'updated_at': updatedAt == null
          ? null
          : TimestampUtils.toUtcIso8601(updatedAt!),
    };
  }

  factory Chat.fromMap(Map<String, dynamic> map) {
    return Chat(
      id: map['id'] as String?,
      chatId: map['chat_id'] as String,
      peerId: map['peer_id'] as String,
      title: map['title'] as String?,
      lastMessage: map['last_message'] as String?,
      lastMessageTime: map['last_message_time'] != null
          ? DateTime.parse(map['last_message_time'] as String)
          : null,
      unreadCount: (map['unread_count'] as int?) ?? 0,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'] as String)
          : null,
    );
  }
}
