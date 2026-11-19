import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/message_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/services/ble/ble_message_store.dart';
import 'package:bechat/services/online/device_registry.dart';
import 'package:bechat/services/online/firebase_bootstrap.dart';
import 'package:bechat/services/online/firestore_online_transport.dart';
import 'package:bechat/services/online/online_transport.dart';
import 'package:bechat/services/online/transport_manager.dart';

import 'helpers/test_database.dart';

void main() {
  final managers = <TransportManager>[];

  tearDown(() async {
    for (final manager in managers) {
      manager.dispose();
    }
    managers.clear();
  });

  group('firebase startup', () {
    test('a failed initialization is clean and retryable', () async {
      Object? first;
      try {
        await FirebaseBootstrap.ensureInitialized();
      } catch (error) {
        first = error;
      }
      // `flutter test` registers no Firebase platform, so initialization must
      // fail — but it must fail loudly rather than half-succeed.
      expect(first, isNotNull);
      expect(Firebase.apps, isEmpty);

      Object? second;
      try {
        await FirebaseBootstrap.ensureInitialized();
      } catch (error) {
        second = error;
      }
      expect(second, isNotNull, reason: 'a retry behaves exactly the same');
    });

    test('anonymous sign-in failure leaves the transport offline, never ready', () async {
      final transport = FirestoreOnlineTransport(deviceId: 'device-a');
      await transport.start();

      expect(transport.state, OnlineConnectionState.disconnected);
      expect(transport.isReady, isFalse);
      await transport.stop();
    });
  });

  group('device registry', () {
    test('binds a new device id to the authenticated uid', () {
      expect(resolveBinding(null, 'uid-1'), RegistryBinding.created);
    });

    test('an existing registration owned by the same uid is adopted', () {
      expect(resolveBinding('uid-1', 'uid-1'), RegistryBinding.alreadyOwned);
    });

    test('a registration owned by another uid is a conflict and is never rebound', () {
      expect(resolveBinding('uid-other', 'uid-1'), RegistryBinding.conflict);
      // The conflict branch must be distinguishable from "adopt": only
      // `created` may write.
      expect(resolveBinding('uid-other', 'uid-1') == RegistryBinding.created, isFalse);
      expect(resolveBinding('', 'uid-1'), RegistryBinding.conflict);
    });
  });

  group('firestore transport', () {
    test('online send reaches the recipient and the ack marks final delivery', () async {
      final server = _FakeFirestore();
      final sender = await _makeDevice('device-a', server);
      final recipient = await _makeDevice('device-b', server);
      final sendManager = sender.startManager();
      final receiveManager = recipient.startManager();
      managers.addAll([sendManager, receiveManager]);
      await sendManager.start();
      await receiveManager.start();
      expect(sendManager.state.mode, TransportMode.online);
      expect(receiveManager.state.mode, TransportMode.online);

      await sender.messages.insertMessage(_outgoing('msg-1'));
      await sendManager.onMessageQueued('device-b');

      // Server acceptance is only "sent" — never the final "delivered".
      expect(await _status(sender.messages, 'msg-1'), MessageStatus.sent);
      expect(
        (await sender.messages.getMessageByMessageId('msg-1'))!.transport,
        MessageTransport.cloud,
      );
      expect(server.docs['msg-1']!['status'], 'sent');

      await waitFor(
        () async => (await recipient.messages.getMessageByMessageId('msg-1')) != null,
        reason: 'recipient should store the message',
      );
      final stored = (await recipient.messages.getMessageByMessageId('msg-1'))!;
      expect(stored.senderId, 'device-a');
      expect(stored.receiverId, 'device-b');
      expect(stored.transport, MessageTransport.cloud);

      await waitFor(
        () async => await _status(sender.messages, 'msg-1') == MessageStatus.delivered,
        reason: 'sender should receive the delivery acknowledgement',
      );
      expect(server.docs['msg-1']!['status'], 'delivered');
    });

    test('an unregistered recipient is rejected instead of silently dropped', () async {
      final server = _FakeFirestore();
      final sender = await _makeDevice('device-a', server);
      final manager = sender.startManager();
      managers.add(manager);
      await manager.start();

      // device-b never registered: send must fail, which requeues + BLE.
      await sender.messages.insertMessage(_outgoing('msg-unregistered'));
      await manager.onMessageQueued('device-b');

      expect(server.docs, isNot(contains('msg-unregistered')));
      expect(await _status(sender.messages, 'msg-unregistered'), MessageStatus.queued);
      expect(sender.bleRequests, contains('device-b'));
    });

    test('messages for an offline recipient are held until it connects', () async {
      final server = _FakeFirestore();
      final sender = await _makeDevice('device-a', server);
      server.register('device-b');
      final sendManager = sender.startManager();
      managers.add(sendManager);
      await sendManager.start();

      await sender.messages.insertMessage(_outgoing('msg-offline'));
      await sendManager.onMessageQueued('device-b');

      expect(await _status(sender.messages, 'msg-offline'), MessageStatus.sent);
      expect(server.docs, contains('msg-offline'));

      final recipient = await _makeDevice('device-b', server);
      final receiveManager = recipient.startManager();
      managers.add(receiveManager);
      await receiveManager.start();

      await waitFor(
        () async => (await recipient.messages.getMessageByMessageId('msg-offline')) != null,
        reason: 'queued message should flush to the recipient',
      );
      await waitFor(
        () async => await _status(sender.messages, 'msg-offline') == MessageStatus.delivered,
        reason: 'ack should flow back once the recipient is reachable',
      );
    });

    test('a recipient reconnects and receives everything sent while it was away', () async {
      final server = _FakeFirestore();
      final sender = await _makeDevice('device-a', server);
      server.register('device-b');
      final sendManager = sender.startManager();
      managers.add(sendManager);
      await sendManager.start();

      // Recipient is configured but its backend is unreachable.
      final recipient = await _makeDevice('device-b', server);
      final receiveManager = recipient.startManager();
      managers.add(receiveManager);
      recipient.transport!.reachable = false;
      await receiveManager.start();
      expect(receiveManager.state.mode, isNot(TransportMode.online));

      await sender.messages.insertMessage(_outgoing('msg-missed-1'));
      await sender.messages.insertMessage(_outgoing('msg-missed-2'));
      await sendManager.onMessageQueued('device-b');
      expect(await _status(sender.messages, 'msg-missed-1'), MessageStatus.sent);

      // Backend comes back: both are delivered without any resend by the sender.
      await recipient.transport!.regainConnection();
      expect(receiveManager.state.mode, TransportMode.online);

      for (final id in ['msg-missed-1', 'msg-missed-2']) {
        await waitFor(
          () async => (await recipient.messages.getMessageByMessageId(id)) != null,
          reason: '$id should reach the reconnecting recipient',
        );
      }
      expect(
        await recipient.db.query('messages', where: 'message_id = ?', whereArgs: ['msg-missed-1']),
        hasLength(1),
        reason: 'no duplicate row',
      );
      await waitFor(
        () async => await _status(sender.messages, 'msg-missed-1') == MessageStatus.delivered,
        reason: 'sender should be told about final delivery',
      );
    });

    test('delivery is acknowledged only after the message is stored locally', () async {
      final server = _FakeFirestore();
      final sender = await _makeDevice('device-a', server);
      final recipient = await _makeDevice('device-b', server, store: _FailingStore());
      final sendManager = sender.startManager();
      final receiveManager = recipient.startManager();
      managers.addAll([sendManager, receiveManager]);
      await sendManager.start();
      await receiveManager.start();

      await sender.messages.insertMessage(_outgoing('msg-broken'));
      await sendManager.onMessageQueued('device-b');
      expect(await _status(sender.messages, 'msg-broken'), MessageStatus.sent);

      // Local persistence failed, so no ack may be written: the message stays
      // 'sent' server-side and is offered again on the next snapshot.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.docs['msg-broken']!['status'], 'sent');
      expect(await _status(sender.messages, 'msg-broken'), MessageStatus.sent);
      expect(await recipient.db.query('messages'), isEmpty);
    });

    test('duplicate prevention: one claim, one document, one stored row', () async {
      final server = _FakeFirestore();
      final sender = await _makeDevice('device-a', server);
      final recipient = await _makeDevice('device-b', server);
      final sendManager = sender.startManager();
      final receiveManager = recipient.startManager();
      managers.addAll([sendManager, receiveManager]);
      await sendManager.start();
      await receiveManager.start();

      await sender.messages.insertMessage(_outgoing('msg-dup'));

      // The claim is a one-shot conditional update: the second caller loses.
      expect(await sender.messages.tryClaimForSending('msg-dup'), isTrue);
      expect(await sender.messages.tryClaimForSending('msg-dup'), isFalse);

      // While another transport owns it, the online dispatch skips it.
      await sendManager.onMessageQueued('device-b');
      expect(await _status(sender.messages, 'msg-dup'), MessageStatus.sending);
      expect(sender.bleRequests, isEmpty);

      // The owning transport releases it (failure path) and online takes over.
      await sender.messages.requeueMessage('msg-dup');
      await sendManager.onMessageQueued('device-b');
      expect(await _status(sender.messages, 'msg-dup'), MessageStatus.sent);
      expect(server.docs, contains('msg-dup'));

      // Two simultaneous dispatches of the same message.
      await sender.messages.requeueMessage('msg-dup');
      await Future.wait([
        sendManager.onMessageQueued('device-b'),
        sendManager.onMessageQueued('device-b'),
      ]);
      await waitFor(
        () async => (await recipient.messages.getMessageByMessageId('msg-dup')) != null,
        reason: 'recipient should store the message',
      );

      // A resend of a message the backend already holds stays a single document.
      await sender.messages.requeueMessage('msg-dup');
      await sendManager.onMessageQueued('device-b');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(server.docs, contains('msg-dup'));
      expect(
        await recipient.db.query('messages', where: 'message_id = ?', whereArgs: ['msg-dup']),
        hasLength(1),
        reason: 'exactly one local row regardless of how many times it was sent',
      );
      expect(sender.bleRequests, isEmpty, reason: 'never dispatched over both transports');
    });

    test('losing the server mid-session falls back to BLE without failing the message', () async {
      final server = _FakeFirestore();
      final sender = await _makeDevice('device-a', server);
      final recipient = await _makeDevice('device-b', server);
      final sendManager = sender.startManager();
      final receiveManager = recipient.startManager();
      managers.addAll([sendManager, receiveManager]);
      await sendManager.start();
      await receiveManager.start();

      await sender.messages.insertMessage(_outgoing('msg-before'));
      await sendManager.onMessageQueued('device-b');
      await waitFor(
        () async => await _status(sender.messages, 'msg-before') == MessageStatus.delivered,
        reason: 'baseline delivery should complete',
      );

      // The backend stops answering while the manager still believes it ready:
      // the write itself must fail and hand the message to BLE.
      sender.transport!.reachable = false;
      await sender.messages.insertMessage(_outgoing('msg-during'));
      await sendManager.onMessageQueued('device-b');

      expect(await _status(sender.messages, 'msg-during'), MessageStatus.queued);
      expect(sender.bleRequests, contains('device-b'));
      expect(
        await _status(sender.messages, 'msg-before'),
        MessageStatus.delivered,
        reason: 'already-delivered messages are untouched by the outage',
      );
    });

    test('pending messages switch to online automatically when the backend returns', () async {
      final server = _FakeFirestore();
      final sender = await _makeDevice('device-a', server);
      final manager = sender.startManager();
      managers.add(manager);
      sender.transport!.reachable = false;
      await manager.start();
      expect(manager.state.mode, isNot(TransportMode.online));

      await sender.messages.insertMessage(_outgoing('msg-late'));
      await manager.onMessageQueued('device-b');
      expect(sender.bleRequests, contains('device-b'));
      expect(await _status(sender.messages, 'msg-late'), MessageStatus.queued);

      // Backend returns: the ready transition drains the queue by itself.
      server.register('device-b');
      await sender.transport!.regainConnection();
      expect(manager.state.mode, TransportMode.online);

      await waitFor(
        () async => await _status(sender.messages, 'msg-late') == MessageStatus.sent,
        reason: 'queued message should be sent once online',
      );
    });

    test('queued messages persisted before startup are synced after connecting', () async {
      final server = _FakeFirestore();
      final sender = await _makeDevice('device-a', server);
      final recipient = await _makeDevice('device-b', server);

      // Rows exist before any transport manager was ever created — the state
      // an app restart leaves behind.
      await sender.messages.insertMessage(_outgoing('msg-pre-1'));
      await sender.messages.insertMessage(_outgoing('msg-pre-2'));

      final sendManager = sender.startManager();
      final receiveManager = recipient.startManager();
      managers.addAll([sendManager, receiveManager]);
      await receiveManager.start();
      await sendManager.start();

      await waitFor(
        () async =>
            await _status(sender.messages, 'msg-pre-1') == MessageStatus.delivered &&
            await _status(sender.messages, 'msg-pre-2') == MessageStatus.delivered,
        reason: 'persisted messages should sync and deliver after restart',
      );
      for (final id in ['msg-pre-1', 'msg-pre-2']) {
        expect(
          await recipient.db.query('messages', where: 'message_id = ?', whereArgs: [id]),
          hasLength(1),
          reason: '$id must be stored exactly once',
        );
      }
    });
  });
}

Future<void> waitFor(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (await condition()) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('$reason not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Message _outgoing(String messageId, {String from = 'device-a', String to = 'device-b'}) {
  final now = DateTime.now();
  return Message(
    messageId: messageId,
    chatId: 'chat-1',
    senderId: from,
    receiverId: to,
    content: 'hello $messageId',
    timestamp: now,
    status: MessageStatus.queued,
    transport: MessageTransport.pending,
    createdAt: now,
    updatedAt: now,
  );
}

Future<MessageStatus?> _status(MessageRepository repository, String messageId) async {
  return (await repository.getMessageByMessageId(messageId))?.status;
}

Future<_Device> _makeDevice(
  String deviceId,
  _FakeFirestore server, {
  BleMessageStore? store,
}) async {
  final db = await openTestDatabase();
  // Every message row needs an existing chat (FK), and every chat needs its
  // peer — the same shape the app's own flows guarantee.
  final now = DateTime.now().toUtc().toIso8601String();
  await db.insert('peers', {
    'id': 'peer-$deviceId',
    'peer_id': 'device-b',
    'display_name': 'Peer B',
    'device_name': 'Peer B Phone',
    'created_at': now,
    'updated_at': now,
  });
  await db.insert('chats', {
    'id': 'chat-$deviceId',
    'chat_id': 'chat-1',
    'peer_id': 'device-b',
    'title': 'Peer B',
    'created_at': now,
    'updated_at': now,
  });
  Future<Database> dbf() async => db;
  return _Device(
    deviceId: deviceId,
    db: db,
    server: server,
    messages: MessageRepository(database: dbf),
    peers: PeerRepository(database: dbf),
    store: store ?? BleMessageStore(database: dbf),
  );
}

class _Device {
  _Device({
    required this.deviceId,
    required this.db,
    required this.server,
    required this.messages,
    required this.peers,
    required this.store,
  });

  final String deviceId;
  final Database db;
  final _FakeFirestore server;
  final MessageRepository messages;
  final PeerRepository peers;
  final BleMessageStore store;
  final bleRequests = <String>[];
  _FakeTransport? transport;

  TransportManager startManager() {
    final fake = _FakeTransport(deviceId: deviceId, server: server);
    transport = fake;
    final manager = TransportManager(
      messages: messages,
      incomingStore: store,
      peers: peers,
      localDeviceId: () => deviceId,
      isBleActive: () => false,
      requestDelivery: (peerId) async {
        bleRequests.add(peerId);
      },
      transportFactory: (_) => fake,
    );
    return manager;
  }
}

/// Local store that always fails, so tests can prove the delivery ack is only
/// written after a successful local persistence.
class _FailingStore extends BleMessageStore {
  @override
  Future<BleIncomingReceipt> storeIncoming({
    required BleMessagePayload payload,
    required Peer peer,
    MessageTransport transport = MessageTransport.ble,
  }) async {
    throw StateError('local persistence failed');
  }
}

/// In-memory stand-in for Firestore: one document per message id, create-only
/// writes, backend-side queueing for recipients that are not connected, and
/// delivery acks that only the addressed recipient may write.
///
/// `cloud_firestore` cannot run under `flutter test` (its plugins are platform
/// channels), so this reproduces the semantics the transport relies on rather
/// than the wire protocol.
class _FakeFirestore {
  final registry = <String, String>{};
  final docs = <String, Map<String, dynamic>>{};
  final sessions = <String, _FakeTransport>{};

  void register(String deviceId) {
    registry.putIfAbsent(deviceId, () => 'uid-$deviceId');
  }
}

class _FakeTransport extends OnlineTransport {
  _FakeTransport({required this.deviceId, required this.server});

  final String deviceId;
  final _FakeFirestore server;

  /// Whether the backend answers this device right now.
  bool reachable = true;

  OnlineConnectionState _state = OnlineConnectionState.disconnected;
  final Set<String> _pendingAcks = <String>{};

  @override
  OnlineConnectionState get state => _state;

  @override
  Future<void> start() async {
    if (!reachable) {
      _setState(OnlineConnectionState.disconnected);
      return;
    }
    server.register(deviceId);
    server.sessions[deviceId] = this;
    _setState(OnlineConnectionState.ready);
    _flushIncoming();
    _flushAcks();
  }

  @override
  Future<void> stop() async {
    server.sessions.remove(deviceId);
    _setState(OnlineConnectionState.disconnected);
  }

  @override
  Future<void> send(Message message) async {
    if (!reachable) throw StateError('backend unreachable');
    if (!server.registry.containsKey(message.receiverId)) {
      throw StateError('recipient is not registered');
    }
    // Create-only, exactly like Firestore's rules: a message id the backend
    // already holds is acknowledged, never written a second time.
    if (server.docs.containsKey(message.messageId)) return;
    server.docs[message.messageId] = {
      'messageId': message.messageId,
      'senderUid': 'uid-$deviceId',
      'senderDeviceId': deviceId,
      'recipientUid': server.registry[message.receiverId],
      'recipientDeviceId': message.receiverId,
      'content': message.content,
      'status': 'sent',
      'createdAt': DateTime.now(),
      'deliveredAt': null,
    };
    server.sessions[message.receiverId]?._deliver(message.messageId);
  }

  @override
  void sendDelivered(String messageId) {
    if (!reachable) {
      _pendingAcks.add(messageId);
      return;
    }
    _ack(messageId);
  }

  /// Simulates the backend coming back: listeners re-sync from scratch.
  Future<void> regainConnection() async {
    reachable = true;
    await start();
  }

  void _deliver(String messageId) {
    if (!reachable) return;
    final doc = server.docs[messageId];
    if (doc == null || doc['status'] != 'sent') return;
    onIncoming?.call(_frame(doc));
  }

  void _flushIncoming() {
    for (final doc in server.docs.values) {
      if (doc['recipientDeviceId'] == deviceId && doc['status'] == 'sent') {
        onIncoming?.call(_frame(doc));
      }
    }
  }

  void _ack(String messageId) {
    final doc = server.docs[messageId];
    if (doc == null || doc['recipientDeviceId'] != deviceId) return;
    if (doc['status'] == 'delivered') return;
    doc['status'] = 'delivered';
    doc['deliveredAt'] = DateTime.now();
    final senderId = doc['senderDeviceId'] as String;
    server.sessions[senderId]?.onDelivered?.call(messageId);
  }

  void _flushAcks() {
    for (final messageId in _pendingAcks.toList()) {
      _ack(messageId);
      _pendingAcks.remove(messageId);
    }
  }

  Map<String, dynamic> _frame(Map<String, dynamic> doc) => {
    'messageId': doc['messageId'],
    'senderId': doc['senderDeviceId'],
    'receiverId': doc['recipientDeviceId'],
    'content': doc['content'],
    'timestamp': (doc['createdAt'] as DateTime).toUtc().toIso8601String(),
    'ttl': AppConstants.messageTtlDefault.inSeconds,
  };

  void _setState(OnlineConnectionState next) {
    if (_state == next) return;
    _state = next;
    onStateChanged?.call(next);
  }
}
