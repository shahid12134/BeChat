import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_secure_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/services/crypto/native_secure_session_service.dart';

enum BleSessionState { idle, handshaking, ready, closed }

class BleLinkClosedException implements Exception {
  const BleLinkClosedException([this.message = 'BLE link closed']);

  final String message;

  @override
  String toString() => 'BleLinkClosedException: $message';
}

class BleAckTimeoutException implements Exception {
  const BleAckTimeoutException(this.messageId, this.timeout);

  final String messageId;
  final Duration timeout;

  @override
  String toString() =>
      'BleAckTimeoutException: no acknowledgement for $messageId within '
      '${timeout.inMilliseconds} ms';
}

class BleApprovalPendingException implements Exception {
  const BleApprovalPendingException(this.messageId);

  final String messageId;

  @override
  String toString() =>
      'BleApprovalPendingException: $messageId is awaiting approval';
}

class BleHelloRejectedException implements Exception {
  const BleHelloRejectedException(this.message);

  final String message;

  @override
  String toString() => 'BleHelloRejectedException: $message';
}

/// A secure-mode link met a peer whose plaintext HELLO did not advertise the
/// secure (Noise) capability.
///
/// Deliberately **not** a [BleHelloRejectedException]: rejecting a HELLO is a
/// silent policy refusal, while an unsupported peer must surface a clear,
/// user-visible "update required" error. The link fails closed — no handshake
/// is attempted, no plaintext application message or ACK is ever written, and
/// there is no fallback to the legacy v1 message path.
class BleSecurePeerUnsupportedException extends BleLinkException {
  const BleSecurePeerUnsupportedException([
    super.message =
        'This peer is running an older version of BeChat that does not '
        'support secure messaging. Ask them to update BeChat to '
        'continue.',
  ]);
}

/// The Noise XX role a secure link session plays.
///
/// The BLE transport role maps onto the Noise role as follows:
///
/// * BLE peripheral -> [initiator] (the accepting side that starts Noise).
/// * BLE central    -> [responder] (the connecting side that awaits Noise
///   message 1).
///
/// The pattern is always `Noise_XX_25519_ChaChaPoly_SHA256`; it is never
/// negotiated from an unauthenticated HELLO.
enum BleSecureRole { initiator, responder }

/// The secure half of the link state machine (opt-in secure mode only).
///
/// A raw transport connection, an exchanged HELLO, and a finished Noise
/// handshake are each insufficient for [secureReady]: only an authenticated
/// handshake followed by explicit [BleLinkSession.confirmSecurePeerIdentity]
/// reaches it. Legacy (non-secure) sessions never leave [idle] here.
enum BleSecureLinkState {
  /// Constructed; no HELLO exchanged.
  idle,

  /// Transport connected and HELLO exchanged; awaiting the owning
  /// application's explicit [BleLinkSession.startSecureHandshake]
  /// authorization.
  awaitingAuthorization,

  /// Noise XX handshake in progress over protocol-v2 frames.
  handshaking,

  /// Handshake finished and the authenticated remote identity is exposed;
  /// awaiting explicit peer-identity confirmation.
  awaitingConfirmation,

  /// Authenticated, confirmed, encrypted session. Application messages and
  /// acknowledgements travel exclusively as Noise-encrypted secureMessage /
  /// secureAck payloads; there is never a plaintext fallback.
  secureReady,

  /// Terminal fail-closed state (timeout, malformed input, identity
  /// mismatch, cryptographic failure). Never falls back to plaintext.
  failed,

  /// The link was closed.
  closed,
}

class BleSecureHandshakeTimeoutException implements Exception {
  const BleSecureHandshakeTimeoutException();

  @override
  String toString() =>
      'BleSecureHandshakeTimeoutException: the secure handshake timed out';
}

/// Opt-in configuration that puts a [BleLinkSession] into secure mode.
///
/// Supplying this activates protocol-v2 framing for the Noise handshake and
/// the secure state machine; omitting it keeps the session byte-for-byte on
/// the legacy v1 path (the current production runtime always omits it).
///
/// The gateway is the existing Dart secure-session gateway; this class adds
/// no cryptography of its own.
class BleSecureSessionConfig {
  const BleSecureSessionConfig({
    required this.gateway,
    required this.role,
    this.pinnedRemotePublicKey,
    this.expectedPeerDeviceId,
    this.requireHelloBinding = false,
    this.onRemoteIdentity,
    this.onPinnedKeyMismatch,
  });

  /// The Dart secure-session gateway owning the native Noise sessions.
  final SecureSessionGateway gateway;

  /// The Noise role for this side of the link.
  final BleSecureRole role;

  /// Optional pinned remote static public key (exactly 32 raw bytes).
  ///
  /// When set, the engine rejects any handshake whose authenticated remote
  /// static key differs, and this session fails closed. A mismatch never
  /// overwrites the pin and never falls back to plaintext.
  final Uint8List? pinnedRemotePublicKey;

  /// Optional expected peer device ID checked against the **authenticated**
  /// remote identity (in addition to the engine's own check).
  final String? expectedPeerDeviceId;

  /// When true, the authenticated remote device ID must equal the device ID
  /// from the plaintext pre-secure HELLO. The HELLO is an unauthenticated
  /// hint; it is only ever compared against, never trusted as proof and
  /// never allowed to override authenticated fields.
  final bool requireHelloBinding;

  /// Surfaces the authenticated remote identity when the handshake finishes,
  /// for the owning application's authorization UI. Invoked on the
  /// [awaitingConfirmation] transition; performs no persistence.
  ///
  /// The session **awaits** a returned future before the secure state machine
  /// proceeds, so the application can validate the identity, apply its
  /// peer-key policy and explicitly confirm the peer in one ordered step. A
  /// throw fails the link closed; a non-future return keeps the historical
  /// fire-and-forget contract.
  final FutureOr<void> Function(RemoteAuthenticatedIdentity identity)?
  onRemoteIdentity;

  /// Invoked when the native engine rejects the handshake because the
  /// authenticated remote static key differs from [pinnedRemotePublicKey].
  ///
  /// Detection is structural (the engine's own status snapshot reports the
  /// authenticated remote key), never string matching on an error message.
  /// The conflicting key is deliberately *not* passed on: the application may
  /// only record that a conflict occurred while preserving the original pin.
  final FutureOr<void> Function()? onPinnedKeyMismatch;
}

class BleAckPolicy {
  const BleAckPolicy({
    this.baseTimeout = const Duration(seconds: 10),
    this.perKilobyte = const Duration(seconds: 1),
    this.perFrame = const Duration(milliseconds: 20),
  });

  final Duration baseTimeout;
  final Duration perKilobyte;
  final Duration perFrame;

  Duration timeoutFor({required int bytes, required int frameCount}) {
    final kilobytes = (bytes / 1024).ceil();
    return baseTimeout + perKilobyte * kilobytes + perFrame * frameCount;
  }
}

class BleLinkSession {
  BleLinkSession({
    required this.transport,
    required this.identity,
    required this.onHello,
    required this.onMessage,
    this.onClosed,
    this.ackPolicy = const BleAckPolicy(),
    this.handshakeTimeout = const Duration(seconds: 15),
    this.secure,
    int Function()? transferIdFactory,
  }) : _transferIdFactory =
           transferIdFactory ?? (() => 1 + Random.secure().nextInt(0xffff));

  final BleTransport transport;
  final Identity identity;
  final Future<void> Function(BleHello hello) onHello;
  final Future<BleAckResult> Function(BleMessagePayload message) onMessage;
  final void Function(Object? error)? onClosed;
  final BleAckPolicy ackPolicy;
  final Duration handshakeTimeout;

  /// Opt-in secure-mode configuration. `null` (the production default) keeps
  /// this session entirely on the legacy v1 plaintext path.
  final BleSecureSessionConfig? secure;

  final int Function() _transferIdFactory;

  final BleTransferAssembler _assembler = BleTransferAssembler();
  final BleSecureTransferAssembler _secureAssembler =
      BleSecureTransferAssembler();
  final Map<String, Completer<BleAck>> _pendingAcks = {};
  final Completer<BleHello> _helloCompleter = Completer<BleHello>();

  StreamSubscription<Uint8List>? _subscription;
  Future<void> _txTail = Future<void>.value();
  Future<void> _rxTail = Future<void>.value();
  BleSessionState _state = BleSessionState.idle;
  BleHello? _hello;
  Object? _closeError;
  bool _closed = false;

  // Secure-mode state. All fields are inert when [secure] is null.
  BleSecureLinkState _secureState = BleSecureLinkState.idle;
  SecureSessionHandle? _secureHandle;
  RemoteAuthenticatedIdentity? _secureRemoteIdentity;
  Timer? _secureHandshakeTimer;

  // Peer-specific secure context bound at runtime after the HELLO exchange;
  // see [bindSecurePeerContext]. Inert unless bound.
  static const int _pinnedKeyLength = 32;
  Uint8List? _boundPinnedRemotePublicKey;
  String? _boundExpectedPeerDeviceId;
  bool _secureContextBound = false;

  BleSessionState get state => _state;
  BleHello? get linkInfo => _hello;
  bool get isReady => _state == BleSessionState.ready;

  /// The secure state machine's state, or null for legacy v1 sessions.
  BleSecureLinkState? get secureState => secure == null ? null : _secureState;

  /// Whether the Noise handshake finished and the peer identity was
  /// explicitly confirmed. Always false for legacy v1 sessions.
  bool get isSecureReady => _secureState == BleSecureLinkState.secureReady;

  /// The authenticated remote identity surfaced by the finished handshake,
  /// before or after confirmation. Null for legacy sessions and until the
  /// handshake authenticates the peer.
  RemoteAuthenticatedIdentity? get secureRemoteIdentity =>
      _secureRemoteIdentity;

  Future<BleHello> start() async {
    if (_state != BleSessionState.idle) {
      throw const BleLinkException('BLE session has already been started');
    }
    _state = BleSessionState.handshaking;
    _subscription = transport.incoming.listen(
      _queueIncoming,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(close(error));
      },
      onDone: () {
        unawaited(close(const BleLinkClosedException()));
      },
    );

    try {
      final hello = BleHello(
        deviceId: identity.deviceId,
        displayName: identity.displayName,
        // Secure sessions advertise the Noise capability in the plaintext
        // HELLO so the peer can tell an updated BeChat from a legacy one.
        // The hint is unauthenticated context only — readiness still requires
        // the full handshake — and a legacy (secure == null) session keeps
        // byte-identical v1 HELLOs by advertising nothing new.
        capabilities: secure == null
            ? BleProtocol.capabilities
            : [...BleProtocol.capabilities, BleProtocol.capabilitySecureNoise],
      );
      await _enqueue(() async {
        await _writeTransfer(BleTransferKind.hello, hello.encode());
      });
      final remote = await _helloCompleter.future.timeout(handshakeTimeout);
      _hello = remote;
      if (secure != null) {
        // Secure mode: an exchanged HELLO is only the pre-secure context,
        // never readiness. The link awaits explicit authorization to begin
        // the Noise handshake.
        _secureState = BleSecureLinkState.awaitingAuthorization;
      } else {
        _state = BleSessionState.ready;
      }
      return remote;
    } catch (error) {
      await close(error);
      rethrow;
    }
  }

  Future<BleAckResult> sendMessage(
    Message message, {
    Future<void> Function()? onTransmitted,
  }) async {
    if (secure != null) {
      return _sendSecureMessage(message, onTransmitted: onTransmitted);
    }
    if (!isReady) {
      throw const BleLinkClosedException('BLE link is not ready');
    }
    final remote = _hello;
    if (remote == null || message.receiverId != remote.deviceId) {
      throw const BleLinkException('Message receiver does not match the link');
    }
    if (message.isEncrypted) {
      throw const BleLinkException(
        'Encrypted messages are not supported in Phase 2',
      );
    }
    if (_pendingAcks.containsKey(message.messageId)) {
      throw BleLinkException(
        'Message ${message.messageId} is already awaiting acknowledgement',
      );
    }

    final payload = _encodeOutboundMessage(message);

    final frames = BleTransferCodec.fragment(
      kind: BleTransferKind.message,
      payload: payload,
      maxWriteLength: transport.maximumWriteLength,
      transferId: _nextTransferId(),
    );
    final timeout = ackPolicy.timeoutFor(
      bytes: payload.length,
      frameCount: frames.length,
    );
    final completer = Completer<BleAck>();
    _pendingAcks[message.messageId] = completer;

    try {
      await _enqueue(() async {
        for (final frame in frames) {
          await transport.write(frame);
        }
      });
      await onTransmitted?.call();
      final ack = await completer.future.timeout(timeout);
      if (ack.result == BleAckResult.rejected &&
          ack.reason?.contains(BleProtocol.approvalPendingReason) == true) {
        throw BleApprovalPendingException(message.messageId);
      }
      return ack.result;
    } on TimeoutException {
      throw BleAckTimeoutException(message.messageId, timeout);
    } finally {
      _pendingAcks.remove(message.messageId);
    }
  }

  /// Encodes an outbound application message with the existing v1 application
  /// codec.
  ///
  /// Shared by the legacy plaintext path and the secure path so both produce
  /// byte-identical inner payloads; the secure path only adds Noise encryption
  /// around the result. Validation order matches the legacy sender exactly.
  Uint8List _encodeOutboundMessage(Message message) {
    final contentBytes = _utf8Length(message.content);
    if (contentBytes > BleProtocol.maxMessageContentBytes) {
      throw const BleLinkException('Message content is too large');
    }
    return BleMessagePayload(
      metadata: BleMessageMetadata(
        messageId: message.messageId,
        senderId: message.senderId,
        receiverId: message.receiverId,
        messageType: message.messageType.name,
        timestamp: message.timestamp,
        ttl: message.ttl,
        contentLength: contentBytes,
        isEncrypted: message.isEncrypted,
      ),
      content: message.content,
    ).encode();
  }

  /// Secure-mode outbound application message: encode once with the existing
  /// codec, encrypt through the Noise gateway, wrap the opaque ciphertext in a
  /// v2 `secureMessage`, write it on the serialized TX path, and complete only
  /// on the matching authenticated `secureAck`.
  ///
  /// Counter safety: a Noise transport message consumes a send counter at
  /// encryption time, so encryption happens *inside* the TX queue (encrypt
  /// order == wire order) and is never repeated on this session. A failed
  /// encrypt/write or an ACK timeout therefore fails the send **and** closes
  /// the secure session; recovery is a fresh connection plus a fresh
  /// handshake, where a higher layer may retry the message. There is no
  /// plaintext fallback and no counter reset, ever.
  Future<BleAckResult> _sendSecureMessage(
    Message message, {
    Future<void> Function()? onTransmitted,
  }) async {
    if (_closed || _state == BleSessionState.closed) {
      throw const BleLinkClosedException('BLE link is not ready');
    }
    if (_secureState != BleSecureLinkState.secureReady) {
      throw const BleLinkException(
        'The secure session is not ready for messaging',
      );
    }
    final remote = _secureRemoteIdentity;
    if (remote == null || message.receiverId != remote.deviceId) {
      // Bound to the *authenticated* remote identity, never to the
      // unauthenticated pre-secure HELLO.
      throw const BleLinkException('Message receiver does not match the link');
    }
    if (message.isEncrypted) {
      throw const BleLinkException(
        'Encrypted messages are not supported in Phase 2',
      );
    }
    if (_pendingAcks.containsKey(message.messageId)) {
      throw BleLinkException(
        'Message ${message.messageId} is already awaiting acknowledgement',
      );
    }

    final plaintext = _encodeOutboundMessage(message);
    if (plaintext.length > BleSecureProtocol.maxTransportPlaintextBytes) {
      // Reject oversized plaintext before any large allocation or native
      // encryption call (the Rust engine enforces the same bound).
      throw const BleLinkException('Message content is too large');
    }

    final completer = Completer<BleAck>();
    _pendingAcks[message.messageId] = completer;
    // Never leave the pending completer's error unhandled if the link closes
    // while this send is still queued or waiting for its acknowledgement.
    unawaited(completer.future.then<void>((_) {}, onError: (_) {}));

    var ciphertextBytes = 0;
    var frameCount = 0;
    try {
      await _enqueue(() async {
        final config = secure;
        final handle = _secureHandle;
        if (config == null ||
            handle == null ||
            _closed ||
            _secureState != BleSecureLinkState.secureReady) {
          throw const BleLinkClosedException('Secure session is not ready');
        }
        // Encrypt and write inside the serialized TX path so the Noise send
        // counter advances in exactly the order frames hit the wire.
        final sealed = await config.gateway.encrypt(handle, plaintext);
        final frames = BleSecureTransferCodec.fragment(
          kind: BleSecureTransferKind.secureMessage,
          payload: sealed,
          maxWriteLength: transport.maximumWriteLength,
          transferId: _nextTransferId(),
        );
        ciphertextBytes = sealed.length;
        frameCount = frames.length;
        for (final frame in frames) {
          await transport.write(frame);
        }
      });
    } catch (error) {
      // A failed encrypt or write makes transport-counter synchronization
      // uncertain: fail this send and tear the secure session down so a
      // later attempt runs on a freshly handshaked session.
      _pendingAcks.remove(message.messageId);
      if (!_closed && _secureState != BleSecureLinkState.failed) {
        await _failSecure(error);
      }
      rethrow;
    }

    final timeout = ackPolicy.timeoutFor(
      bytes: ciphertextBytes,
      frameCount: frameCount,
    );
    try {
      await onTransmitted?.call();
      final ack = await completer.future.timeout(timeout);
      if (ack.result == BleAckResult.rejected &&
          ack.reason?.contains(BleProtocol.approvalPendingReason) == true) {
        throw BleApprovalPendingException(message.messageId);
      }
      return ack.result;
    } on TimeoutException {
      // Counter safety: an unacknowledged ciphertext may already be on the
      // peer's wire, so this session can never be reused for a re-encrypt.
      // Drop the pending entry first (so close() cannot error an abandoned
      // completer), then invalidate the session.
      _pendingAcks.remove(message.messageId);
      if (!_closed && _secureState != BleSecureLinkState.failed) {
        await _failSecure(BleAckTimeoutException(message.messageId, timeout));
      }
      throw BleAckTimeoutException(message.messageId, timeout);
    } finally {
      _pendingAcks.remove(message.messageId);
    }
  }

  Future<void> close([Object? error]) async {
    if (_closed) return;
    _closed = true;
    _state = BleSessionState.closed;
    if (secure != null) {
      if (_secureState != BleSecureLinkState.failed) {
        // A failure keeps its terminal state for observability; a clean or
        // transport-driven close moves to closed. Either way there is no
        // plaintext fallback path from here.
        _secureState = BleSecureLinkState.closed;
      }
      _secureHandshakeTimer?.cancel();
      _secureHandshakeTimer = null;
    }
    _closeError = error;
    final secureHandle = _secureHandle;
    _secureHandle = null;
    await _subscription?.cancel();
    _subscription = null;
    if (!_helloCompleter.isCompleted) {
      _helloCompleter.completeError(error ?? const BleLinkClosedException());
    }
    for (final completer in _pendingAcks.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          error is BleLinkClosedException
              ? error
              : BleLinkClosedException(error?.toString() ?? 'BLE link closed'),
        );
      }
    }
    _pendingAcks.clear();
    if (secureHandle != null) {
      // Close the native Noise session and invalidate the handle. The
      // gateway is idempotent; a native close failure must not keep the
      // link half-open, so it is swallowed like the transport close below.
      try {
        await secure?.gateway.closeSession(secureHandle);
      } catch (_) {
        // The native session may already be gone.
      }
    }
    try {
      await transport.close();
    } catch (_) {
      // The native connection may already be gone.
    }
    onClosed?.call(_closeError);
  }

  /// Binds the peer-specific secure context — the pinned remote key and the
  /// expected peer device ID — that the owning application resolves from its
  /// peer store *after* the plaintext HELLO exchange.
  ///
  /// A BLE link does not know the peer's BeChat device ID before the HELLO
  /// (a GATT peripheral address is not the peer identity), so the pin cannot
  /// be known when the session is constructed. This seam must be called while
  /// the link is [BleSecureLinkState.awaitingAuthorization] — after approval
  /// and before [startSecureHandshake] — and it never re-binds a running or
  /// finished handshake. When never called, the constructor-provided values
  /// apply unchanged.
  void bindSecurePeerContext({
    Uint8List? pinnedRemotePublicKey,
    String? expectedPeerDeviceId,
  }) {
    if (secure == null) {
      throw const BleLinkException('Secure mode is not enabled on this link');
    }
    if (_closed || _secureState != BleSecureLinkState.awaitingAuthorization) {
      throw const BleLinkException(
        'The secure peer context can only be bound before the handshake starts',
      );
    }
    if (pinnedRemotePublicKey != null &&
        pinnedRemotePublicKey.length != _pinnedKeyLength) {
      throw ArgumentError.value(
        pinnedRemotePublicKey,
        'pinnedRemotePublicKey',
        'must be a 32-byte public key',
      );
    }
    _boundPinnedRemotePublicKey = pinnedRemotePublicKey == null
        ? null
        : Uint8List.fromList(pinnedRemotePublicKey);
    _boundExpectedPeerDeviceId = expectedPeerDeviceId;
    _secureContextBound = true;
  }

  /// The pin the native engine must enforce: a bound value (runtime path)
  /// otherwise the constructor value (direct-construction path).
  Uint8List? get _effectivePinnedRemotePublicKey => _secureContextBound
      ? _boundPinnedRemotePublicKey
      : secure?.pinnedRemotePublicKey;

  /// The device ID the native engine must authenticate: same precedence as
  /// [_effectivePinnedRemotePublicKey].
  String? get _effectiveExpectedPeerDeviceId => _secureContextBound
      ? _boundExpectedPeerDeviceId
      : secure?.expectedPeerDeviceId;

  /// Explicitly authorizes and starts the Noise XX handshake (application
  /// approval seam).
  ///
  /// Call this only after the owning application has approved the connection;
  /// [startSecureHandshake] is the single authorization point — nothing else
  /// in the session begins a handshake on its own. Requires the pre-secure
  /// HELLO exchange to have completed ([BleSecureLinkState]
  /// .awaitingAuthorization).
  ///
  /// The BLE peripheral maps to the Noise initiator and starts the exchange;
  /// the BLE central maps to the Noise responder and waits for message 1.
  Future<void> startSecureHandshake() async {
    final config = secure;
    if (config == null) {
      throw const BleLinkException('Secure mode is not enabled on this link');
    }
    if (_closed || _secureState == BleSecureLinkState.closed) {
      throw const BleLinkClosedException('BLE link closed');
    }
    if (_secureState != BleSecureLinkState.awaitingAuthorization) {
      throw const BleLinkException(
        'The secure handshake cannot start in the current state',
      );
    }
    _secureState = BleSecureLinkState.handshaking;
    _armSecureHandshakeTimeout();
    try {
      final handle = await config.gateway.createSession(
        initiator: config.role == BleSecureRole.initiator,
        deviceId: identity.deviceId,
        displayName: identity.displayName,
        pinnedRemotePublicKey: _effectivePinnedRemotePublicKey,
        expectedRemoteDeviceId: _effectiveExpectedPeerDeviceId,
      );
      if (_closed) {
        try {
          await config.gateway.closeSession(handle);
        } catch (_) {
          // The link is already gone; nothing further to clean up.
        }
        return;
      }
      _secureHandle = handle;
      if (config.role == BleSecureRole.initiator) {
        final step = await config.gateway.startHandshake(handle);
        if (_closed || !identical(_secureHandle, handle)) {
          // Closed or replaced while the native call was in flight.
          return;
        }
        await _applyHandshakeStep(config, handle, step);
      }
      // The responder waits for the initiator's message 1 over the link.
    } catch (error) {
      if (!_closed && _secureState != BleSecureLinkState.failed) {
        await _failSecure(error);
      }
      rethrow;
    }
  }

  /// Explicitly accepts the authenticated remote identity surfaced by a
  /// finished handshake, moving the link to secure-ready.
  ///
  /// This is the application's identity-confirmation decision; the session
  /// never confirms on its own and never writes any peer state.
  Future<void> confirmSecurePeerIdentity() async {
    final config = secure;
    final handle = _secureHandle;
    if (config == null) {
      throw const BleLinkException('Secure mode is not enabled on this link');
    }
    if (handle == null ||
        _secureState != BleSecureLinkState.awaitingConfirmation) {
      throw const BleLinkException(
        'There is no authenticated peer identity awaiting confirmation',
      );
    }
    try {
      await config.gateway.confirmPeerIdentity(handle);
    } catch (error) {
      if (!_closed && _secureState != BleSecureLinkState.failed) {
        await _failSecure(error);
      }
      rethrow;
    }
    if (_closed || !identical(_secureHandle, handle)) {
      // Closed or replaced while confirmation was in flight.
      return;
    }
    _secureHandshakeTimer?.cancel();
    _secureHandshakeTimer = null;
    _secureState = BleSecureLinkState.secureReady;
    _state = BleSessionState.ready;
  }

  /// Applies one native handshake step: transmits any outbound handshake
  /// message over protocol-v2 framing and, when the handshake finished,
  /// validates the authenticated identity before exposing it.
  Future<void> _applyHandshakeStep(
    BleSecureSessionConfig config,
    SecureSessionHandle handle,
    HandshakeStepResult step,
  ) async {
    if (step.outgoing.isNotEmpty) {
      final outgoing = step.outgoing;
      await _enqueue(() async {
        await _writeSecureTransfer(
          BleSecureTransferKind.secureHandshake,
          outgoing,
        );
      });
    }
    if (!step.finished) return;

    _secureHandshakeTimer?.cancel();
    _secureHandshakeTimer = null;

    final remote = step.remoteIdentity;
    if (remote == null) {
      await _failSecure(
        const BleLinkException(
          'The secure handshake finished without an authenticated identity',
        ),
      );
      return;
    }
    final expected = _effectiveExpectedPeerDeviceId;
    if (expected != null && remote.deviceId != expected) {
      // Fail closed on an authenticated identity that is not the expected
      // peer. Nothing is persisted and no saved peer is overwritten.
      await _failSecure(
        const BleLinkException(
          'The authenticated peer does not match the expected peer',
        ),
      );
      return;
    }
    final hello = _hello;
    if (config.requireHelloBinding &&
        (hello == null || remote.deviceId != hello.deviceId)) {
      // The plaintext HELLO is an unauthenticated hint; when binding is
      // required, disagreement with the authenticated identity fails
      // closed. The authenticated fields are never rewritten from HELLO.
      await _failSecure(
        const BleLinkException(
          'The authenticated peer does not match the exchanged HELLO',
        ),
      );
      return;
    }
    if (_closed || !identical(_secureHandle, handle)) {
      return;
    }
    _secureRemoteIdentity = remote;
    _secureState = BleSecureLinkState.awaitingConfirmation;
    // The application's validation/confirmation step runs here, in the
    // inbound-frame queue: awaiting it means the next frame cannot be
    // processed until this side has confirmed (or failed), so an early
    // secure message from a peer that finished first can never race ahead of
    // local confirmation. A thrown validation fails the link closed.
    await config.onRemoteIdentity?.call(remote);
  }

  /// Sends one opaque Noise payload (handshake message, encrypted application
  /// message, or encrypted acknowledgement) over protocol-v2 framing through
  /// the existing write serialization path.
  Future<void> _writeSecureTransfer(
    BleSecureTransferKind kind,
    Uint8List payload,
  ) async {
    final frames = BleSecureTransferCodec.fragment(
      kind: kind,
      payload: payload,
      maxWriteLength: transport.maximumWriteLength,
      transferId: _nextTransferId(),
    );
    for (final frame in frames) {
      await transport.write(frame);
    }
  }

  void _armSecureHandshakeTimeout() {
    _secureHandshakeTimer?.cancel();
    _secureHandshakeTimer = Timer(handshakeTimeout, () {
      if (_closed || _secureState != BleSecureLinkState.handshaking) return;
      unawaited(_failSecure(const BleSecureHandshakeTimeoutException()));
    });
  }

  /// Fails the secure session closed: marks it failed, tears down the native
  /// session, and closes the link. Never falls back to plaintext.
  Future<void> _failSecure(Object error) async {
    _secureState = BleSecureLinkState.failed;
    _secureHandshakeTimer?.cancel();
    _secureHandshakeTimer = null;
    if (!_closed) {
      await close(error);
    }
  }

  void _queueIncoming(Uint8List bytes) {
    _rxTail = _rxTail.then((_) async {
      if (_closed) return;
      try {
        if (secure != null && _isSecureVersionFrame(bytes)) {
          final frame = BleSecureFrame.decode(bytes);
          final transfer = _secureAssembler.add(frame);
          if (transfer != null) {
            await _handleSecureTransfer(transfer);
          }
          return;
        }
        final frame = BleFrame.decode(bytes);
        final transfer = _assembler.add(frame);
        if (transfer != null) {
          await _handleTransfer(transfer);
        }
      } catch (error) {
        if (secure != null &&
            _secureState != BleSecureLinkState.failed &&
            _secureState != BleSecureLinkState.closed) {
          // Secure-mode protocol or gateway failures are terminal: mark the
          // secure session failed (which tears down the native session and
          // closes the link). Never a plaintext fallback.
          await _failSecure(error);
        } else {
          await close(error);
        }
      }
    });
  }

  /// Phase-aware dispatch: only a secure-mode session routes protocol-v2
  /// frames to the secure decoder, and only the version byte decides. A
  /// legacy session never consults the secure decoder at all, and a v1
  /// frame never reaches it either. Frames with any other version fall
  /// through to the v1 decoder, which rejects them.
  bool _isSecureVersionFrame(Uint8List bytes) =>
      bytes.length >= 2 && bytes[1] == BleSecureProtocol.version;

  Future<void> _handleSecureTransfer(BleSecureTransfer transfer) async {
    // Enforce the per-kind size bounds on receive, before any native call
    // allocates for the payload. The engine has its own limits; this keeps
    // the BLE framing layer from forwarding an oversized handshake or
    // transport payload.
    BleSecureTransferCodec.validatePayload(transfer.kind, transfer.payload);
    switch (transfer.kind) {
      case BleSecureTransferKind.secureHandshake:
        await _handleSecureHandshake(transfer.payload);
      case BleSecureTransferKind.secureMessage:
        await _handleSecureMessage(transfer.payload);
      case BleSecureTransferKind.secureAck:
        await _handleSecureAck(transfer.payload);
    }
  }

  /// The confirmed Noise session used for application transport.
  ///
  /// Application traffic is acceptable only on this session's own confirmed,
  /// ready transport; anything else fails closed (never a plaintext path).
  (BleSecureSessionConfig, SecureSessionHandle) _requireSecureTransport(
    String what,
  ) {
    final config = secure;
    final handle = _secureHandle;
    if (config == null ||
        handle == null ||
        _closed ||
        _secureState != BleSecureLinkState.secureReady) {
      throw BleLinkException('Unexpected secure $what');
    }
    return (config, handle);
  }

  /// Secure-mode inbound application message: reassemble, decrypt exactly once
  /// through the Noise gateway, decode with the existing application codec,
  /// reuse the existing [onMessage] callback (validation, persistence, dedup)
  /// and its [BleAckResult], then encrypt that ACK and send it as a v2
  /// `secureAck`.
  ///
  /// Nothing is stored before authenticated decryption and decoding succeed,
  /// and a decrypt/decode failure propagates to [_queueIncoming], which fails
  /// the session closed rather than falling back to the legacy handler.
  Future<void> _handleSecureMessage(Uint8List payload) async {
    final (config, handle) = _requireSecureTransport('message');
    final plaintext = await config.gateway.decrypt(handle, payload);
    if (_closed || !identical(_secureHandle, handle)) {
      // The link was closed or the session replaced while the native call was
      // in flight; this late plaintext must not change any state.
      return;
    }
    // Authenticated plaintext, decoded once. Any malformed payload throws and
    // tears the session down; it is never retried as a legacy message.
    final message = BleMessagePayload.decode(plaintext);

    final remote = _secureRemoteIdentity;
    if (remote == null) {
      throw const BleLinkException('Secure session has no authenticated peer');
    }

    BleAckResult result;
    String? reason;
    try {
      if (message.metadata.receiverId != identity.deviceId ||
          message.metadata.senderId != remote.deviceId) {
        // Transport-level binding to this session's authenticated peer, on
        // top of the application callback's own linked-peer validation.
        throw const BleLinkException(
          'Secure message does not match the authenticated link',
        );
      }
      result = await onMessage(message);
    } catch (error) {
      // Existing application-level rejection semantics: the reason travels
      // only inside the encrypted acknowledgement, never as plaintext.
      result = BleAckResult.rejected;
      reason = error.toString();
    }

    final ack = BleAck(
      messageId: message.metadata.messageId,
      result: result,
      reason: reason,
    );
    final ackBytes = ack.encode();
    await _enqueue(() async {
      final (config, handle) = _requireSecureTransport('acknowledgement');
      // Encrypt inside the serialized TX path so the send counter advances
      // in wire order, exactly like outbound messages.
      final sealed = await config.gateway.encrypt(handle, ackBytes);
      await _writeSecureTransfer(BleSecureTransferKind.secureAck, sealed);
    });
  }

  /// Secure-mode inbound acknowledgement: decrypt exactly once, decode the
  /// existing ACK representation, and complete only the pending operation
  /// whose message ID matches.
  ///
  /// A valid but unmatched ACK is consumed (so the receive counter stays in
  /// sync) and then ignored; a malformed ACK fails the session closed. The
  /// decrypt always happens before the correlation decision, and only on this
  /// session's own confirmed transport.
  Future<void> _handleSecureAck(Uint8List payload) async {
    final (config, handle) = _requireSecureTransport('acknowledgement');
    final plaintext = await config.gateway.decrypt(handle, payload);
    if (_closed || !identical(_secureHandle, handle)) {
      // A late ACK from a closed or replaced session completes nothing.
      return;
    }
    final ack = BleAck.decode(plaintext);
    final completer = _pendingAcks[ack.messageId];
    if (completer == null || completer.isCompleted) return;
    _pendingAcks.remove(ack.messageId);
    completer.complete(ack);
  }

  Future<void> _handleSecureHandshake(Uint8List payload) async {
    final config = secure;
    final handle = _secureHandle;
    if (config == null ||
        handle == null ||
        _secureState != BleSecureLinkState.handshaking) {
      // Handshake messages are only valid while this session's own Noise
      // handshake is running; anything else fails closed.
      throw const BleLinkException('Unexpected secure handshake message');
    }
    final HandshakeStepResult step;
    try {
      step = await config.gateway.processHandshake(handle, payload);
    } catch (error) {
      // A poisoned handshake step may be the engine refusing a remote key
      // that differs from the pin. Ask the engine's status snapshot — never
      // its message text — whether an authenticated remote key arrived, and
      // tell the application so it can record the conflict while keeping the
      // original pin. Nothing is swallowed: the original failure still fails
      // the link closed below.
      await _notifyPinnedKeyConflict(config, handle);
      rethrow;
    }
    if (_closed || !identical(_secureHandle, handle)) {
      // The link was closed or the session replaced while the native call
      // was in flight; this late result must not change any state.
      return;
    }
    await _applyHandshakeStep(config, handle, step);
  }

  /// Reports a pinned-key conflict to the application after a failed native
  /// handshake step, but only when the engine's own snapshot proves the peer
  /// presented a *different* authenticated key. Any uncertainty — no remote
  /// key reported, snapshot unavailable, or an identical key — reports
  /// nothing: a timeout or malformed message must never be mistaken for an
  /// identity change. The link fails closed either way.
  Future<void> _notifyPinnedKeyConflict(
    BleSecureSessionConfig config,
    SecureSessionHandle handle,
  ) async {
    final callback = config.onPinnedKeyMismatch;
    final pin = _effectivePinnedRemotePublicKey;
    if (callback == null || pin == null) return;
    String? remoteKeyHex;
    try {
      final status = await config.gateway.getSessionStatus(handle);
      remoteKeyHex = status.remotePublicKeyHex;
    } catch (_) {
      // The session could not report a snapshot: no evidence of a conflict.
      return;
    }
    if (remoteKeyHex == null || _hexOf(pin) == remoteKeyHex) return;
    await callback();
  }

  /// Lowercase-hex encoding used to compare non-secret public key material.
  static String _hexOf(List<int> bytes) {
    const digits = '0123456789abcdef';
    final out = StringBuffer();
    for (final byte in bytes) {
      out.write(digits[byte >> 4]);
      out.write(digits[byte & 0x0f]);
    }
    return out.toString();
  }

  Future<void> _handleTransfer(BleTransfer transfer) async {
    if (secure != null &&
        (transfer.kind == BleTransferKind.message ||
            transfer.kind == BleTransferKind.acknowledgement)) {
      // A secure-mode link never accepts plaintext application messages or
      // ACKs, in any state. There is no downgrade path.
      throw const BleLinkException(
        'Plaintext application traffic is not accepted on a secure link',
      );
    }
    switch (transfer.kind) {
      case BleTransferKind.hello:
        await _handleHello(transfer.payload);
      case BleTransferKind.message:
        await _handleMessage(transfer.payload);
      case BleTransferKind.acknowledgement:
        await _handleAcknowledgement(transfer.payload);
      case BleTransferKind.error:
        final error = BleErrorPayload.decode(transfer.payload);
        await close(BleLinkException('${error.code}: ${error.message}'));
    }
  }

  Future<void> _handleHello(Uint8List bytes) async {
    if (_hello != null) {
      throw const BleProtocolException('Duplicate HELLO');
    }
    final hello = BleHello.decode(bytes);
    hello.validate(localDeviceId: identity.deviceId);
    if (secure != null &&
        !hello.capabilities.contains(BleProtocol.capabilitySecureNoise)) {
      // Secure mode with a peer that cannot do secure messaging: fail before
      // any approval workflow runs, before any handshake starts, and without
      // writing a single plaintext application byte. This throw propagates to
      // the incoming queue, which fails the secure session closed (never a
      // plaintext fallback), and it also fails the pending HELLO exchange, so
      // the owning application sees one clear "peer update required" failure
      // instead of an approval request it would have to decline by hand.
      final error = const BleSecurePeerUnsupportedException();
      if (!_helloCompleter.isCompleted) {
        _helloCompleter.completeError(error);
      }
      throw error;
    }
    try {
      await onHello(hello);
    } catch (error) {
      await _sendError('hello_rejected', error.toString());
      throw BleHelloRejectedException(error.toString());
    }
    if (!_helloCompleter.isCompleted) {
      _helloCompleter.complete(hello);
    }
  }

  Future<void> _handleMessage(Uint8List bytes) async {
    if (!isReady) {
      throw const BleProtocolException(
        'Message received before HELLO completed',
      );
    }
    BleMessagePayload message;
    try {
      message = BleMessagePayload.decode(bytes);
    } on BleProtocolException {
      rethrow;
    }

    BleAckResult result;
    String? reason;
    try {
      result = await onMessage(message);
    } catch (error) {
      result = BleAckResult.rejected;
      reason = error.toString();
    }
    final ack = BleAck(
      messageId: message.metadata.messageId,
      result: result,
      reason: reason,
    );
    await _enqueue(() async {
      await _writeTransfer(BleTransferKind.acknowledgement, ack.encode());
    });
  }

  Future<void> _handleAcknowledgement(Uint8List bytes) async {
    final ack = BleAck.decode(bytes);
    final completer = _pendingAcks.remove(ack.messageId);
    if (completer == null || completer.isCompleted) return;
    completer.complete(ack);
  }

  Future<void> _sendError(String code, String message) async {
    try {
      final payload = BleErrorPayload(code: code, message: message).encode();
      await _enqueue(() async {
        await _writeTransfer(BleTransferKind.error, payload);
      });
    } catch (_) {
      // The link is already unusable; closing is the only remaining action.
    }
  }

  Future<void> _writeTransfer(BleTransferKind kind, Uint8List payload) async {
    final frames = BleTransferCodec.fragment(
      kind: kind,
      payload: payload,
      maxWriteLength: transport.maximumWriteLength,
      transferId: _nextTransferId(),
    );
    for (final frame in frames) {
      await transport.write(frame);
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _txTail.then((_) => action());
    _txTail = next.catchError((Object _) {});
    return next;
  }

  int _nextTransferId() {
    final value = _transferIdFactory();
    if (value < 0 || value > 0xffff) {
      throw const BleLinkException('Invalid transfer id');
    }
    return value;
  }

  int _utf8Length(String value) {
    var length = 0;
    for (final rune in value.runes) {
      if (rune <= 0x7f) {
        length += 1;
      } else if (rune <= 0x7ff) {
        length += 2;
      } else if (rune <= 0xffff) {
        length += 3;
      } else {
        length += 4;
      }
    }
    return length;
  }
}
