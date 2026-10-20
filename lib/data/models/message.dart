import 'package:bechat/core/utils/timestamp_utils.dart';

enum MessageType { text, image, file, system }

enum MessageStatus { queued, sending, sent, delivered, read, failed }

enum MessageTransport { local, ble, mesh, cloud, pending }

class Message {
  final String? id;
  final String messageId;
  final String chatId;
  final String senderId;
  final String receiverId;
  final String content;
  final MessageType messageType;
  final DateTime timestamp;
  final MessageStatus status;
  final MessageTransport transport;
  final int ttl;
  final bool isEncrypted;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Message({
    this.id,
    required this.messageId,
    required this.chatId,
    required this.senderId,
    required this.receiverId,
    required this.content,
    this.messageType = MessageType.text,
    required this.timestamp,
    this.status = MessageStatus.queued,
    this.transport = MessageTransport.pending,
    this.ttl = 86400,
    this.isEncrypted = false,
    this.createdAt,
    this.updatedAt,
  });

  bool isSentBy(String localDeviceId) => senderId == localDeviceId;

  Message copyWith({
    String? id,
    String? messageId,
    String? chatId,
    String? senderId,
    String? receiverId,
    String? content,
    MessageType? messageType,
    DateTime? timestamp,
    MessageStatus? status,
    MessageTransport? transport,
    int? ttl,
    bool? isEncrypted,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Message(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      chatId: chatId ?? this.chatId,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      content: content ?? this.content,
      messageType: messageType ?? this.messageType,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      transport: transport ?? this.transport,
      ttl: ttl ?? this.ttl,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'message_id': messageId,
      'chat_id': chatId,
      'sender_id': senderId,
      'receiver_id': receiverId,
      'content': content,
      'message_type': messageType.name,
      'timestamp': TimestampUtils.toUtcIso8601(timestamp),
      'status': status.name,
      'transport': transport.name,
      'ttl': ttl,
      'is_encrypted': isEncrypted ? 1 : 0,
      'created_at': createdAt == null
          ? null
          : TimestampUtils.toUtcIso8601(createdAt!),
      'updated_at': updatedAt == null
          ? null
          : TimestampUtils.toUtcIso8601(updatedAt!),
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as String?,
      messageId: map['message_id'] as String,
      chatId: map['chat_id'] as String,
      senderId: map['sender_id'] as String,
      receiverId: map['receiver_id'] as String,
      content: map['content'] as String,
      messageType: MessageType.values.firstWhere(
        (e) => e.name == map['message_type'],
        orElse: () => MessageType.text,
      ),
      timestamp: DateTime.parse(map['timestamp'] as String),
      status: MessageStatus.values.firstWhere(
        (e) => e.name == map['status'],
        orElse: () => MessageStatus.sent,
      ),
      transport: MessageTransport.values.firstWhere(
        (e) => e.name == map['transport'],
        orElse: () => MessageTransport.pending,
      ),
      ttl: (map['ttl'] as int?) ?? 86400,
      isEncrypted: (map['is_encrypted'] as int?) == 1,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'] as String)
          : null,
    );
  }
}
