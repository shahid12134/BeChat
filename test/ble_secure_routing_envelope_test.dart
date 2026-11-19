import 'dart:convert';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_routing_envelope.dart';
import 'package:bechat/core/ble/ble_secure_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/data/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/ble_secure_fixtures.dart';

// Routing-envelope transport over the secure BLE link session (Phase 3D.1).
//
// Envelopes travel inside the existing Noise secureMessage/secureAck framing,
// so these tests reuse the same fake gateway and fake transport as the secure
// message suite. They prove dispatch, ACK correlation and fail-closed
// behaviour of the envelope path; they are NOT evidence that the underlying
// cryptography is sound (that lives in the Rust engine tests).

void main() {
  group('inbound envelope dispatch', () {
    test('a valid routing envelope reaches the routing callback and is '
        'acknowledged with the envelope ID', () async {
      final pair = SecurePair();
      await pair.ready();

      final result = await pair.sessionA.sendEnvelope(
        _envelope(envelopeId: 'env-42'),
      );

      expect(result, BleAckResult.stored);
      expect(pair.receivedEnvelopesOnB, hasLength(1));
      final received = pair.receivedEnvelopesOnB.single;
      expect(received.envelopeId, 'env-42');
      expect(received.originDeviceId, 'device-a');
      expect(received.destinationDeviceId, 'device-b');
      expect(
        pair.receivedOnB,
        isEmpty,
        reason: 'an envelope is never delivered as a direct message',
      );

      // The ACK that completed the send names the envelope, not a message ID.
      final ackTransfer = _transferOfKind(
        secureTransfersWritten(pair.transportB),
        BleSecureTransferKind.secureAck,
      );
      final ack = BleAck.decode(
        pair.gateway.openFor(pair.sessionBHandle, ackTransfer.payload),
      );
      expect(ack.messageId, 'env-42');
      expect(ack.result, BleAckResult.stored);

      // Still an encrypted-only link: no plaintext frame beyond the HELLO.
      expect(v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
      expect(v1KindsWritten(pair.transportB), [BleTransferKind.hello]);
      expect(pair.sessionA.isSecureReady, isTrue);
      expect(pair.sessionB.isSecureReady, isTrue);
    });

    test('a forwarded envelope may originate from a device other than the '
        'authenticated relay peer', () async {
      final pair = SecurePair();
      await pair.ready();

      final result = await pair.sessionA.sendEnvelope(
        _envelope(
          envelopeId: 'env-relay',
          originDeviceId: 'device-originator',
          destinationDeviceId: 'device-b',
        ),
      );

      expect(result, BleAckResult.stored);
      expect(pair.receivedEnvelopesOnB, hasLength(1));
      expect(pair.receivedEnvelopesOnB.single.originDeviceId,
          'device-originator');
      // B's authenticated transport peer is device-a; the envelope origin is
      // a different device, and no direct-message sender check rejected it.
      expect(pair.sessionB.secureRemoteIdentity!.deviceId, 'device-a');
      expect(pair.sessionB.isSecureReady, isTrue);
      expect(pair.sessionB.state, BleSessionState.ready);
      expect(pair.receivedOnB, isEmpty);
    });

    test('a malformed routing envelope fails the session closed and is never '
        'decoded as a direct message', () async {
      final pair = SecurePair();
      await pair.ready();

      // Right magic, unsupported version, zero-filled header: the routing
      // decoder must reject it outright.
      final malformed = Uint8List.fromList([
        BleRoutingEnvelope.magic,
        ...List.filled(BleRoutingEnvelope.headerLength - 1, 0),
      ]);
      _deliverSecure(
        pair.transportA,
        BleSecureTransferKind.secureMessage,
        pair.gateway.sealFor(pair.sessionBHandle, malformed),
        transferId: 41,
      );
      await pair.pump();

      expect(pair.sessionA.secureState, BleSecureLinkState.failed);
      expect(pair.sessionA.state, BleSessionState.closed);
      expect(pair.receivedEnvelopesOnA, isEmpty);
      expect(
        pair.receivedOnA,
        isEmpty,
        reason: 'a malformed envelope is never retried as a direct message',
      );
      expect(pair.closedErrorsA.single, isA<BleProtocolException>());
      expect(v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
    });

    test('direct secure messaging is unchanged alongside envelope dispatch',
        () async {
      final pair = SecurePair();
      await pair.ready();

      final result = await pair.sessionA.sendMessage(testMessage());

      expect(result, BleAckResult.stored);
      expect(pair.receivedOnB, hasLength(1));
      expect(pair.receivedOnB.single.content, 'Hello from A');
      expect(
        pair.receivedEnvelopesOnB,
        isEmpty,
        reason: 'a direct message never reaches the routing callback',
      );
    });
  });

  group('outbound envelope boundary', () {
    test('envelope transmission requires a confirmed secure session', () async {
      final pair = SecurePair();
      await pair.start();

      // HELLO exchanged, handshake not authorized.
      await expectLater(
        pair.sessionA.sendEnvelope(_envelope()),
        throwsA(isA<BleLinkException>()),
      );

      // Handshake finished but not confirmed.
      await pair.authorize();
      await pair.pump();
      await expectLater(
        pair.sessionA.sendEnvelope(_envelope()),
        throwsA(isA<BleLinkException>()),
      );

      // Confirmed session, then closed: still refused.
      await pair.confirmBoth();
      await pair.sessionA.close();
      await expectLater(
        pair.sessionA.sendEnvelope(_envelope()),
        throwsA(isA<BleLinkClosedException>()),
      );
      expect(v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
    });

    test('a legacy session refuses envelope transmission', () async {
      final pair = _LegacyPair();
      await pair.start();

      await expectLater(
        pair.sessionA.sendEnvelope(_envelope()),
        throwsA(isA<BleLinkException>()),
      );
      expect(pair.sessionA.secureState, isNull);
      expect(v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
    });

    test('a legacy link does not accept a routing envelope through plaintext',
        () async {
      final pair = _LegacyPair();
      await pair.start();

      for (final frame in BleTransferCodec.fragment(
        kind: BleTransferKind.message,
        payload: _envelope(envelopeId: 'env-plaintext').encode(),
        maxWriteLength: pair.transportB.maximumWriteLength,
        transferId: 9,
      )) {
        pair.transportB.deliver(frame);
      }
      await pair.pump();

      expect(
        pair.receivedEnvelopesOnB,
        isEmpty,
        reason: 'plaintext routing is never accepted on a legacy link',
      );
      expect(pair.receivedOnB, isEmpty);
      expect(pair.sessionB.state, BleSessionState.closed);
    });
  });
}

/// A well-formed envelope whose inner payload is a valid v2 message, as
/// required by the routing codec's decode-time validation.
BleRoutingEnvelope _envelope({
  String envelopeId = 'env-1',
  String originDeviceId = 'device-a',
  String destinationDeviceId = 'device-b',
}) {
  const content = 'inner payload';
  final now = DateTime.utc(2026, 3, 4, 5, 6);
  return BleRoutingEnvelope(
    envelopeId: envelopeId,
    originDeviceId: originDeviceId,
    destinationDeviceId: destinationDeviceId,
    createdAt: now,
    expiresAt: now.add(const Duration(minutes: 5)),
    hopLimit: 3,
    payload: BleMessagePayload(
      metadata: BleMessageMetadata(
        messageId: 'inner-1',
        senderId: originDeviceId,
        receiverId: destinationDeviceId,
        messageType: MessageType.text.name,
        timestamp: now,
        ttl: 300,
        contentLength: utf8.encode(content).length,
        isEncrypted: false,
      ),
      content: content,
    ).encode(),
  );
}

void _deliverSecure(
  FakeTransport transport,
  BleSecureTransferKind kind,
  Uint8List payload, {
  required int transferId,
}) {
  for (final frame in BleSecureTransferCodec.fragment(
    kind: kind,
    payload: payload,
    maxWriteLength: transport.maximumWriteLength,
    transferId: transferId,
  )) {
    transport.deliver(frame);
  }
}

BleSecureTransfer _transferOfKind(
  List<BleSecureTransfer> transfers,
  BleSecureTransferKind kind,
) {
  final matches = transfers.where((t) => t.kind == kind).toList();
  expect(
    matches,
    hasLength(1),
    reason: 'expected exactly one $kind transfer on this link',
  );
  return matches.single;
}

/// A legacy v1 pair wired the way the runtime wires non-secure sessions,
/// with a routing callback bound so a plaintext rejection is observable.
class _LegacyPair {
  _LegacyPair() {
    transportA = FakeTransport(64);
    transportB = FakeTransport(48);
    transportA.peer = transportB;
    transportB.peer = transportA;

    sessionA = BleLinkSession(
      transport: transportA,
      identity: testIdentity('device-a', 'Alice'),
      onHello: (hello) async {},
      onMessage: (payload) async => BleAckResult.stored,
      transferIdFactory: () => 1,
    );
    sessionB = BleLinkSession(
      transport: transportB,
      identity: testIdentity('device-b', 'Bob'),
      onHello: (hello) async {},
      onMessage: (payload) async {
        receivedOnB.add(payload);
        return BleAckResult.stored;
      },
      onRoutingEnvelope: (envelope) async {
        receivedEnvelopesOnB.add(envelope);
        return BleAckResult.stored;
      },
      transferIdFactory: () => 2,
    );
  }

  late final FakeTransport transportA;
  late final FakeTransport transportB;
  late final BleLinkSession sessionA;
  late final BleLinkSession sessionB;
  final List<BleMessagePayload> receivedOnB = [];
  final List<BleRoutingEnvelope> receivedEnvelopesOnB = [];

  Future<void> start() => Future.wait([sessionA.start(), sessionB.start()]);

  /// Lets queued transport hops and stream deliveries settle.
  Future<void> pump([int rounds = 20]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}
