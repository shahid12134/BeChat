import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_secure_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/services/crypto/native_secure_session_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/ble_secure_fixtures.dart';

// Secure application-message and acknowledgement transport (Phase 2G).
//
// These tests drive the *opt-in* secure path of BleLinkSession over a fake
// transport and a fake gateway. They prove session behaviour: framing,
// encryption ordering, ACK correlation, fail-closed teardown and the absence
// of any plaintext fallback. They are NOT evidence that the real BLE
// encryption is sound - the cryptography lives in the Rust Noise engine and
// is covered by its own tests plus the native instrumentation tests.

void main() {
  group('outbound secure messages', () {
    test('a valid message is encoded, encrypted and written only as a v2 '
        'secureMessage, then completed by the encrypted ACK', () async {
      final pair = SecurePair();
      await pair.ready();

      final probe = _SendProbe(pair.sessionA.sendMessage(testMessage()));
      await pair.pump(200);
      await probe.done;

      expect(probe.result, BleAckResult.stored);
      expect(
        v1KindsWritten(pair.transportA),
        [BleTransferKind.hello],
        reason: 'no plaintext message frame is ever written',
      );

      final transfers = secureTransfersWritten(pair.transportA);
      expect(
        transfers.map((t) => t.kind),
        contains(BleSecureTransferKind.secureMessage),
      );

      // Exactly one encryption per side: A sealed the message, B sealed the
      // ACK; exactly one decrypt per side: B opened the message, A opened the
      // ACK. This is the ordered counter exchange, nothing more.
      expect(pair.gateway.encryptHandles, [
        pair.sessionAHandle,
        pair.sessionBHandle,
      ]);
      expect(pair.gateway.decryptHandles, [
        pair.sessionBHandle,
        pair.sessionAHandle,
      ]);

      // The inner schema is the existing application payload, unchanged.
      expect(pair.receivedOnB, hasLength(1));
      final received = pair.receivedOnB.single;
      expect(received.metadata.messageId, 'msg-1');
      expect(received.metadata.senderId, 'device-a');
      expect(received.metadata.receiverId, 'device-b');
      expect(received.metadata.contentLength, 'Hello from A'.length);
      expect(received.content, 'Hello from A');
      expect(pair.sessionA.isSecureReady, isTrue);
    });

    test('outer secure frames expose no application field: message ID, '
        'content and identities exist only inside the ciphertext', () async {
      final pair = SecurePair();
      await pair.ready();

      final writtenBefore = pair.transportA.writes.length;
      final probe = _SendProbe(
        pair.sessionA.sendMessage(
          testMessage(
            messageId: 'msg-opaque-42',
            content: 'Top secret payload',
          ),
        ),
      );
      await pair.pump(200);
      await probe.done;
      expect(probe.result, BleAckResult.stored);

      final frames = pair.transportA.writes.sublist(writtenBefore);
      expect(frames, isNotEmpty);
      final onTheWire = _join(frames);
      expect(_containsAscii(onTheWire, 'msg-opaque-42'), isFalse);
      expect(_containsAscii(onTheWire, 'Top secret payload'), isFalse);
      expect(_containsAscii(onTheWire, 'device-a'), isFalse);
      expect(_containsAscii(onTheWire, 'device-b'), isFalse);

      // ...while opening the ciphertext recovers every field, proving the
      // opacity assertion above is not vacuous.
      final messageTransfer = _transferOfKind(
        secureTransfersWritten(pair.transportA),
        BleSecureTransferKind.secureMessage,
      );
      expect(
        _containsAscii(messageTransfer.payload, 'msg-opaque-42'),
        isFalse,
        reason: 'the ciphertext itself carries no plaintext field',
      );
      final opened = pair.gateway.openFor(
        pair.sessionAHandle,
        messageTransfer.payload,
      );
      expect(_containsAscii(opened, 'msg-opaque-42'), isTrue);
      expect(_containsAscii(opened, 'Top secret payload'), isTrue);
    });

    test('the send stays pending until its matching authenticated ACK arrives; '
        'an unmatched ACK completes nothing', () async {
      final pair = SecurePair();
      await pair.ready();

      final releaseB = Completer<BleAckResult>();
      pair.onMessageB = (payload) => releaseB.future;

      final probe = _SendProbe(pair.sessionA.sendMessage(testMessage()));
      await pair.pump(200);
      expect(probe.completed, isFalse, reason: 'B has not acknowledged yet');
      expect(pair.receivedOnB, hasLength(1), reason: 'B did receive it');

      // A valid, correctly encrypted ACK that names a different message must
      // not complete this send - but it must still be decrypted, because a
      // skipped decrypt would desynchronize the receive counter.
      final decryptsBefore = pair.gateway.decryptHandles.length;
      _deliverSecure(
        pair.transportA,
        BleSecureTransferKind.secureAck,
        pair.gateway.sealFor(
          pair.sessionBHandle,
          _ackBytes('someone-elses-message', BleAckResult.stored),
        ),
        transferId: 31,
      );
      await pair.pump(50);
      expect(probe.completed, isFalse, reason: 'unmatched ACK is rejected');
      expect(pair.sessionA.isSecureReady, isTrue);
      expect(
        pair.gateway.decryptHandles.length,
        decryptsBefore + 1,
        reason: 'the unmatched ACK is still decrypted to stay counter-aligned',
      );

      // The genuine ACK for this exact message completes it.
      releaseB.complete(BleAckResult.stored);
      await probe.done;
      expect(probe.result, BleAckResult.stored);
      expect(pair.sessionA.isSecureReady, isTrue);
    });

    test(
      'an ACK that names no pending message is decrypted, then ignored',
      () async {
        final pair = SecurePair();
        await pair.ready();
        final decryptsBefore = pair.gateway.decryptHandles.length;

        _deliverSecure(
          pair.transportA,
          BleSecureTransferKind.secureAck,
          pair.gateway.sealFor(
            pair.sessionBHandle,
            _ackBytes('never-sent', BleAckResult.stored),
          ),
          transferId: 32,
        );
        await pair.pump(50);

        expect(pair.sessionA.isSecureReady, isTrue);
        expect(pair.sessionA.state, BleSessionState.ready);
        expect(pair.gateway.decryptHandles.length, decryptsBefore + 1);
        expect(
          pair.gateway.encryptHandles,
          isEmpty,
          reason: 'an unmatched ACK triggers no reaction of any kind',
        );
      },
    );

    test(
      'a plaintext v1 acknowledgement cannot complete a pending secure send',
      () async {
        final pair = SecurePair();
        await pair.ready();
        // B's encrypted ACK never reaches A, so the send stays pending.
        pair.transportB.dropWrites = true;

        final probe = _SendProbe(pair.sessionA.sendMessage(testMessage()));
        await pair.pump(50);
        expect(probe.completed, isFalse);

        for (final frame in BleTransferCodec.fragment(
          kind: BleTransferKind.acknowledgement,
          payload: _ackBytes('msg-1', BleAckResult.stored),
          maxWriteLength: pair.transportA.maximumWriteLength,
          transferId: 33,
        )) {
          pair.transportA.deliver(frame);
        }
        await pair.pump(50);

        expect(
          probe.result,
          isNull,
          reason: 'no plaintext ACK is ever accepted',
        );
        expect(probe.error, isA<BleLinkClosedException>());
        expect(pair.sessionA.state, BleSessionState.closed);
        expect(pair.sessionA.secureState, BleSecureLinkState.failed);
        expect(
          pair.gateway.countFor('device-a', 'encrypt'),
          1,
          reason: 'exactly one encryption by A: the failure never re-encrypts',
        );
        expect(v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
      },
    );
  });

  group('inbound secure messages', () {
    test(
      'an inbound secureMessage is decrypted before application decoding, '
      'invokes the callback exactly once and returns an encrypted ACK',
      () async {
        final pair = SecurePair();
        await pair.ready();

        final probe = _SendProbe(
          pair.sessionB.sendMessage(
            _messageToA(messageId: 'msg-b1', content: 'from B'),
          ),
        );
        await pair.pump(200);
        await probe.done;

        expect(probe.result, BleAckResult.stored);
        expect(pair.receivedOnA, hasLength(1), reason: 'callback ran once');
        final received = pair.receivedOnA.single;
        expect(received.metadata.messageId, 'msg-b1');
        expect(received.metadata.senderId, 'device-b');
        expect(received.metadata.receiverId, 'device-a');
        expect(received.content, 'from B');

        // One decrypt, then one ACK encryption, per side - in wire order.
        expect(pair.gateway.countFor('device-a', 'decrypt'), 1);
        expect(pair.gateway.countFor('device-a', 'encrypt'), 1);
        expect(pair.gateway.countFor('device-b', 'encrypt'), 1);
        expect(pair.gateway.countFor('device-b', 'decrypt'), 1);

        // The ACK is a secureAck whose fields live only inside the ciphertext.
        final ackTransfer = _transferOfKind(
          secureTransfersWritten(pair.transportA),
          BleSecureTransferKind.secureAck,
        );
        expect(_containsAscii(ackTransfer.payload, 'msg-b1'), isFalse);
        expect(_containsAscii(ackTransfer.payload, 'stored'), isFalse);
        final ack = BleAck.decode(
          pair.gateway.openFor(pair.sessionAHandle, ackTransfer.payload),
        );
        expect(ack.messageId, 'msg-b1');
        expect(ack.result, BleAckResult.stored);
        expect(pair.sessionA.isSecureReady, isTrue);
        expect(pair.sessionB.isSecureReady, isTrue);
      },
    );

    test('a message whose sender or receiver does not match the authenticated '
        'link is answered with an encrypted rejection only', () async {
      final pair = SecurePair();
      await pair.ready();

      // Wrong sender: the authenticated peer is device-b, not device-evil.
      _deliverSecure(
        pair.transportA,
        BleSecureTransferKind.secureMessage,
        pair.gateway.sealFor(
          pair.sessionBHandle,
          _messageBytes(
            messageId: 'msg-foreign',
            senderId: 'device-evil',
            receiverId: 'device-a',
            content: 'hello',
          ),
        ),
        transferId: 34,
      );
      // Wrong receiver: this side is device-a.
      _deliverSecure(
        pair.transportA,
        BleSecureTransferKind.secureMessage,
        pair.gateway.sealFor(
          pair.sessionBHandle,
          _messageBytes(
            messageId: 'msg-not-for-us',
            senderId: 'device-b',
            receiverId: 'device-x',
            content: 'hello',
          ),
        ),
        transferId: 35,
      );
      await pair.pump(100);

      expect(
        pair.receivedOnA,
        isEmpty,
        reason: 'the application callback never sees a mismatched message',
      );
      expect(
        pair.sessionA.isSecureReady,
        isTrue,
        reason: 'an application rejection is not a transport failure',
      );

      final acks = secureTransfersWritten(
        pair.transportA,
      ).where((t) => t.kind == BleSecureTransferKind.secureAck).toList();
      expect(acks, hasLength(2), reason: 'one encrypted rejection per message');
      final results = <String, BleAckResult>{};
      for (final transfer in acks) {
        final ack = BleAck.decode(
          pair.gateway.openFor(pair.sessionAHandle, transfer.payload),
        );
        expect(ack.result, BleAckResult.rejected);
        results[ack.messageId] = ack.result;
      }
      expect(results.keys, {'msg-foreign', 'msg-not-for-us'});
      expect(
        _containsAscii(_join(pair.transportA.writes), 'authenticated link'),
        isFalse,
        reason: 'the rejection reason never travels in plaintext',
      );
    });

    test('a stored message, a deduplicated message and a policy rejection keep '
        'their existing ACK semantics over the encrypted path', () async {
      final pair = SecurePair();
      await pair.ready();

      final seen = <String>{};
      pair.onMessageA = (payload) async {
        // Stand-in for BleMessageStore's unique-message-ID dedup, which stays
        // the source of truth for duplicate delivery.
        if (!seen.add(payload.metadata.messageId)) {
          return BleAckResult.duplicate;
        }
        return BleAckResult.stored;
      };

      final first = await pair.sessionB.sendMessage(_messageToA());
      expect(first, BleAckResult.stored);
      // Same message ID again: the deduplication answer must survive the
      // encrypted round trip unchanged.
      final duplicate = await pair.sessionB.sendMessage(_messageToA());
      expect(duplicate, BleAckResult.duplicate);
      expect(pair.receivedOnA, hasLength(2), reason: 'both deliveries ran');

      // A policy rejection from the application callback travels only as an
      // encrypted ACK result, and it must not tear the transport down.
      pair.onMessageA = (payload) async {
        throw const BleLinkException('The BLE link has no validated peer');
      };
      final rejected = _SendProbe(
        pair.sessionB.sendMessage(
          _messageToA(messageId: 'msg-policy', content: 'nope'),
        ),
      );
      await pair.pump(100);
      await rejected.done;
      expect(rejected.result, BleAckResult.rejected);
      expect(pair.sessionA.isSecureReady, isTrue);
      expect(pair.sessionB.isSecureReady, isTrue);

      final ackTransfer = secureTransfersWritten(
        pair.transportA,
      ).where((t) => t.kind == BleSecureTransferKind.secureAck).last;
      final ack = BleAck.decode(
        pair.gateway.openFor(pair.sessionAHandle, ackTransfer.payload),
      );
      expect(ack.messageId, 'msg-policy');
      expect(ack.result, BleAckResult.rejected);
      expect(ack.reason, contains('no validated peer'));
      expect(
        _containsAscii(_join(pair.transportA.writes), 'no validated peer'),
        isFalse,
        reason: 'the reason exists only inside the ciphertext',
      );
    });

    test('an approval-pending rejection still maps to the approval exception '
        'on the secure path', () async {
      final pair = SecurePair();
      await pair.ready();
      pair.onMessageA = (payload) async {
        throw const BleLinkException(BleProtocol.approvalPendingReason);
      };

      await expectLater(
        pair.sessionB.sendMessage(
          _messageToA(messageId: 'msg-approval', content: 'hi'),
        ),
        throwsA(isA<BleApprovalPendingException>()),
      );
      expect(
        pair.sessionA.isSecureReady,
        isTrue,
        reason: 'an approval hold is application state, not a crypto failure',
      );
      expect(v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
    });

    test('a malformed decrypted application payload fails the session without '
        'invoking the legacy handler or emitting an ACK', () async {
      final pair = SecurePair();
      await pair.ready();

      // Authenticated (correctly sealed) but not a valid application payload.
      _deliverSecure(
        pair.transportA,
        BleSecureTransferKind.secureMessage,
        pair.gateway.sealFor(
          pair.sessionBHandle,
          Uint8List.fromList(List.filled(24, 0x01)),
        ),
        transferId: 36,
      );
      await pair.pump(50);

      expect(pair.receivedOnA, isEmpty, reason: 'no callback, no legacy path');
      expect(pair.sessionA.state, BleSessionState.closed);
      expect(pair.sessionA.secureState, BleSecureLinkState.failed);
      expect(pair.closedErrorsA.single, isA<BleProtocolException>());
      expect(pair.gateway.countFor('device-a', 'decrypt'), 1);
      expect(
        pair.gateway.encryptHandles,
        isEmpty,
        reason: 'a malformed payload never produces an ACK',
      );
      expect(
        v1KindsWritten(pair.transportA),
        [BleTransferKind.hello],
        reason: 'no plaintext fallback decoding happens',
      );
    });

    test('interleaved inbound transfers are fully reassembled before their '
        'single decrypt and processed in order', () async {
      final pair = SecurePair();
      await pair.ready();

      final first = pair.gateway.sealFor(
        pair.sessionBHandle,
        _messageBytes(
          messageId: 'msg-i1',
          senderId: 'device-b',
          receiverId: 'device-a',
          content: 'first',
        ),
      );
      final second = pair.gateway.sealFor(
        pair.sessionBHandle,
        _messageBytes(
          messageId: 'msg-i2',
          senderId: 'device-b',
          receiverId: 'device-a',
          content: 'second',
        ),
      );
      final framesA = BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureMessage,
        payload: first,
        maxWriteLength: pair.transportA.maximumWriteLength,
        transferId: 37,
      );
      final framesB = BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureMessage,
        payload: second,
        maxWriteLength: pair.transportA.maximumWriteLength,
        transferId: 38,
      );
      final rounds = framesA.length > framesB.length
          ? framesA.length
          : framesB.length;
      for (var i = 0; i < rounds; i++) {
        if (i < framesA.length) pair.transportA.deliver(framesA[i]);
        if (i < framesB.length) pair.transportA.deliver(framesB[i]);
      }
      await pair.pump(200);

      expect(
        pair.receivedOnA.map((p) => p.metadata.messageId),
        ['msg-i1', 'msg-i2'],
        reason: 'one transfer is reassembled and decoded before the next',
      );
      expect(
        pair.gateway.countFor('device-a', 'decrypt'),
        2,
        reason: 'exactly one decrypt per reassembled transfer',
      );
      expect(pair.sessionA.isSecureReady, isTrue);
      // Both sides consumed their counters: A sealed two ACKs, B opened them.
      expect(pair.gateway.countFor('device-a', 'encrypt'), 2);
      expect(pair.gateway.countFor('device-b', 'decrypt'), 2);
      expect(pair.sessionB.isSecureReady, isTrue);
    });
  });

  group('secure ACK processing', () {
    test('an invalid ACK payload fails the session closed and completes '
        'nothing', () async {
      final pair = SecurePair();
      await pair.ready();
      pair.transportB.dropWrites = true;

      final probe = _SendProbe(pair.sessionA.sendMessage(testMessage()));
      await pair.pump(50);
      expect(probe.completed, isFalse);

      // Correctly sealed, but not an acknowledgement once opened.
      _deliverSecure(
        pair.transportA,
        BleSecureTransferKind.secureAck,
        pair.gateway.sealFor(
          pair.sessionBHandle,
          Uint8List.fromList(List.filled(48, 0x02)),
        ),
        transferId: 39,
      );
      await pair.pump(50);

      expect(probe.result, isNull);
      expect(probe.error, isA<BleLinkClosedException>());
      expect(pair.sessionA.state, BleSessionState.closed);
      expect(pair.sessionA.secureState, BleSecureLinkState.failed);
      expect(pair.closedErrorsA.single, isA<BleProtocolException>());
      expect(
        pair.gateway.countFor('device-a', 'encrypt'),
        1,
        reason: 'no second encryption on the failed session',
      );
    });

    test(
      'an ACK received around a close cannot complete a stale send',
      () async {
        final pair = SecurePair();
        await pair.ready();
        pair.transportB.dropWrites = true;

        // Crafted while both sessions are still alive, delivered around close.
        final lateAck = pair.gateway.sealFor(
          pair.sessionBHandle,
          _ackBytes('msg-1', BleAckResult.stored),
        );
        final probe = _SendProbe(pair.sessionA.sendMessage(testMessage()));
        await pair.pump(50);
        expect(probe.completed, isFalse);

        final decryptsBefore = pair.gateway.decryptHandles.length;
        _deliverSecure(
          pair.transportA,
          BleSecureTransferKind.secureAck,
          lateAck,
          transferId: 40,
        );
        await pair.sessionA.close();
        await pair.pump(50);

        expect(probe.result, isNull);
        expect(probe.error, isA<BleLinkClosedException>());
        expect(
          pair.gateway.decryptHandles,
          hasLength(decryptsBefore),
          reason: 'a closed session neither decrypts nor completes anything',
        );
        expect(pair.sessionA.isSecureReady, isFalse);
      },
    );

    test('an ACK delivered after the session failed on timeout changes '
        'nothing', () async {
      final pair = SecurePair(
        ackPolicy: const BleAckPolicy(
          baseTimeout: Duration(milliseconds: 60),
          perKilobyte: Duration.zero,
          perFrame: Duration.zero,
        ),
      );
      await pair.ready();
      pair.transportA.dropWrites = true;

      final staleAck = pair.gateway.sealFor(
        pair.sessionBHandle,
        _ackBytes('msg-1', BleAckResult.stored),
      );
      final probe = _SendProbe(pair.sessionA.sendMessage(testMessage()));
      await probe.done;
      expect(probe.error, isA<BleAckTimeoutException>());

      final decrypts = pair.gateway.decryptHandles.length;
      _deliverSecure(
        pair.transportA,
        BleSecureTransferKind.secureAck,
        staleAck,
        transferId: 41,
      );
      await pair.pump(50);

      expect(probe.result, isNull);
      expect(pair.sessionA.secureState, BleSecureLinkState.failed);
      expect(pair.gateway.decryptHandles, hasLength(decrypts));
      expect(pair.gateway.encryptHandles, [pair.sessionAHandle]);
    });
  });

  group('counters, failures and teardown', () {
    test('a native decrypt failure closes the session, never falls back to '
        'plaintext, and cannot be reused', () async {
      final pair = SecurePair();
      await pair.ready();
      pair.gateway.failDecrypt = true;

      _deliverSecure(
        pair.transportA,
        BleSecureTransferKind.secureMessage,
        pair.gateway.sealFor(
          pair.sessionBHandle,
          _messageBytes(
            messageId: 'msg-d1',
            senderId: 'device-b',
            receiverId: 'device-a',
            content: 'payload',
          ),
        ),
        transferId: 42,
      );
      await pair.pump(50);

      expect(pair.receivedOnA, isEmpty);
      expect(pair.sessionA.state, BleSessionState.closed);
      expect(pair.sessionA.secureState, BleSecureLinkState.failed);
      expect(
        pair.closedErrorsA.single,
        isA<SecureSessionNativeFailure>().having(
          (e) => e.message,
          'message',
          contains('simulated decrypt failure'),
        ),
      );
      expect(pair.gateway.closedHandles, contains(pair.sessionAHandle));
      expect(v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
      await expectLater(
        pair.sessionA.sendMessage(testMessage(messageId: 'msg-after')),
        throwsA(isA<BleLinkClosedException>()),
      );
      expect(pair.gateway.encryptHandles, isEmpty);
    });

    test('a secure write failure tears the session down after exactly one '
        'encryption', () async {
      final pair = SecurePair();
      await pair.ready();
      pair.transportA.failWrites = true;

      await expectLater(
        pair.sessionA.sendMessage(testMessage()),
        throwsA(
          isA<BleLinkException>().having(
            (e) => e.message,
            'message',
            contains('Simulated GATT write failure'),
          ),
        ),
      );

      expect(pair.sessionA.secureState, BleSecureLinkState.failed);
      expect(pair.sessionA.state, BleSessionState.closed);
      expect(pair.gateway.closedHandles, contains(pair.sessionAHandle));
      expect(
        pair.gateway.encryptHandles,
        [pair.sessionAHandle],
        reason:
            'the uncertain ciphertext is never re-encrypted on this '
            'session',
      );
      expect(
        v1KindsWritten(pair.transportA),
        [BleTransferKind.hello],
        reason: 'no plaintext fallback after the write failure',
      );
      expect(pair.receivedOnB, isEmpty);
    });

    test('an ACK timeout closes the session instead of retrying the same '
        'Noise session, so recovery is a fresh connection', () async {
      final pair = SecurePair(
        ackPolicy: const BleAckPolicy(
          baseTimeout: Duration(milliseconds: 80),
          perKilobyte: Duration.zero,
          perFrame: Duration.zero,
        ),
      );
      await pair.ready();
      // The ciphertext is written to the wire but never reaches B: the ACK is
      // lost, which is exactly the case where counters can no longer be
      // proven synchronized.
      pair.transportA.dropWrites = true;

      await expectLater(
        pair.sessionA.sendMessage(testMessage()),
        throwsA(isA<BleAckTimeoutException>()),
      );

      expect(pair.sessionA.secureState, BleSecureLinkState.failed);
      expect(pair.sessionA.isReady, isFalse);
      expect(pair.sessionA.state, BleSessionState.closed);
      expect(pair.gateway.closedHandles, contains(pair.sessionAHandle));
      expect(pair.closedErrorsA.single, isA<BleAckTimeoutException>());
      expect(
        pair.gateway.encryptHandles,
        [pair.sessionAHandle],
        reason: 'exactly one encryption: no second attempt after the timeout',
      );
      expect(pair.receivedOnB, isEmpty);
      expect(v1KindsWritten(pair.transportA), [BleTransferKind.hello]);

      // Higher layers recover through a new link plus a fresh handshake; the
      // failed session itself is never reused and never downgraded.
      await expectLater(
        pair.sessionA.sendMessage(testMessage(messageId: 'msg-retry')),
        throwsA(isA<BleLinkClosedException>()),
      );
      expect(pair.gateway.encryptHandles, hasLength(1));
      expect(v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
    });

    test('an inbound transport payload below the authentication tag is '
        'rejected before any native decrypt', () async {
      final pair = SecurePair();
      await pair.ready();

      // Hand-crafted: the fragmenting writer itself refuses payloads this
      // small, so only a hostile or broken peer could produce this.
      final payload = Uint8List(8);
      for (final frame in <Uint8List>[
        BleSecureFrame(
          type: BleFrameType.start,
          transferId: 43,
          sequence: 0,
          payload: BleSecureStartPayload(
            kind: BleSecureTransferKind.secureMessage,
            totalLength: payload.length,
            checksum: BleSecureTransferCodec.checksum(payload),
          ).encode(),
        ).encode(),
        BleSecureFrame(
          type: BleFrameType.data,
          transferId: 43,
          sequence: 1,
          payload: payload,
        ).encode(),
        BleSecureFrame(
          type: BleFrameType.end,
          transferId: 43,
          sequence: 2,
          payload: emptyBytes,
        ).encode(),
      ]) {
        pair.transportA.deliver(frame);
      }
      await pair.pump(50);

      expect(pair.sessionA.secureState, BleSecureLinkState.failed);
      expect(
        pair.gateway.decryptHandles,
        isEmpty,
        reason: 'the native engine never sees an undersized payload',
      );
      expect(pair.receivedOnA, isEmpty);
      expect(
        pair.closedErrorsA.single,
        isA<BleProtocolException>().having(
          (e) => e.message,
          'message',
          contains('authentication tag'),
        ),
      );
    });
  });

  group('size boundaries', () {
    test('the largest supported payload is encrypted end to end and one byte '
        'more is rejected before any encryption', () async {
      final pair = SecurePair();
      await pair.ready();

      final largest = String.fromCharCodes(
        List.filled(BleProtocol.maxMessageContentBytes, 0x61),
      );
      final probe = _SendProbe(
        pair.sessionA.sendMessage(
          testMessage(messageId: 'msg-max', content: largest),
        ),
      );
      await pair.pump(600);
      await probe.done;

      expect(probe.result, BleAckResult.stored);
      expect(pair.receivedOnB.single.metadata.contentLength, largest.length);
      expect(pair.receivedOnB.single.content, largest);

      final encryptsBefore = pair.gateway.encryptHandles.length;
      await expectLater(
        pair.sessionA.sendMessage(
          testMessage(messageId: 'msg-over', content: '$largest!'),
        ),
        throwsA(
          isA<BleLinkException>().having(
            (e) => e.message,
            'message',
            contains('too large'),
          ),
        ),
      );
      expect(
        pair.gateway.encryptHandles,
        hasLength(encryptsBefore),
        reason: 'the oversized payload never reached the engine',
      );
      expect(v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
    });
  });

  group('regression and compatibility', () {
    test('the encrypted payload is byte-identical to the legacy inner '
        'encoding: one application schema, not two', () async {
      // Legacy side: capture the plaintext payload a v1 session writes.
      final legacyA = FakeTransport(64);
      final legacyB = FakeTransport(64);
      legacyA.peer = legacyB;
      legacyB.peer = legacyA;
      final sessionA = BleLinkSession(
        transport: legacyA,
        identity: testIdentity('device-a', 'Alice'),
        onHello: (hello) async {},
        onMessage: (payload) async => BleAckResult.stored,
        transferIdFactory: () => 1,
      );
      final sessionB = BleLinkSession(
        transport: legacyB,
        identity: testIdentity('device-b', 'Bob'),
        onHello: (hello) async {},
        onMessage: (payload) async => BleAckResult.stored,
        transferIdFactory: () => 2,
      );
      await Future.wait([sessionA.start(), sessionB.start()]);
      expect(await sessionA.sendMessage(testMessage()), BleAckResult.stored);

      final assembler = BleTransferAssembler();
      Uint8List? legacyPayload;
      for (final frame in legacyA.writes) {
        final transfer = assembler.add(BleFrame.decode(frame));
        if (transfer != null && transfer.kind == BleTransferKind.message) {
          legacyPayload = transfer.payload;
        }
      }
      expect(legacyPayload, isNotNull);

      // Secure side: open the ciphertext and compare the inner bytes.
      final pair = SecurePair();
      await pair.ready();
      final probe = _SendProbe(pair.sessionA.sendMessage(testMessage()));
      await pair.pump(200);
      await probe.done;
      expect(probe.result, BleAckResult.stored);

      final sealed = _transferOfKind(
        secureTransfersWritten(pair.transportA),
        BleSecureTransferKind.secureMessage,
      ).payload;
      final inner = pair.gateway.openFor(pair.sessionAHandle, sealed);
      expect(inner, orderedEquals(legacyPayload!));

      await sessionA.close();
      await sessionB.close();
    });

    test('legacy v1 sessions keep their own semantics: ACK timeout leaves the '
        'link usable and no secure state ever exists', () async {
      final legacyA = FakeTransport(64);
      final legacyB = FakeTransport(64);
      legacyA.peer = legacyB;
      legacyB.peer = legacyA;
      final sessionA = BleLinkSession(
        transport: legacyA,
        identity: testIdentity('device-a', 'Alice'),
        onHello: (hello) async {},
        onMessage: (payload) async => BleAckResult.stored,
        ackPolicy: const BleAckPolicy(
          baseTimeout: Duration(milliseconds: 30),
          perKilobyte: Duration.zero,
          perFrame: Duration.zero,
        ),
        transferIdFactory: () => 1,
      );
      final sessionB = BleLinkSession(
        transport: legacyB,
        identity: testIdentity('device-b', 'Bob'),
        onHello: (hello) async {},
        onMessage: (payload) async => BleAckResult.stored,
        transferIdFactory: () => 2,
      );
      await Future.wait([sessionA.start(), sessionB.start()]);
      legacyB.dropWrites = true; // the legacy ACK is lost

      await expectLater(
        sessionA.sendMessage(testMessage()),
        throwsA(isA<BleAckTimeoutException>()),
      );
      expect(sessionA.isReady, isTrue, reason: 'legacy timeout stays usable');
      expect(sessionA.secureState, isNull);
      expect(sessionA.isSecureReady, isFalse);

      legacyB.dropWrites = false;
      expect(
        await sessionA.sendMessage(testMessage(messageId: 'msg-2')),
        BleAckResult.stored,
      );

      await sessionA.close();
      await sessionB.close();
    });
  });
}

// ---------------------------------------------------------------- helpers

/// Observes one send without ever letting its error go unhandled, so tests can
/// assert "still pending" as well as the eventual result or failure.
class _SendProbe {
  _SendProbe(Future<BleAckResult> future) {
    done = future.then<void>(
      (value) {
        result = value;
      },
      onError: (Object error) {
        this.error = error;
      },
    );
  }

  late final Future<void> done;
  BleAckResult? result;
  Object? error;

  bool get completed => result != null || error != null;
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

Uint8List _messageBytes({
  required String messageId,
  required String senderId,
  required String receiverId,
  required String content,
}) {
  return BleMessagePayload(
    metadata: BleMessageMetadata(
      messageId: messageId,
      senderId: senderId,
      receiverId: receiverId,
      messageType: MessageType.text.name,
      timestamp: DateTime.utc(2026, 5, 6),
      ttl: 60,
      contentLength: utf8.encode(content).length,
      isEncrypted: false,
    ),
    content: content,
  ).encode();
}

Uint8List _ackBytes(String messageId, BleAckResult result) =>
    BleAck(messageId: messageId, result: result).encode();

/// A message sent from B to A: the inverse direction of [testMessage]'s
/// defaults, matching each side's authenticated peer.
Message _messageToA({
  String messageId = 'msg-from-b',
  String content = 'Hello from A',
}) => testMessage(
  messageId: messageId,
  senderId: 'device-b',
  receiverId: 'device-a',
  content: content,
);

Uint8List _join(Iterable<Uint8List> parts) {
  final builder = BytesBuilder();
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

bool _containsAscii(List<int> haystack, String needle) {
  final needleBytes = utf8.encode(needle);
  if (needleBytes.isEmpty) return true;
  if (needleBytes.length > haystack.length) return false;
  for (var i = 0; i <= haystack.length - needleBytes.length; i++) {
    var matched = true;
    for (var j = 0; j < needleBytes.length; j++) {
      if (haystack[i + j] != needleBytes[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
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
