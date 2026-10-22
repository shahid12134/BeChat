import 'dart:async';

import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/repositories/message_repository.dart';

typedef BleMessageSender =
    Future<BleAckResult> Function(
      Message message, {
      Future<void> Function()? onTransmitted,
    });

typedef BleOutboxChanged = Future<void> Function(Message message);

class BleOutbox {
  BleOutbox({
    required MessageRepository repository,
    required BleMessageSender send,
    required bool Function() isLinkUsable,
    required BleOutboxChanged onChanged,
    this.maxAttempts = 2,
    this.retryDelay = _defaultRetryDelay,
    this.approvalRetryWindow = AppConstants.incomingRequestTimeout,
    this.approvalRetryDelay = const Duration(seconds: 2),
  }) : _repository = repository,
       _send = send,
       _isLinkUsable = isLinkUsable,
       _onChanged = onChanged;

  final MessageRepository _repository;
  final BleMessageSender _send;
  final bool Function() _isLinkUsable;
  final BleOutboxChanged _onChanged;
  final int maxAttempts;
  final Duration Function(int attempt) retryDelay;
  final Duration approvalRetryWindow;
  final Duration approvalRetryDelay;

  bool _running = false;
  bool _rerun = false;

  static Duration _defaultRetryDelay(int attempt) {
    return Duration(seconds: 1 << (attempt - 1).clamp(0, 4));
  }

  Future<void> drain({
    required String localDeviceId,
    required String peerId,
  }) async {
    if (!_isLinkUsable()) return;
    if (_running) {
      _rerun = true;
      return;
    }
    _running = true;
    try {
      do {
        _rerun = false;
        final messages = await _repository.getQueuedOutgoingMessages(
          localDeviceId,
        );
        for (final message in messages) {
          if (message.receiverId != peerId) continue;
          if (!_isLinkUsable()) return;
          await _deliver(message);
        }
      } while (_rerun && _isLinkUsable());
    } finally {
      _running = false;
    }
  }

  Future<void> _deliver(Message message) async {
    final approvalDeadline = DateTime.now().add(approvalRetryWindow);
    var attempt = 0;
    while (true) {
      if (!_isLinkUsable()) return;
      attempt++;
      await _repository.markMessageSending(message.messageId);
      await _onChanged(message.copyWith(status: MessageStatus.sending));

      try {
        final result = await _send(
          message,
          onTransmitted: () async {
            await _repository.markMessageSent(message.messageId);
            await _onChanged(message.copyWith(status: MessageStatus.sent));
          },
        );
        switch (result) {
          case BleAckResult.stored:
          case BleAckResult.duplicate:
            await _repository.markMessageDelivered(message.messageId);
            await _onChanged(message.copyWith(status: MessageStatus.delivered));
            return;
          case BleAckResult.rejected:
            await _repository.markMessageFailed(message.messageId);
            await _onChanged(message.copyWith(status: MessageStatus.failed));
            return;
        }
      } on BleApprovalPendingException {
        await _repository.requeueMessage(message.messageId);
        await _onChanged(message.copyWith(status: MessageStatus.queued));
        if (!_isLinkUsable()) return;
        if (!DateTime.now().isBefore(approvalDeadline)) return;
        await Future<void>.delayed(approvalRetryDelay);
      } catch (_) {
        await _repository.requeueMessage(message.messageId);
        await _onChanged(message.copyWith(status: MessageStatus.queued));
        if (!_isLinkUsable()) return;
        if (attempt >= maxAttempts) return;
        await Future<void>.delayed(retryDelay(attempt));
      }
    }
  }
}
