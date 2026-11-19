import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/repositories/message_repository.dart';
import 'package:bechat/services/ble/ble_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('leaves messages queued when no BLE link is usable', () async {
    final repository = _FakeMessageRepository([_message()]);
    final outbox = BleOutbox(
      repository: repository,
      send: (peerId, message, {onTransmitted}) async => BleAckResult.stored,
      isLinkUsable: (_) => false,
      onChanged: (message) async {},
    );

    await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

    expect(repository.statusOf('msg-1'), MessageStatus.queued);
    expect(repository.sentCount, 0);
  });

  test('marks delivered only after a stored acknowledgement', () async {
    final repository = _FakeMessageRepository([_message()]);
    final statuses = <MessageStatus>[];
    var sent = 0;
    final outbox = BleOutbox(
      repository: repository,
      send: (peerId, message, {onTransmitted}) async {
        sent++;
        await onTransmitted?.call();
        return BleAckResult.stored;
      },
      isLinkUsable: (_) => true,
      onChanged: (message) async => statuses.add(message.status),
    );

    await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

    expect(sent, 1);
    expect(repository.statusOf('msg-1'), MessageStatus.delivered);
    expect(
      statuses,
      containsAllInOrder([
        MessageStatus.sending,
        MessageStatus.sent,
        MessageStatus.delivered,
      ]),
    );
  });

  test('retries once after a transient failure and then delivers', () async {
    final repository = _FakeMessageRepository([_message()]);
    var attempts = 0;
    final outbox = BleOutbox(
      repository: repository,
      send: (peerId, message, {onTransmitted}) async {
        attempts++;
        if (attempts == 1) throw StateError('link dropped');
        await onTransmitted?.call();
        return BleAckResult.stored;
      },
      isLinkUsable: (_) => true,
      onChanged: (message) async {},
      retryDelay: (_) => Duration.zero,
    );

    await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

    expect(attempts, 2);
    expect(repository.statusOf('msg-1'), MessageStatus.delivered);
  });

  test(
    'requeues after a disconnect instead of showing false success',
    () async {
      final repository = _FakeMessageRepository([_message()]);
      var usable = true;
      var attempts = 0;
      final outbox = BleOutbox(
        repository: repository,
        send: (peerId, message, {onTransmitted}) async {
          attempts++;
          usable = false;
          throw StateError('disconnected');
        },
        isLinkUsable: (_) => usable,
        onChanged: (message) async {},
        retryDelay: (_) => Duration.zero,
      );

      await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

      expect(attempts, 1);
      expect(repository.statusOf('msg-1'), MessageStatus.queued);
    },
  );

  test('retries while the peer is waiting for connection approval', () async {
    final repository = _FakeMessageRepository([_message()]);
    var attempts = 0;
    final outbox = BleOutbox(
      repository: repository,
      send: (peerId, message, {onTransmitted}) async {
        attempts++;
        await onTransmitted?.call();
        if (attempts == 1) {
          throw const BleApprovalPendingException('msg-1');
        }
        return BleAckResult.stored;
      },
      isLinkUsable: (_) => true,
      onChanged: (message) async {},
      approvalRetryDelay: Duration.zero,
    );

    await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

    expect(attempts, 2);
    expect(repository.statusOf('msg-1'), MessageStatus.delivered);
  });

  test(
    'leaves a message queued when approval does not arrive in time',
    () async {
      final repository = _FakeMessageRepository([_message()]);
      final outbox = BleOutbox(
        repository: repository,
        send: (peerId, message, {onTransmitted}) async {
          await onTransmitted?.call();
          throw const BleApprovalPendingException('msg-1');
        },
        isLinkUsable: (_) => true,
        onChanged: (message) async {},
        approvalRetryWindow: Duration.zero,
        approvalRetryDelay: Duration.zero,
      );

      await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

      expect(repository.statusOf('msg-1'), MessageStatus.queued);
    },
  );

  test('marks a definitive rejection as failed', () async {
    final repository = _FakeMessageRepository([_message()]);
    final outbox = BleOutbox(
      repository: repository,
      send: (peerId, message, {onTransmitted}) async {
        await onTransmitted?.call();
        return BleAckResult.rejected;
      },
      isLinkUsable: (_) => true,
      onChanged: (message) async {},
    );

    await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

    expect(repository.statusOf('msg-1'), MessageStatus.failed);
  });

  test('treats a duplicate acknowledgement as delivered', () async {
    final repository = _FakeMessageRepository([_message()]);
    final outbox = BleOutbox(
      repository: repository,
      send: (peerId, message, {onTransmitted}) async {
        await onTransmitted?.call();
        return BleAckResult.duplicate;
      },
      isLinkUsable: (_) => true,
      onChanged: (message) async {},
    );

    await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

    expect(repository.statusOf('msg-1'), MessageStatus.delivered);
  });

  group('multi-destination draining', () {
    test(
      'each peer only receives its own messages, never another peer\'s',
      () async {
        final repository = _FakeMessageRepository([
          _message(id: 'to-b', receiver: 'device-b'),
          _message(id: 'to-c', receiver: 'device-c'),
        ]);
        final seenByPeer = <String, List<String>>{};

        final outbox = BleOutbox(
          repository: repository,
          send: (peerId, message, {onTransmitted}) async {
            seenByPeer.putIfAbsent(peerId, () => []).add(message.messageId);
            await onTransmitted?.call();
            return BleAckResult.stored;
          },
          isLinkUsable: (_) => true,
          onChanged: (message) async {},
        );

        await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');
        await outbox.drain(localDeviceId: 'device-a', peerId: 'device-c');

        expect(seenByPeer['device-b'], ['to-b']);
        expect(seenByPeer['device-c'], ['to-c']);
        expect(repository.statusOf('to-b'), MessageStatus.delivered);
        expect(repository.statusOf('to-c'), MessageStatus.delivered);
      },
    );

    test('one peer\'s failure is confined to that peer\'s queue', () async {
      final repository = _FakeMessageRepository([
        _message(id: 'to-b', receiver: 'device-b'),
        _message(id: 'to-c', receiver: 'device-c'),
      ]);
      final outbox = BleOutbox(
        repository: repository,
        send: (peerId, message, {onTransmitted}) async {
          if (peerId == 'device-b') {
            throw StateError('peer-b link dropped');
          }
          await onTransmitted?.call();
          return BleAckResult.stored;
        },
        isLinkUsable: (_) => true,
        onChanged: (message) async {},
        retryDelay: (_) => Duration.zero,
      );

      await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');
      await outbox.drain(localDeviceId: 'device-a', peerId: 'device-c');

      // b's message is requeued, c's still delivers.
      expect(repository.statusOf('to-b'), MessageStatus.queued);
      expect(repository.statusOf('to-c'), MessageStatus.delivered);
    });

    test(
      'draining one peer leaves another peer\'s queued messages untouched',
      () async {
        final repository = _FakeMessageRepository([
          _message(id: 'to-b', receiver: 'device-b'),
          _message(id: 'to-c', receiver: 'device-c'),
        ]);
        final outbox = BleOutbox(
          repository: repository,
          send: (peerId, message, {onTransmitted}) async {
            await onTransmitted?.call();
            return BleAckResult.stored;
          },
          isLinkUsable: (_) => true,
          onChanged: (message) async {},
        );

        await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

        expect(repository.statusOf('to-b'), MessageStatus.delivered);
        expect(repository.statusOf('to-c'), MessageStatus.queued);
      },
    );

    test(
      'messages stay queued while that specific peer\'s link is unusable',
      () async {
        final repository = _FakeMessageRepository([
          _message(id: 'to-b', receiver: 'device-b'),
          _message(id: 'to-c', receiver: 'device-c'),
        ]);
        final outbox = BleOutbox(
          repository: repository,
          send: (peerId, message, {onTransmitted}) async {
            await onTransmitted?.call();
            return BleAckResult.stored;
          },
          // Only device-c has a usable link.
          isLinkUsable: (peerId) => peerId == 'device-c',
          onChanged: (message) async {},
        );

        await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');
        await outbox.drain(localDeviceId: 'device-a', peerId: 'device-c');

        expect(repository.statusOf('to-b'), MessageStatus.queued);
        expect(repository.statusOf('to-c'), MessageStatus.delivered);
      },
    );

    test('FIFO order is preserved per peer', () async {
      final repository = _FakeMessageRepository([
        _message(id: 'first', receiver: 'device-b'),
        _message(id: 'second', receiver: 'device-b'),
        _message(id: 'third', receiver: 'device-b'),
      ]);
      final sendOrder = <String>[];
      final outbox = BleOutbox(
        repository: repository,
        send: (peerId, message, {onTransmitted}) async {
          sendOrder.add(message.messageId);
          await onTransmitted?.call();
          return BleAckResult.stored;
        },
        isLinkUsable: (_) => true,
        onChanged: (message) async {},
      );

      await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

      expect(sendOrder, ['first', 'second', 'third']);
    });
  });
}

Message _message({String id = 'msg-1', String receiver = 'device-b'}) {
  final now = DateTime.utc(2026, 3, 4);
  return Message(
    messageId: id,
    chatId: 'chat-1',
    senderId: 'device-a',
    receiverId: receiver,
    content: 'Queued',
    timestamp: now,
    createdAt: now,
    updatedAt: now,
  );
}

class _FakeMessageRepository extends MessageRepository {
  _FakeMessageRepository(List<Message> messages)
    : _messages = {for (final message in messages) message.messageId: message};

  final Map<String, Message> _messages;
  int sentCount = 0;

  MessageStatus? statusOf(String messageId) => _messages[messageId]?.status;

  @override
  Future<List<Message>> getQueuedOutgoingMessages(String senderId) async {
    return _messages.values
        .where(
          (message) =>
              message.senderId == senderId &&
              message.status == MessageStatus.queued,
        )
        .toList();
  }

  @override
  Future<void> markMessageSending(String messageId) async {
    _setStatus(messageId, MessageStatus.sending);
  }

  @override
  Future<bool> tryClaimForSending(String messageId) async {
    // Mirrors the repository's atomic claim: only a queued message can be
    // taken, by exactly one caller.
    if (statusOf(messageId) != MessageStatus.queued) return false;
    _setStatus(messageId, MessageStatus.sending);
    return true;
  }

  @override
  Future<void> markMessageSent(String messageId) async {
    sentCount++;
    _setStatus(messageId, MessageStatus.sent);
  }

  @override
  Future<void> markMessageDelivered(String messageId) async {
    _setStatus(messageId, MessageStatus.delivered);
  }

  @override
  Future<void> markMessageFailed(String messageId) async {
    _setStatus(messageId, MessageStatus.failed);
  }

  @override
  Future<void> requeueMessage(String messageId) async {
    _setStatus(messageId, MessageStatus.queued);
  }

  void _setStatus(String messageId, MessageStatus status) {
    final message = _messages[messageId];
    if (message == null) return;
    _messages[messageId] = message.copyWith(status: status);
  }
}
