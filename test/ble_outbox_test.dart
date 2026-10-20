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
      send: (message, {onTransmitted}) async => BleAckResult.stored,
      isLinkUsable: () => false,
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
      send: (message, {onTransmitted}) async {
        sent++;
        await onTransmitted?.call();
        return BleAckResult.stored;
      },
      isLinkUsable: () => true,
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
      send: (message, {onTransmitted}) async {
        attempts++;
        if (attempts == 1) throw StateError('link dropped');
        await onTransmitted?.call();
        return BleAckResult.stored;
      },
      isLinkUsable: () => true,
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
        send: (message, {onTransmitted}) async {
          attempts++;
          usable = false;
          throw StateError('disconnected');
        },
        isLinkUsable: () => usable,
        onChanged: (message) async {},
        retryDelay: (_) => Duration.zero,
      );

      await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

      expect(attempts, 1);
      expect(repository.statusOf('msg-1'), MessageStatus.queued);
    },
  );

  test('marks a definitive rejection as failed', () async {
    final repository = _FakeMessageRepository([_message()]);
    final outbox = BleOutbox(
      repository: repository,
      send: (message, {onTransmitted}) async {
        await onTransmitted?.call();
        return BleAckResult.rejected;
      },
      isLinkUsable: () => true,
      onChanged: (message) async {},
    );

    await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

    expect(repository.statusOf('msg-1'), MessageStatus.failed);
  });

  test('treats a duplicate acknowledgement as delivered', () async {
    final repository = _FakeMessageRepository([_message()]);
    final outbox = BleOutbox(
      repository: repository,
      send: (message, {onTransmitted}) async {
        await onTransmitted?.call();
        return BleAckResult.duplicate;
      },
      isLinkUsable: () => true,
      onChanged: (message) async {},
    );

    await outbox.drain(localDeviceId: 'device-a', peerId: 'device-b');

    expect(repository.statusOf('msg-1'), MessageStatus.delivered);
  });
}

Message _message() {
  final now = DateTime.utc(2026, 3, 4);
  return Message(
    messageId: 'msg-1',
    chatId: 'chat-1',
    senderId: 'device-a',
    receiverId: 'device-b',
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
