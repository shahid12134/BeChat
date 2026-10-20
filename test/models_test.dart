import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/models/chat.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/attachment.dart';
import 'package:bechat/data/models/message_route.dart';

void main() {
  sqfliteFfiInit();

  group('Peer Model', () {
    test('should create Peer from map', () {
      final now = DateTime.now();
      final peer = Peer(
        peerId: 'peer-001',
        displayName: 'Alice',
        deviceName: 'Alice Phone',
        status: PeerStatus.online,
        signalStrength: -50,
        firstSeen: now,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      );

      final map = peer.toMap();
      final restored = Peer.fromMap(map);

      expect(restored.peerId, 'peer-001');
      expect(restored.displayName, 'Alice');
      expect(restored.deviceName, 'Alice Phone');
      expect(restored.status, PeerStatus.online);
      expect(restored.signalStrength, -50);
    });

    test('should copy with changes', () {
      final peer = Peer(
        peerId: 'peer-001',
        displayName: 'Alice',
        deviceName: 'Alice Phone',
      );

      final updated = peer.copyWith(displayName: 'Bob');
      expect(updated.displayName, 'Bob');
      expect(updated.peerId, 'peer-001');
    });
  });

  group('Chat Model', () {
    test('should create Chat from map', () {
      final now = DateTime.now();
      final chat = Chat(
        chatId: 'chat-001',
        peerId: 'peer-001',
        title: 'Alice',
        lastMessage: 'Hello',
        lastMessageTime: now,
        unreadCount: 2,
        createdAt: now,
        updatedAt: now,
      );

      final map = chat.toMap();
      final restored = Chat.fromMap(map);

      expect(restored.chatId, 'chat-001');
      expect(restored.peerId, 'peer-001');
      expect(restored.title, 'Alice');
      expect(restored.lastMessage, 'Hello');
      expect(restored.unreadCount, 2);
    });
  });

  group('Message Model', () {
    test('should create Message from map', () {
      final now = DateTime.now();
      final message = Message(
        messageId: 'msg-001',
        chatId: 'chat-001',
        senderId: 'local-device-001',
        receiverId: 'peer-001',
        content: 'Test message',
        timestamp: now,
        status: MessageStatus.sent,
        transport: MessageTransport.local,
        createdAt: now,
        updatedAt: now,
      );

      final map = message.toMap();
      final restored = Message.fromMap(map);

      expect(restored.messageId, 'msg-001');
      expect(restored.chatId, 'chat-001');
      expect(restored.content, 'Test message');
      expect(restored.status, MessageStatus.sent);
      expect(restored.transport, MessageTransport.local);
    });

    test('isSent returns true for local device', () {
      final message = Message(
        messageId: 'msg-001',
        chatId: 'chat-001',
        senderId: 'local-device-001',
        receiverId: 'peer-001',
        content: 'Test',
        timestamp: DateTime.now(),
      );

      expect(message.isSent, true);
    });

    test('isSent returns false for remote peer', () {
      final message = Message(
        messageId: 'msg-001',
        chatId: 'chat-001',
        senderId: 'peer-001',
        receiverId: 'local-device-001',
        content: 'Test',
        timestamp: DateTime.now(),
      );

      expect(message.isSent, false);
    });
  });

  group('Identity Model', () {
    test('should create Identity from map', () {
      final now = DateTime.now();
      final identity = Identity(
        deviceId: 'device-001',
        displayName: 'My Device',
        createdAt: now,
        updatedAt: now,
      );

      final map = identity.toMap();
      final restored = Identity.fromMap(map);

      expect(restored.deviceId, 'device-001');
      expect(restored.displayName, 'My Device');
    });
  });

  group('Attachment Model', () {
    test('should create Attachment from map', () {
      final attachment = Attachment(
        attachmentId: 'att-001',
        messageId: 'msg-001',
        fileName: 'photo.jpg',
        filePath: '/path/to/photo.jpg',
        mimeType: 'image/jpeg',
        fileSize: 1024,
        transferStatus: TransferStatus.pending,
      );

      final map = attachment.toMap();
      final restored = Attachment.fromMap(map);

      expect(restored.attachmentId, 'att-001');
      expect(restored.fileName, 'photo.jpg');
      expect(restored.fileSize, 1024);
      expect(restored.transferStatus, TransferStatus.pending);
    });
  });

  group('MessageRoute Model', () {
    test('should create MessageRoute from map', () {
      final now = DateTime.now();
      final route = MessageRoute(
        messageId: 'msg-001',
        targetPeer: 'peer-001',
        ttl: 3600,
        status: RouteStatus.queued,
        queuedAt: now,
        updatedAt: now,
      );

      final map = route.toMap();
      final restored = MessageRoute.fromMap(map);

      expect(restored.messageId, 'msg-001');
      expect(restored.targetPeer, 'peer-001');
      expect(restored.ttl, 3600);
      expect(restored.status, RouteStatus.queued);
    });
  });
}
