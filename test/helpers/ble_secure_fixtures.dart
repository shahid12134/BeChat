import 'dart:async';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_routing_envelope.dart';
import 'package:bechat/core/ble/ble_secure_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/services/crypto/native_secure_session_service.dart';

// Shared fixtures for the secure BLE link-session test suites.
//
// The fake gateway mirrors the *call contract* of the native Noise engine:
// XX message ordering, finishing steps that carry the authenticated identity,
// pin enforcement at completion, confirmation gating before any transport
// call, and exactly one encrypt/decrypt call per transport payload.
//
// Its encrypt/decrypt use a deterministic stand-in ("fake AEAD": XOR body
// plus a magic/checksum tag sized exactly like Noise, plaintext + 16 bytes)
// so tests can prove that application bytes are opaque on the wire, that a
// tampered or foreign payload is rejected *before* application decoding, and
// how many transport operations a session performed. This is NOT
// cryptography and NOT evidence that the real encryption is sound; that
// evidence lives in the Rust engine tests and the native instrumentation
// tests.

final Uint8List emptyBytes = Uint8List(0);
final Uint8List secureMsg1 = Uint8List.fromList([0x11, 0x11, 0x11]);
final Uint8List secureMsg2 = Uint8List.fromList([0x22, 0x22]);
final Uint8List secureMsg3 = Uint8List.fromList([0x33, 0x33, 0x33, 0x33]);

String hexOf(Uint8List bytes) {
  const digits = '0123456789abcdef';
  final out = StringBuffer();
  for (final byte in bytes) {
    out.write(digits[byte >> 4]);
    out.write(digits[byte & 0x0f]);
  }
  return out.toString();
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Deterministic stand-in key shared by both sides of one fake pair. Public
/// and fixed on purpose: it only has to make ciphertext differ from
/// plaintext, never to resist an attacker.
const List<int> _fakeKey = [
  0x5c,
  0xa1,
  0xab,
  0x1e,
  0x9f,
  0x37,
  0xd4,
  0x2b,
  0x68,
  0x41,
  0xe2,
  0x75,
  0x0c,
  0x53,
  0x8a,
  0xd9,
];

const List<int> _fakeTagMagic = [0x42, 0x45, 0x43, 0x32];

/// Fake-AEAD seal: `ciphertext == plaintext.length + 16`, matching the Noise
/// transport framing so size-boundary tests behave like production.
Uint8List fakeSeal(List<int> plaintext) {
  final body = Uint8List(plaintext.length);
  for (var i = 0; i < plaintext.length; i++) {
    body[i] = plaintext[i] ^ _fakeKey[i % _fakeKey.length];
  }
  final sealed = Uint8List(body.length + 16);
  sealed.setAll(0, body);
  final tag = ByteData.sublistView(sealed, body.length, body.length + 16);
  for (var i = 0; i < 4; i++) {
    tag.setUint8(i, _fakeTagMagic[i]);
  }
  tag.setUint32(4, BleSecureTransferCodec.checksum(body), Endian.big);
  for (var i = 8; i < 16; i++) {
    tag.setUint8(i, _fakeKey[(i + body.length) % _fakeKey.length] ^ 0x5a);
  }
  return sealed;
}

/// Fake-AEAD open: rejects anything whose tag is missing, foreign or does not
/// match the body, exactly where the engine rejects an unauthenticated
/// transport payload.
Uint8List fakeOpen(List<int> ciphertext) {
  if (ciphertext.length < 16) {
    throw const SecureSessionNativeFailure('transport authentication failed');
  }
  final body = ciphertext.sublist(0, ciphertext.length - 16);
  final tag = ByteData.sublistView(
    Uint8List.fromList(ciphertext.sublist(ciphertext.length - 16)),
  );
  for (var i = 0; i < 4; i++) {
    if (tag.getUint8(i) != _fakeTagMagic[i]) {
      throw const SecureSessionNativeFailure('transport authentication failed');
    }
  }
  if (tag.getUint32(4, Endian.big) != BleSecureTransferCodec.checksum(body)) {
    throw const SecureSessionNativeFailure('transport authentication failed');
  }
  final plain = Uint8List(body.length);
  for (var i = 0; i < body.length; i++) {
    plain[i] = body[i] ^ _fakeKey[i % _fakeKey.length];
  }
  return plain;
}

class FakeDevice {
  const FakeDevice(this.deviceId, this.displayName, this.staticKey);

  final String deviceId;
  final String displayName;
  final Uint8List staticKey;

  RemoteAuthenticatedIdentity get identity => RemoteAuthenticatedIdentity(
    publicKeyHex: hexOf(staticKey),
    deviceId: deviceId,
    displayName: displayName,
    protocolVersion: 1,
    capabilities: 1,
  );
}

final deviceA = FakeDevice(
  'device-a',
  'Alice',
  Uint8List.fromList(List.filled(32, 0xaa)),
);

final deviceB = FakeDevice(
  'device-b',
  'Bob',
  Uint8List.fromList(List.filled(32, 0xbb)),
);

class _FakeSession {
  _FakeSession({
    required this.handle,
    required this.initiator,
    required this.localDeviceId,
    required this.pinned,
    required this.expectedRemoteDeviceId,
  });

  final SecureSessionHandle handle;
  final bool initiator;
  final String localDeviceId;
  final Uint8List? pinned;
  final String? expectedRemoteDeviceId;

  /// 0: nothing exchanged. Initiator: 1 after msg1. Responder: 1 after msg2.
  int step = 0;
  bool finished = false;

  /// Mirrors the engine: transport calls are refused until the peer identity
  /// is explicitly confirmed.
  bool confirmed = false;

  /// Authenticated remote static key recorded at handshake completion —
  /// set *before* the pin check, exactly like the engine, so a pinned-key
  /// conflict still exposes the authenticated key through a status snapshot.
  String? remoteKeyHex;

  /// Set when the pin check rejected the authenticated remote key. The
  /// session then reports the `failed` stage forever.
  bool pinFailed = false;
}

class FakeSecureGateway implements SecureSessionGateway {
  FakeSecureGateway({
    required List<FakeDevice> devices,
    this.remoteIdentityOverride,
  }) : _devices = {for (final d in devices) d.deviceId: d};

  final Map<String, FakeDevice> _devices;

  /// Local deviceId -> identity to present as that session's remote peer.
  /// Used to script authenticated-identity mismatches.
  final RemoteAuthenticatedIdentity? Function(String localDeviceId)?
  remoteIdentityOverride;

  final List<String> calls = [];
  final List<SecureSessionHandle> createdHandles = [];
  final List<SecureSessionHandle> closedHandles = [];

  /// Every plaintext handed to [encrypt] and every ciphertext handed to
  /// [decrypt] by a session under test.
  final List<Uint8List> applicationCryptoCalls = [];

  /// Encrypt/decrypt call counts per handle: the counter-safety evidence
  /// (exactly one encryption per send, no second attempt after a failure,
  /// one decrypt per received transfer).
  final List<SecureSessionHandle> encryptHandles = [];
  final List<SecureSessionHandle> decryptHandles = [];

  Uint8List? pinForwardedA;

  /// Every pin forwarded to [createSession], keyed by the session's local
  /// device ID. Tests with UUID device IDs (the real runtime identity is a
  /// UUID) assert pin forwarding through this map.
  final Map<String, Uint8List?> pinsForwarded = {};

  SecureSessionException? failCreateSession;
  bool failEncrypt = false;
  bool failDecrypt = false;
  String? parkProcessHandshakeFor;
  Completer<HandshakeStepResult>? _parked;
  void Function(HandshakeStepResult step)? releaseParked;

  final Map<SecureSessionHandle, _FakeSession> _sessions = {};
  int _nextHandleValue = 100;

  List<String> callsFor(String deviceId) => calls
      .where((c) => c.contains('($deviceId,') || c.contains('($deviceId)'))
      .toList();

  /// Number of [verb] calls made for one device, e.g. `encryptCount('device-a')`.
  int countFor(String deviceId, String verb) =>
      callsFor(deviceId).where((c) => c.startsWith('$verb(')).length;

  FakeDevice _remoteOf(String localDeviceId) =>
      _devices.values.firstWhere((d) => d.deviceId != localDeviceId);

  @override
  Future<SecureSessionHandle> createSession({
    required bool initiator,
    required String deviceId,
    required String displayName,
    Uint8List? pinnedRemotePublicKey,
    String? expectedRemoteDeviceId,
  }) async {
    calls.add('createSession($deviceId, initiator=$initiator)');
    if (failCreateSession != null) throw failCreateSession!;
    pinsForwarded[deviceId] = pinnedRemotePublicKey;
    if (deviceId == 'device-a') pinForwardedA = pinnedRemotePublicKey;
    final handle = SecureSessionHandle.forTesting(_nextHandleValue++);
    createdHandles.add(handle);
    _sessions[handle] = _FakeSession(
      handle: handle,
      initiator: initiator,
      localDeviceId: deviceId,
      pinned: pinnedRemotePublicKey,
      expectedRemoteDeviceId: expectedRemoteDeviceId,
    );
    return handle;
  }

  @override
  Future<HandshakeStepResult> startHandshake(
    SecureSessionHandle session,
  ) async {
    final s = _require(session);
    calls.add('startHandshake(${s.localDeviceId})');
    if (!s.initiator) {
      throw const SecureSessionNativeFailure('only the initiator starts');
    }
    if (s.step != 0 || s.finished) {
      throw const SecureSessionNativeFailure('handshake already started');
    }
    s.step = 1;
    return HandshakeStepResult(
      outgoing: secureMsg1,
      finished: false,
      confirmationRequired: false,
    );
  }

  @override
  Future<HandshakeStepResult> processHandshake(
    SecureSessionHandle session,
    Uint8List incoming,
  ) async {
    final s = _require(session);
    calls.add('processHandshake(${s.localDeviceId})');
    if (s.finished) {
      throw const SecureSessionNativeFailure('handshake already finished');
    }
    if (s.localDeviceId == parkProcessHandshakeFor && _parked == null) {
      _parked = Completer<HandshakeStepResult>();
      releaseParked = (step) {
        // Apply the same session bookkeeping the real branch would have,
        // so a later handshake message still matches the step counter.
        try {
          if (s.step == 0 && bytesEqual(incoming, secureMsg1)) {
            s.step = 1;
          }
          if (step.finished) {
            s.step = 2;
            _finish(s);
          }
          _parked!.complete(step);
        } catch (error) {
          _parked!.completeError(error);
        }
      };
      return _parked!.future;
    }
    if (s.initiator) {
      if (s.step != 1 || !bytesEqual(incoming, secureMsg2)) {
        throw const SecureSessionNativeFailure('unexpected handshake message');
      }
      s.step = 2;
      _finish(s);
      return HandshakeStepResult(
        outgoing: secureMsg3,
        finished: true,
        confirmationRequired: true,
        remoteIdentity: _identityFor(s),
      );
    }
    if (s.step == 0 && bytesEqual(incoming, secureMsg1)) {
      s.step = 1;
      return HandshakeStepResult(
        outgoing: secureMsg2,
        finished: false,
        confirmationRequired: false,
      );
    }
    if (s.step == 1 && bytesEqual(incoming, secureMsg3)) {
      s.step = 2;
      _finish(s);
      return HandshakeStepResult(
        outgoing: emptyBytes,
        finished: true,
        confirmationRequired: true,
        remoteIdentity: _identityFor(s),
      );
    }
    throw const SecureSessionNativeFailure('unexpected handshake message');
  }

  @override
  Future<SecureSessionStatus> getSessionStatus(
    SecureSessionHandle session,
  ) async {
    final s = _require(session);
    calls.add('getSessionStatus(${s.localDeviceId})');
    // A realistic engine snapshot: never `ready` before the handshake
    // finished AND the peer identity was explicitly confirmed, `failed`
    // once a pin check rejected the remote key, and the authenticated
    // remote identity (key included) only at or after completion.
    final stage = s.pinFailed
        ? SecureSessionStage.failed
        : s.confirmed
        ? SecureSessionStage.ready
        : s.finished
        ? SecureSessionStage.awaitingConfirmation
        : SecureSessionStage.handshaking;
    final identityAvailable = s.finished || s.pinFailed;
    return SecureSessionStatus(
      stage: stage,
      remoteIdentityAvailable: identityAvailable,
      remotePublicKeyHex: identityAvailable ? s.remoteKeyHex : null,
    );
  }

  @override
  Future<void> confirmPeerIdentity(SecureSessionHandle session) async {
    final s = _require(session);
    calls.add('confirmPeerIdentity(${s.localDeviceId})');
    if (!s.finished) {
      throw const SecureSessionNativeFailure('handshake not finished');
    }
    s.confirmed = true;
  }

  @override
  Future<Uint8List> encrypt(SecureSessionHandle session, Uint8List plaintext) {
    final s = _require(session);
    calls.add('encrypt(${s.localDeviceId})');
    encryptHandles.add(session);
    applicationCryptoCalls.add(plaintext);
    if (failEncrypt) {
      throw const SecureSessionNativeFailure('simulated encrypt failure');
    }
    if (!s.confirmed) {
      throw const SecureSessionNativeFailure('session confirmation required');
    }
    if (plaintext.length > BleSecureProtocol.maxTransportPlaintextBytes) {
      throw const SecureSessionNativeFailure('plaintext is too large');
    }
    return Future.value(fakeSeal(plaintext));
  }

  @override
  Future<Uint8List> decrypt(SecureSessionHandle session, Uint8List ciphertext) {
    final s = _require(session);
    calls.add('decrypt(${s.localDeviceId})');
    decryptHandles.add(session);
    applicationCryptoCalls.add(ciphertext);
    if (failDecrypt) {
      throw SecureSessionNativeFailure('simulated decrypt failure');
    }
    if (!s.confirmed) {
      throw SecureSessionNativeFailure('session confirmation required');
    }
    return Future.value(fakeOpen(ciphertext));
  }

  /// Seals [plaintext] the way the engine would, for tests that must craft an
  /// inbound secure payload from the peer side. It does not touch the
  /// session's recorded encrypt/decrypt counters.
  Uint8List sealFor(SecureSessionHandle session, Uint8List plaintext) {
    _require(session);
    return fakeSeal(plaintext);
  }

  /// Opens a ciphertext the way the engine would, for tests that must read an
  /// acknowledgement's contents. It does not touch the session's counters.
  Uint8List openFor(SecureSessionHandle session, Uint8List ciphertext) {
    _require(session);
    return fakeOpen(ciphertext);
  }

  @override
  Future<void> closeSession(SecureSessionHandle session) async {
    calls.add('closeSession(${_sessions[session]?.localDeviceId ?? '?'})');
    closedHandles.add(session);
    _sessions.remove(session);
  }

  _FakeSession _require(SecureSessionHandle session) {
    final s = _sessions[session];
    if (s == null) {
      throw const SecureSessionClosed('the session is closed');
    }
    return s;
  }

  /// Enforces the pin at completion exactly where the real engine does.
  ///
  /// The authenticated remote key is recorded first: the engine populates
  /// `remote_identity` before the pinned-key comparison, so a pin conflict
  /// remains observable through [getSessionStatus] (`failed` stage plus the
  /// key that mismatched).
  void _finish(_FakeSession s) {
    final remote = _remoteOf(s.localDeviceId);
    s.remoteKeyHex = hexOf(remote.staticKey);
    final pin = s.pinned;
    if (pin != null && !bytesEqual(pin, remote.staticKey)) {
      s.pinFailed = true;
      throw const SecureSessionNativeFailure(
        'remote static key does not match the pinned key',
      );
    }
    s.finished = true;
  }

  RemoteAuthenticatedIdentity _identityFor(_FakeSession s) =>
      remoteIdentityOverride?.call(s.localDeviceId) ??
      _remoteOf(s.localDeviceId).identity;
}

class FakeTransport implements BleTransport {
  FakeTransport(this.maximumWriteLength);

  @override
  final int maximumWriteLength;

  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final List<Uint8List> writes = [];
  FakeTransport? peer;
  bool _closed = false;

  /// Records every write but drops it before the peer sees it: models a
  /// ciphertext or acknowledgement lost on the wire (ACK timeout).
  bool dropWrites = false;

  /// Records every write and then fails it: models a GATT write failure,
  /// where the bytes may or may not have reached the peer.
  bool failWrites = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  /// Simulates the peer delivering raw bytes to this side.
  void deliver(Uint8List value) {
    if (!_closed) _incoming.add(Uint8List.fromList(value));
  }

  @override
  Future<void> write(Uint8List value) async {
    if (_closed || peer == null || peer!._closed) {
      throw const BleLinkException('Transport is closed');
    }
    final copy = Uint8List.fromList(value);
    writes.add(copy);
    if (failWrites) {
      throw const BleLinkException('Simulated GATT write failure');
    }
    if (dropWrites) return;
    await Future<void>.delayed(Duration.zero);
    peer!.deliver(copy);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}

/// Reassembles every v1 frame in [frames] and returns the transfer kinds,
/// letting tests prove no plaintext message/ACK was ever emitted.
List<BleTransferKind> v1KindsOf(Iterable<Uint8List> frames) {
  final assembler = BleTransferAssembler();
  final kinds = <BleTransferKind>[];
  for (final frame in frames) {
    if (frame.length >= 2 && frame[1] == BleSecureProtocol.version) continue;
    try {
      final transfer = assembler.add(BleFrame.decode(frame));
      if (transfer != null) kinds.add(transfer.kind);
    } catch (_) {
      // Not a complete v1 frame; ignore for this classification.
    }
  }
  return kinds;
}

/// [v1KindsOf] for a paired fake transport's recorded writes.
List<BleTransferKind> v1KindsWritten(FakeTransport transport) =>
    v1KindsOf(transport.writes);

/// Reassembles every protocol-v2 transfer in [frames], letting tests inspect
/// the opaque payloads and prove that no application field exists outside the
/// ciphertext.
List<BleSecureTransfer> secureTransfersOf(Iterable<Uint8List> frames) {
  final assembler = BleSecureTransferAssembler();
  final transfers = <BleSecureTransfer>[];
  for (final frame in frames) {
    if (frame.length < 2 || frame[1] != BleSecureProtocol.version) continue;
    final transfer = assembler.add(BleSecureFrame.decode(frame));
    if (transfer != null) transfers.add(transfer);
  }
  return transfers;
}

/// [secureTransfersOf] for a paired fake transport's recorded writes.
List<BleSecureTransfer> secureTransfersWritten(FakeTransport transport) =>
    secureTransfersOf(transport.writes);

Message testMessage({
  String messageId = 'msg-1',
  String senderId = 'device-a',
  String receiverId = 'device-b',
  String content = 'Hello from A',
  int ttl = 3600,
}) {
  final now = DateTime.utc(2026, 2, 3, 4, 5, 6);
  return Message(
    messageId: messageId,
    chatId: 'chat-1',
    senderId: senderId,
    receiverId: receiverId,
    content: content,
    timestamp: now,
    ttl: ttl,
    createdAt: now,
    updatedAt: now,
  );
}

Identity testIdentity(String id, String name) =>
    Identity(deviceId: id, displayName: name);

/// A secure pair: A is the BLE peripheral (Noise initiator), B the BLE
/// central (Noise responder), sharing one fake native engine.
class SecurePair {
  SecurePair({
    Uint8List? pinA,
    String? expectedPeerDeviceIdA,
    bool requireHelloBindingA = false,
    RemoteAuthenticatedIdentity? remoteIdentityForA,
    void Function(RemoteAuthenticatedIdentity identity)? onIdentityA,
    Duration handshakeTimeout = const Duration(seconds: 2),
    bool rejectHelloOnB = false,
    BleAckPolicy ackPolicy = const BleAckPolicy(),
  }) {
    gateway = FakeSecureGateway(
      devices: [deviceA, deviceB],
      remoteIdentityOverride: remoteIdentityForA == null
          ? null
          : (localDeviceId) =>
                localDeviceId == 'device-a' ? remoteIdentityForA : null,
    );
    transportA = FakeTransport(64);
    transportB = FakeTransport(48);
    transportA.peer = transportB;
    transportB.peer = transportA;

    sessionA = BleLinkSession(
      transport: transportA,
      identity: testIdentity('device-a', 'Alice'),
      onHello: (hello) async {},
      onMessage: (payload) async {
        receivedOnA.add(payload);
        final override = onMessageA;
        if (override != null) return override(payload);
        return BleAckResult.stored;
      },
      onRoutingEnvelope: (envelope) async {
        receivedEnvelopesOnA.add(envelope);
        final override = onRoutingEnvelopeA;
        if (override != null) return override(envelope);
        return BleAckResult.stored;
      },
      onClosed: closedErrorsA.add,
      ackPolicy: ackPolicy,
      handshakeTimeout: handshakeTimeout,
      secure: BleSecureSessionConfig(
        gateway: gateway,
        role: BleSecureRole.initiator,
        pinnedRemotePublicKey: pinA,
        expectedPeerDeviceId: expectedPeerDeviceIdA,
        requireHelloBinding: requireHelloBindingA,
        onRemoteIdentity: onIdentityA,
      ),
      transferIdFactory: () => 1,
    );
    sessionB = BleLinkSession(
      transport: transportB,
      identity: testIdentity('device-b', 'Bob'),
      onHello: (hello) async {
        if (rejectHelloOnB) {
          throw const BleLinkException('Peer is blocked');
        }
      },
      onMessage: (payload) async {
        receivedOnB.add(payload);
        final override = onMessageB;
        if (override != null) return override(payload);
        return BleAckResult.stored;
      },
      onRoutingEnvelope: (envelope) async {
        receivedEnvelopesOnB.add(envelope);
        final override = onRoutingEnvelopeB;
        if (override != null) return override(envelope);
        return BleAckResult.stored;
      },
      onClosed: closedErrorsB.add,
      ackPolicy: ackPolicy,
      handshakeTimeout: handshakeTimeout,
      secure: BleSecureSessionConfig(
        gateway: gateway,
        role: BleSecureRole.responder,
        requireHelloBinding: requireHelloBindingA,
        onRemoteIdentity: (identity) => identitySeenOnB = identity,
      ),
      transferIdFactory: () => 2,
    );
  }

  late final FakeSecureGateway gateway;
  late final FakeTransport transportA;
  late final FakeTransport transportB;
  late final BleLinkSession sessionA;
  late final BleLinkSession sessionB;
  final List<Object?> closedErrorsA = [];
  final List<Object?> closedErrorsB = [];
  final List<BleMessagePayload> receivedOnA = [];
  final List<BleMessagePayload> receivedOnB = [];
  RemoteAuthenticatedIdentity? identitySeenOnB;

  /// Optional overrides of the application message callbacks: a test can
  /// script stored/duplicate/rejected results, throw for a policy rejection,
  /// or park persistence until it releases the returned future.
  Future<BleAckResult> Function(BleMessagePayload payload)? onMessageA;
  Future<BleAckResult> Function(BleMessagePayload payload)? onMessageB;

  /// Routing-envelope counterparts of [onMessageA]/[onMessageB]: every
  /// envelope is captured first, then handed to the optional override.
  Future<BleAckResult> Function(BleRoutingEnvelope envelope)?
  onRoutingEnvelopeA;
  Future<BleAckResult> Function(BleRoutingEnvelope envelope)?
  onRoutingEnvelopeB;
  final List<BleRoutingEnvelope> receivedEnvelopesOnA = [];
  final List<BleRoutingEnvelope> receivedEnvelopesOnB = [];

  /// B authorizes first, so its handle is created before A's.
  SecureSessionHandle get sessionBHandle => gateway.createdHandles[0];
  SecureSessionHandle get sessionAHandle => gateway.createdHandles[1];

  Future<void> start() => Future.wait([sessionA.start(), sessionB.start()]);

  /// Authorizes both sides, responder first so it is ready for message 1.
  Future<void> authorize() async {
    await sessionB.startSecureHandshake();
    await sessionA.startSecureHandshake();
  }

  Future<void> confirmBoth() async {
    await sessionA.confirmSecurePeerIdentity();
    await sessionB.confirmSecurePeerIdentity();
  }

  Future<void> ready() async {
    await start();
    await authorize();
    await pump();
    await confirmBoth();
  }

  /// Lets queued transport hops and stream deliveries settle.
  Future<void> pump([int rounds = 20]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}
