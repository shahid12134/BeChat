import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/data/models/attachment.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/message_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/services/ble/ble_message_store.dart';
import 'package:bechat/services/online/firestore_online_transport.dart';
import 'package:bechat/services/online/online_transport.dart';

/// Which transport is currently preferred for new outgoing messages.
enum TransportMode {
  /// Firebase reachable: messages go online (BLE still available as fallback).
  online,

  /// A Firebase attempt is in progress.
  connecting,

  /// Online unavailable, a usable BLE link exists: messages go over BLE.
  bluetooth,

  /// Neither transport is available: messages stay in the persistent queue.
  offline,
}

class TransportManagerState {
  const TransportManagerState({
    this.mode = TransportMode.offline,
    this.internet = false,
    this.firebase = false,
    this.ble = false,
  });

  final TransportMode mode;

  /// The device can reach the internet (DNS probe of the Firestore host) —
  /// "no internet" is a different failure from "Firebase is down".
  final bool internet;

  /// Firebase authenticated this device AND the Firestore server
  /// acknowledged the session (transport `ready`, not a cache hit).
  final bool firebase;

  /// A usable BLE link exists.
  final bool ble;
}

typedef TransportFactory = OnlineTransport Function(String deviceId);

/// Chooses between the Firebase online transport and the existing BLE one.
///
/// Priority: online when the authenticated Firestore session is reachable,
/// BLE when it is not, persistent SQLite queue when neither works. The
/// manager never touches an in-progress BLE transmission — both transports
/// claim a message through [MessageRepository.tryClaimForSending], so exactly
/// one can own a message at a time and switching never duplicates or drops.
///
/// Reachability is re-probed on a timer rather than inferred from device
/// connectivity: `OnlineTransport.start()` only reports `ready` after a
/// Firestore server acknowledgement.
class TransportManager extends StateNotifier<TransportManagerState> {
  TransportManager({
    required MessageRepository messages,
    required BleMessageStore incomingStore,
    required PeerRepository peers,
    required String? Function() localDeviceId,
    required bool Function() isBleActive,
    required Future<void> Function(String peerId) requestDelivery,
    this.onChanged,
    this.onIncomingStored,
    TransportFactory? transportFactory,
  }) : _messages = messages,
       _incomingStore = incomingStore,
       _peers = peers,
       _localDeviceId = localDeviceId,
       _isBleActive = isBleActive,
       _requestDelivery = requestDelivery,
       _transportFactory = transportFactory,
       super(const TransportManagerState());

  /// How often an unready transport is retried (Firestore may come back at
  /// any time; there is no connectivity callback to wait for).
  static const _retryInterval = Duration(seconds: 10);

  /// Upper bound for the exponential backoff while Firebase is unreachable.
  static const _retryMaxInterval = Duration(seconds: 60);

  final MessageRepository _messages;
  final BleMessageStore _incomingStore;
  final PeerRepository _peers;
  final String? Function() _localDeviceId;
  final bool Function() _isBleActive;
  final Future<void> Function(String peerId) _requestDelivery;
  final TransportFactory? _transportFactory;

  /// Refreshes the chat UI after an outgoing status change or an incoming
  /// message was stored (wired to the same refreshers the BLE runtime uses).
  final Future<void> Function(Message message)? onChanged;
  final Future<void> Function(String chatId)? onIncomingStored;

  OnlineTransport? _transport;
  Timer? _retryTimer;
  bool _started = false;

  /// Next delay for the single retry timer: 10 → 20 → 40 → 60s while
  /// Firebase stays unreachable, reset to 10s on success or foreground.
  Duration _retryDelay = _retryInterval;

  /// Result of the last DNS probe (see [_probeInternet]).
  bool _internetOk = false;

  /// Prevents overlapping ticks (a foreground resume can land mid-probe).
  bool _ticking = false;

  /// Connects once the local identity exists. Safe to call repeatedly.
  Future<void> start() async {
    if (_started || AppConstants.demoDataEnabled) return;
    _started = true;
    unawaited(_probeInternet());
    await _connect();
    _ensureRetryTimer();
  }

  Future<void> _connect() async {
    final deviceId = _localDeviceId();
    if (deviceId == null) {
      // No identity yet: nothing to authenticate as. The provider re-reads
      // localDeviceId, and start() is re-run by the retry timer.
      _started = false;
      _refreshMode();
      return;
    }
    final transport =
        _transport ??= (_transportFactory ?? _defaultTransportFactory)(
          deviceId,
        );
    transport.onStateChanged = (next) {
      _refreshMode();
      if (next == OnlineConnectionState.ready) {
        // Backend reachable again: everything still queued goes online now.
        unawaited(syncPending());
      }
    };
    transport.onIncoming = _handleIncoming;
    transport.onDelivered = _handleDelivered;
    await transport.start();
    _refreshMode();
  }

  OnlineTransport _defaultTransportFactory(String deviceId) =>
      FirestoreOnlineTransport(deviceId: deviceId);

  /// The one and only retry timer. It is NOT periodic: each tick schedules
  /// the next one, so the delay can grow with consecutive failures (bounded
  /// exponential backoff) and collapse back to [_retryInterval] on success.
  void _ensureRetryTimer() {
    if (_retryTimer != null) return;
    _scheduleRetry(_retryDelay);
  }

  void _scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    if (!mounted) return;
    _retryTimer = Timer(delay, () => unawaited(_retryTick()));
  }

  Future<void> _retryTick() async {
    if (!mounted || _ticking) return;
    _ticking = true;
    try {
      final transport = _transport;
      if (transport == null) {
        // start() ran before the local identity existed, so no transport
        // could be built yet. Retry the whole connect instead of waiting
        // forever on a transport that was never created.
        await _connect();
      } else if (!transport.isReady) {
        // Re-attaches listeners and probes the server. Never interrupts an
        // in-flight send: claims keep exactly one owner per message.
        await transport.start();
      }
      await _probeInternet();
      if (!mounted) return;
      _refreshMode();
      _retryDelay = (_transport?.isReady ?? false)
          ? _retryInterval
          : _backoff(_retryDelay);
      _scheduleRetry(_retryDelay);
    } finally {
      _ticking = false;
    }
  }

  static Duration _backoff(Duration current) {
    final next = current * 2;
    return next > _retryMaxInterval ? _retryMaxInterval : next;
  }

  /// DNS probe of the Firestore host: separates "no internet" from
  /// "Firebase unreachable", which `transport.start()` alone cannot tell
  /// apart (both end in the same failed start).
  Future<void> _probeInternet() async {
    var ok = false;
    try {
      final resolved = await InternetAddress.lookup('firestore.googleapis.com')
          .timeout(const Duration(seconds: 5));
      ok = resolved.isNotEmpty;
    } catch (_) {
      // DNS failure or timeout: no internet until the next probe.
    }
    if (!mounted || _internetOk == ok) return;
    _internetOk = ok;
    _refreshMode();
  }

  /// App returned to the foreground: drop the accumulated backoff and probe
  /// immediately instead of waiting out the current delay.
  void onForeground() {
    if (!mounted || _retryTimer == null) return;
    _retryDelay = _retryInterval;
    _scheduleRetry(Duration.zero);
  }

  /// Entry point after a message was saved locally: sends it over the
  /// preferred transport (online when Firebase is reachable, BLE otherwise),
  /// exactly as the chat screen previously handed it to BLE directly.
  Future<void> onMessageQueued(String peerId) async {
    if (_transport?.isReady ?? false) {
      await _drainOnline(peerId);
    } else {
      // Existing BLE path, unchanged behavior and error propagation.
      await _requestDelivery(peerId);
    }
  }

  /// Sends every queued outgoing message over the reachable transport.
  /// Called on demand and whenever the backend (re)becomes reachable.
  Future<void> syncPending() async {
    final deviceId = _localDeviceId();
    final transport = _transport;
    if (deviceId == null || transport == null || !transport.isReady) return;
    final queued = await _messages.getQueuedOutgoingMessages(deviceId);
    for (final message in queued) {
      await _dispatchOnline(message);
    }
  }

  Future<void> _drainOnline(String peerId) async {
    final deviceId = _localDeviceId();
    final transport = _transport;
    if (deviceId == null || transport == null || !transport.isReady) return;
    final queued = await _messages.getQueuedOutgoingMessages(deviceId);
    for (final message in queued) {
      if (message.receiverId != peerId) continue;
      await _dispatchOnline(message);
    }
  }

  Future<void> _dispatchOnline(Message message) async {
    final transport = _transport;
    if (transport == null || !transport.isReady) return;

    // Atomic claim: fails when the BLE outbox (or an earlier dispatch)
    // already owns this message, so it is never sent twice.
    final claimed = await _messages.tryClaimForSending(message.messageId);
    if (!claimed) return;

    try {
      await transport.send(message);
      // Server acceptance only — final delivery arrives via onDelivered.
      await _messages.updateMessageStatus(
        message.messageId,
        MessageStatus.sent,
      );
      await _messages.updateMessageTransport(
        message.messageId,
        MessageTransport.cloud,
      );
      await onChanged?.call(
        message.copyWith(
          status: MessageStatus.sent,
          transport: MessageTransport.cloud,
        ),
      );
    } catch (_) {
      // Not accepted (or unreachable): return it to the shared queue. A resend
      // after a lost acknowledgement is harmless — the message id is the
      // document id, so it can never be stored twice.
      await _messages.requeueMessage(message.messageId);
      await onChanged?.call(message.copyWith(status: MessageStatus.queued));
      // Media never goes over BLE or the multi-hop relay: the bytes live in
      // Storage, so the BLE drain skips these rows and they wait here for the
      // next online attempt instead of being sent as a bare label.
      if (message.attachment != null) return;
      try {
        await _requestDelivery(message.receiverId);
      } catch (_) {
        // BLE fallback unavailable too; the message simply stays queued.
      }
    }
  }

  Future<void> _handleDelivered(String messageId) async {
    try {
      final message = await _messages.getMessageByMessageId(messageId);
      if (message == null) return;
      if (message.status == MessageStatus.delivered ||
          message.status == MessageStatus.read) {
        return;
      }
      // Transport stays as recorded (cloud); only the status advances.
      await _messages.updateMessageStatus(messageId, MessageStatus.delivered);
      await onChanged?.call(message.copyWith(status: MessageStatus.delivered));
    } catch (_) {
      // A failed status refresh never invalidates the server's ack; the
      // next snapshot repeats it idempotently.
    }
  }

  Future<void> _handleIncoming(Map<String, dynamic> frame) async {
    try {
      final deviceId = _localDeviceId();
      final receiverId = frame['receiverId'];
      final messageId = frame['messageId'];
      final senderId = frame['senderId'];
      final content = frame['content'];
      // Never store a frame addressed to another device. The sender id is
      // bound to an authenticated Firebase UID by firestore.rules, so it is
      // identity, not a client-supplied claim.
      if (deviceId == null ||
          receiverId is! String ||
          receiverId != deviceId ||
          messageId is! String ||
          senderId is! String ||
          senderId.isEmpty ||
          senderId == deviceId ||
          content is! String ||
          utf8.encode(content).length > AppConstants.maxMessageLength) {
        return;
      }
      // Attachment metadata is validated against this message (id, sender
      // device, Storage path, type and size). A frame whose metadata does not
      // hold up is dropped rather than trusted.
      final rawAttachment = frame['attachment'];
      final attachment = rawAttachment == null
          ? null
          : Attachment.fromFirestore(
              messageId: messageId,
              senderDeviceId: senderId,
              data: rawAttachment,
            );
      if (rawAttachment != null && attachment == null) return;

      final timestamp =
          DateTime.tryParse('${frame['timestamp']}') ?? DateTime.now();
      final payload = BleMessagePayload(
        metadata: BleMessageMetadata(
          messageId: messageId,
          senderId: senderId,
          receiverId: receiverId,
          messageType: 'text',
          timestamp: timestamp,
          ttl:
              (frame['ttl'] as num?)?.toInt() ??
              AppConstants.messageTtlDefault.inSeconds,
          contentLength: utf8.encode(content).length,
          isEncrypted: false,
        ),
        content: content,
      );
      final existingPeer = await _peers.getPeerByPeerId(senderId);
      final peer =
          existingPeer ?? Peer(peerId: senderId, displayName: senderId, deviceName: '');
      final receipt = await _incomingStore.storeIncoming(
        payload: payload,
        peer: peer,
        transport: MessageTransport.cloud,
        attachment: attachment,
      );
      // Ack only after the local write succeeded — and for duplicates too,
      // so a repeated snapshot cannot leave the sender waiting forever.
      _transport?.sendDelivered(messageId);
      if (receipt.result == BleIncomingResult.stored) {
        await onIncomingStored?.call(receipt.chatId);
      }
    } catch (_) {
      // A malformed frame never crashes the manager; the message stays
      // 'sent' server-side and is offered again on the next snapshot.
    }
  }

  void _refreshMode() {
    // Transport callbacks can land after dispose; StateNotifier forbids
    // state writes once disposed.
    if (!mounted) return;
    final firebase = _transport?.isReady ?? false;
    final ble = _isBleActive();
    final TransportMode mode;
    if (firebase) {
      mode = TransportMode.online;
    } else if (ble) {
      mode = TransportMode.bluetooth;
    } else if (_transport?.state == OnlineConnectionState.connecting) {
      mode = TransportMode.connecting;
    } else {
      mode = TransportMode.offline;
    }
    if (state.mode != mode ||
        state.internet != _internetOk ||
        state.firebase != firebase ||
        state.ble != ble) {
      state = TransportManagerState(
        mode: mode,
        internet: _internetOk,
        firebase: firebase,
        ble: ble,
      );
    }
  }

  /// Re-evaluates the mode from the current BLE state (called by the
  /// provider whenever the BLE runtime state changes).
  void refreshFromBle() => _refreshMode();

  @override
  void dispose() {
    _retryTimer?.cancel();
    // Stop the transport without touching state afterwards: StateNotifier
    // forbids state changes once disposed.
    final transport = _transport;
    _transport = null;
    if (transport != null) unawaited(transport.stop());
    super.dispose();
  }
}
