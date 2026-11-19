import 'dart:async';

import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/repositories/message_repository.dart';

/// Delivers one queued message over [peerId]'s own secure link.
///
/// The runtime resolves the receiving peer's link session from its
/// multi-connection registry and fails with [BleLinkClosedException] when
/// that specific peer has no usable link — one peer's missing link never
/// affects delivery to another peer.
typedef BleMessageSender =
    Future<BleAckResult> Function(
      String peerId,
      Message message, {
      Future<void> Function()? onTransmitted,
    });

typedef BleOutboxChanged = Future<void> Function(Message message);

/// Per-destination outgoing-message delivery.
///
/// Multi-connection behavior: each destination drains independently and
/// concurrently with other destinations, while at most one drain runs per
/// destination at a time, preserving strict FIFO order per peer. A failure on
/// one peer (link closed, ACK timeout) is confined to that peer's messages —
/// other peers keep draining. Messages are stored in the repository, so a
/// message whose link closed stays queued and is delivered on a later drain
/// once that peer reconnects; nothing is relayed, and a message is only ever
/// sent to the directly connected peer it names as its receiver.
class BleOutbox {
  BleOutbox({
    required MessageRepository repository,
    required BleMessageSender send,
    required bool Function(String peerId) isLinkUsable,
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
  final bool Function(String peerId) _isLinkUsable;
  final BleOutboxChanged _onChanged;
  final int maxAttempts;
  final Duration Function(int attempt) retryDelay;
  final Duration approvalRetryWindow;
  final Duration approvalRetryDelay;

  /// Destinations with a drain currently running, so two drains can never
  /// run for the same peer while different peers drain concurrently.
  final Set<String> _runningDestinations = {};

  /// Destinations whose drain was re-requested while it was running.
  final Set<String> _rerun = {};

  static Duration _defaultRetryDelay(int attempt) {
    return Duration(seconds: 1 << (attempt - 1).clamp(0, 4));
  }

  /// Drains queued messages for [peerId] over that peer's link.
  ///
  /// When a drain for this destination is already running, this schedules one
  /// extra pass instead of a second concurrent drain, so no message is
  /// skipped and FIFO order per peer is preserved.
  Future<void> drain({
    required String localDeviceId,
    required String peerId,
  }) async {
    if (!_isLinkUsable(peerId)) return;
    if (_runningDestinations.contains(peerId)) {
      _rerun.add(peerId);
      return;
    }
    _runningDestinations.add(peerId);
    try {
      do {
        _rerun.remove(peerId);
        final messages = await _repository.getQueuedOutgoingMessages(
          localDeviceId,
          // Media stays queued for the online transport: a chunked BLE file
          // transfer is a protocol change, and sending only the text label
          // would look delivered while the file never arrived.
          excludeAttachments: true,
        );
        for (final message in messages) {
          // Only this destination's messages: another peer's queue is drained
          // by that peer's own drain, never here.
          if (message.receiverId != peerId) continue;
          if (!_isLinkUsable(peerId)) return;
          await _deliver(peerId, message);
        }
      } while (_rerun.contains(peerId) && _isLinkUsable(peerId));
    } finally {
      _runningDestinations.remove(peerId);
    }
  }

  Future<void> _deliver(String peerId, Message message) async {
    final approvalDeadline = DateTime.now().add(approvalRetryWindow);
    var attempt = 0;
    while (true) {
      if (!_isLinkUsable(peerId)) return;
      attempt++;
      // Atomic claim: if the online transport already owns this message,
      // skip it here instead of sending it over both transports.
      final claimed = await _repository.tryClaimForSending(message.messageId);
      if (!claimed) return;
      await _onChanged(message.copyWith(status: MessageStatus.sending));

      try {
        final result = await _send(
          peerId,
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
        if (!_isLinkUsable(peerId)) return;
        if (!DateTime.now().isBefore(approvalDeadline)) return;
        await Future<void>.delayed(approvalRetryDelay);
      } catch (_) {
        // Any transport, link or ACK failure stays confined to this peer: the
        // message returns to the queue and other destinations are unaffected.
        await _repository.requeueMessage(message.messageId);
        await _onChanged(message.copyWith(status: MessageStatus.queued));
        if (!_isLinkUsable(peerId)) return;
        if (attempt >= maxAttempts) return;
        await Future<void>.delayed(retryDelay(attempt));
      }
    }
  }
}
