import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/models/chat.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/core/constants/app_constants.dart';

class MockData {
  static Future<void> seedIfEmpty() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM peers');
    final count = (result.first['count'] as int?) ?? 0;
    if (count > 0) return;

    final now = DateTime.now();
    final deviceId = AppConstants.placeholderDeviceId;

    final identity = Identity(
      deviceId: deviceId,
      displayName: 'You',
      createdAt: now,
      updatedAt: now,
    );
    await DatabaseHelper.database.then((db) =>
        db.insert('identity', identity.toMap()..remove('id')));

    final peers = [
      Peer(
        peerId: 'peer-alice-001',
        displayName: 'Alice',
        deviceName: "Alice's Phone",
        status: PeerStatus.online,
        signalStrength: -45,
        firstSeen: now.subtract(const Duration(hours: 2)),
        lastSeen: now,
        createdAt: now.subtract(const Duration(days: 2)),
        updatedAt: now,
      ),
      Peer(
        peerId: 'peer-rahul-002',
        displayName: 'Rahul',
        deviceName: "Rahul's Phone",
        status: PeerStatus.online,
        signalStrength: -62,
        firstSeen: now.subtract(const Duration(hours: 5)),
        lastSeen: now.subtract(const Duration(minutes: 5)),
        createdAt: now.subtract(const Duration(days: 3)),
        updatedAt: now,
      ),
      Peer(
        peerId: 'peer-device-003',
        displayName: 'BeChat Lab Device',
        deviceName: 'BeChat Device 01',
        status: PeerStatus.offline,
        signalStrength: -78,
        firstSeen: now.subtract(const Duration(days: 3)),
        lastSeen: now.subtract(const Duration(hours: 1)),
        createdAt: now.subtract(const Duration(days: 5)),
        updatedAt: now,
      ),
      Peer(
        peerId: 'peer-cyber-004',
        displayName: 'Cyber Lab',
        deviceName: 'Cyber Lab Device',
        status: PeerStatus.online,
        signalStrength: -55,
        firstSeen: now.subtract(const Duration(days: 1)),
        lastSeen: now.subtract(const Duration(minutes: 2)),
        createdAt: now.subtract(const Duration(days: 7)),
        updatedAt: now,
      ),
      Peer(
        peerId: 'peer-maria-005',
        displayName: 'Maria',
        deviceName: "Maria's Phone",
        status: PeerStatus.offline,
        signalStrength: -88,
        firstSeen: now.subtract(const Duration(days: 7)),
        lastSeen: now.subtract(const Duration(hours: 3)),
        createdAt: now.subtract(const Duration(days: 10)),
        updatedAt: now,
      ),
    ];

    for (final peer in peers) {
      await db.insert('peers', peer.toMap()..remove('id'));
    }

    final chats = [
      Chat(
        chatId: 'chat-alice-001',
        peerId: 'peer-alice-001',
        title: 'Alice',
        lastMessage: 'Hey! Are you coming to the lab today?',
        lastMessageTime: now.subtract(const Duration(minutes: 15)),
        unreadCount: 2,
        createdAt: now.subtract(const Duration(days: 2)),
        updatedAt: now,
      ),
      Chat(
        chatId: 'chat-rahul-002',
        peerId: 'peer-rahul-002',
        title: 'Rahul',
        lastMessage: 'The BLE module is working great!',
        lastMessageTime: now.subtract(const Duration(hours: 1)),
        unreadCount: 0,
        createdAt: now.subtract(const Duration(days: 3)),
        updatedAt: now,
      ),
      Chat(
        chatId: 'chat-cyber-004',
        peerId: 'peer-cyber-004',
        title: 'Cyber Lab',
        lastMessage: 'Lab session starts at 3 PM',
        lastMessageTime: now.subtract(const Duration(hours: 3)),
        unreadCount: 1,
        createdAt: now.subtract(const Duration(days: 1)),
        updatedAt: now,
      ),
    ];

    for (final chat in chats) {
      await db.insert('chats', chat.toMap()..remove('id'));
    }

    final messages = [
      Message(
        messageId: 'msg-001',
        chatId: 'chat-alice-001',
        senderId: 'peer-alice-001',
        receiverId: deviceId,
        content: 'Hey! How is the project going?',
        timestamp: now.subtract(const Duration(hours: 2)),
        status: MessageStatus.delivered,
        transport: MessageTransport.local,
        createdAt: now.subtract(const Duration(hours: 2)),
        updatedAt: now.subtract(const Duration(hours: 2)),
      ),
      Message(
        messageId: 'msg-002',
        chatId: 'chat-alice-001',
        senderId: deviceId,
        receiverId: 'peer-alice-001',
        content: 'Going well! The architecture is almost ready.',
        timestamp: now.subtract(const Duration(hours: 1, minutes: 55)),
        status: MessageStatus.delivered,
        transport: MessageTransport.local,
        createdAt: now.subtract(const Duration(hours: 1, minutes: 55)),
        updatedAt: now.subtract(const Duration(hours: 1, minutes: 55)),
      ),
      Message(
        messageId: 'msg-003',
        chatId: 'chat-alice-001',
        senderId: 'peer-alice-001',
        receiverId: deviceId,
        content: 'That sounds great! Can you show me the database schema?',
        timestamp: now.subtract(const Duration(hours: 1, minutes: 30)),
        status: MessageStatus.delivered,
        transport: MessageTransport.local,
        createdAt: now.subtract(const Duration(hours: 1, minutes: 30)),
        updatedAt: now.subtract(const Duration(hours: 1, minutes: 30)),
      ),
      Message(
        messageId: 'msg-004',
        chatId: 'chat-alice-001',
        senderId: deviceId,
        receiverId: 'peer-alice-001',
        content: 'Sure! I have set up the full schema with support for future encryption and routing.',
        timestamp: now.subtract(const Duration(hours: 1, minutes: 20)),
        status: MessageStatus.delivered,
        transport: MessageTransport.local,
        createdAt: now.subtract(const Duration(hours: 1, minutes: 20)),
        updatedAt: now.subtract(const Duration(hours: 1, minutes: 20)),
      ),
      Message(
        messageId: 'msg-005',
        chatId: 'chat-alice-001',
        senderId: 'peer-alice-001',
        receiverId: deviceId,
        content: 'Nice! We should test it with the mock peers.',
        timestamp: now.subtract(const Duration(minutes: 30)),
        status: MessageStatus.delivered,
        transport: MessageTransport.local,
        createdAt: now.subtract(const Duration(minutes: 30)),
        updatedAt: now.subtract(const Duration(minutes: 30)),
      ),
      Message(
        messageId: 'msg-006',
        chatId: 'chat-alice-001',
        senderId: 'peer-alice-001',
        receiverId: deviceId,
        content: 'Hey! Are you coming to the lab today?',
        timestamp: now.subtract(const Duration(minutes: 15)),
        status: MessageStatus.delivered,
        transport: MessageTransport.local,
        createdAt: now.subtract(const Duration(minutes: 15)),
        updatedAt: now.subtract(const Duration(minutes: 15)),
      ),
      // Rahul chat messages
      Message(
        messageId: 'msg-010',
        chatId: 'chat-rahul-002',
        senderId: 'peer-rahul-002',
        receiverId: deviceId,
        content: 'Did you check the BLE scanning code?',
        timestamp: now.subtract(const Duration(hours: 3)),
        status: MessageStatus.delivered,
        transport: MessageTransport.local,
        createdAt: now.subtract(const Duration(hours: 3)),
        updatedAt: now.subtract(const Duration(hours: 3)),
      ),
      Message(
        messageId: 'msg-011',
        chatId: 'chat-rahul-002',
        senderId: deviceId,
        receiverId: 'peer-rahul-002',
        content: 'Yes! It looks solid. The peer discovery abstraction is clean.',
        timestamp: now.subtract(const Duration(hours: 2, minutes: 45)),
        status: MessageStatus.delivered,
        transport: MessageTransport.local,
        createdAt: now.subtract(const Duration(hours: 2, minutes: 45)),
        updatedAt: now.subtract(const Duration(hours: 2, minutes: 45)),
      ),
      Message(
        messageId: 'msg-012',
        chatId: 'chat-rahul-002',
        senderId: 'peer-rahul-002',
        receiverId: deviceId,
        content: 'The BLE module is working great!',
        timestamp: now.subtract(const Duration(hours: 1)),
        status: MessageStatus.delivered,
        transport: MessageTransport.local,
        createdAt: now.subtract(const Duration(hours: 1)),
        updatedAt: now.subtract(const Duration(hours: 1)),
      ),
      // Cyber Lab messages
      Message(
        messageId: 'msg-020',
        chatId: 'chat-cyber-004',
        senderId: 'peer-cyber-004',
        receiverId: deviceId,
        content: 'Lab session starts at 3 PM',
        timestamp: now.subtract(const Duration(hours: 3)),
        status: MessageStatus.delivered,
        transport: MessageTransport.local,
        createdAt: now.subtract(const Duration(hours: 3)),
        updatedAt: now.subtract(const Duration(hours: 3)),
      ),
    ];

    for (final msg in messages) {
      await db.insert('messages', msg.toMap()..remove('id'));
    }
  }
}
