import 'dart:async';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_secure_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/services/crypto/native_secure_session_service.dart';
import 'package:flutter_test/flutter_test.dart';

// The fake gateway in this file simulates the *call contract* of the native
// Noise engine (message ordering, finishing steps, pin enforcement points).
// It proves the Dart link-session state machine coordinates, authorizes and
// fails closed correctly. It is NOT evidence that the real cryptography is
// sound; that evidence lives in the Rust engine tests and the native
// instrumentation tests.

void main() {
  group('legacy v1 sessions are untouched by the secure state machine', () {
    test(
      'a session built exactly like the runtime stays entirely legacy',
      () async {
        // Mirrors BleRuntimeController._createSession: no secure config.
        final pair = _LegacyPair();
        await pair.start();

        expect(pair.sessionA.secureState, isNull);
        expect(pair.sessionB.secureState, isNull);
        expect(pair.sessionA.isSecureReady, isFalse);
        expect(pair.sessionB.isSecureReady, isFalse);
        expect(pair.sessionA.isReady, isTrue);

        final result = await pair.sessionA.sendMessage(_message());
        expect(result, BleAckResult.stored);
        expect(pair.receivedOnB, hasLength(1));
      },
    );

    test('secure mode is opt-in: no native session exists before '
        'startSecureHandshake', () async {
      final pair = _SecurePair();
      await pair.start();

      expect(
        pair.sessionA.secureState,
        BleSecureLinkState.awaitingAuthorization,
      );
      expect(
        pair.sessionB.secureState,
        BleSecureLinkState.awaitingAuthorization,
      );
      expect(pair.sessionA.isReady, isFalse);
      expect(pair.sessionA.isSecureReady, isFalse);
      expect(
        pair.gateway.calls,
        isEmpty,
        reason: 'nothing native may happen before explicit authorization',
      );
    });
  });

  group('handshake sequence and role mapping', () {
    test('peripheral/initiator and central/responder complete Noise XX in '
        'order and reach secure-ready only after confirmation', () async {
      final pair = _SecurePair();
      await pair.start();

      await pair.authorize();
      await pair.pump();

      // Both sides finished the 3-message flow and await confirmation.
      expect(
        pair.sessionA.secureState,
        BleSecureLinkState.awaitingConfirmation,
      );
      expect(
        pair.sessionB.secureState,
        BleSecureLinkState.awaitingConfirmation,
      );
      expect(pair.sessionA.isSecureReady, isFalse);
      expect(
        pair.sessionA.isReady,
        isFalse,
        reason: 'a finished handshake alone is not readiness',
      );

      await pair.confirmBoth();

      expect(pair.sessionA.secureState, BleSecureLinkState.secureReady);
      expect(pair.sessionB.secureState, BleSecureLinkState.secureReady);
      expect(pair.sessionA.isSecureReady, isTrue);
      expect(pair.sessionA.isReady, isTrue);
      expect(pair.sessionB.isReady, isTrue);
    });

    test('the initiator drives createSession/startHandshake then processes '
        'one message; the responder only processes inbound messages', () async {
      final pair = _SecurePair();
      await pair.start();
      await pair.authorize();
      await pair.pump();
      await pair.confirmBoth();

      expect(pair.gateway.callsFor('device-a'), [
        'createSession(device-a, initiator=true)',
        'startHandshake(device-a)',
        'processHandshake(device-a)',
        'confirmPeerIdentity(device-a)',
      ]);
      expect(pair.gateway.callsFor('device-b'), [
        'createSession(device-b, initiator=false)',
        'processHandshake(device-b)',
        'processHandshake(device-b)',
        'confirmPeerIdentity(device-b)',
      ]);
    });

    test('every handshake byte travels as protocol-v2 frames; the only v1 '
        'transfer ever written is the pre-secure HELLO', () async {
      final pair = _SecurePair();
      await pair.ready();

      // v1 traffic: exactly one HELLO transfer per side, nothing else.
      expect(_v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
      expect(_v1KindsWritten(pair.transportB), [BleTransferKind.hello]);

      // The initiator wrote protocol-v2 handshake frames after the HELLO.
      final secureFrames = pair.transportA.writes
          .where((f) => f.length >= 2 && f[1] == BleSecureProtocol.version)
          .toList();
      expect(secureFrames, isNotEmpty);
    });

    test(
      'authorization is required twice over: no readiness at HELLO, none '
      'at handshake end, secure-ready only after explicit confirmation',
      () async {
        final pair = _SecurePair();
        await pair.start();
        // HELLO exchanged, but awaiting authorization:
        expect(pair.sessionA.isReady, isFalse);

        await pair.authorize();
        await pair.pump();
        // Handshake finished, but awaiting confirmation:
        expect(pair.sessionA.isReady, isFalse);
        expect(pair.sessionA.isSecureReady, isFalse);

        await pair.confirmBoth();
        expect(pair.sessionA.isSecureReady, isTrue);
      },
    );
  });

  group('authorization and approval boundaries', () {
    test('a rejected HELLO keeps the link out of secure mode entirely and '
        'creates no native session', () async {
      final pair = _SecurePair(rejectHelloOnB: true);

      await expectLater(pair.start(), throwsA(anything));
      expect(pair.sessionA.isSecureReady, isFalse);
      expect(
        pair.gateway.calls,
        isEmpty,
        reason: 'connection approval precedes every secure operation',
      );
    });

    test('startSecureHandshake cannot run before HELLO or twice', () async {
      final pair = _SecurePair();
      await pair.start();

      await pair.sessionA.startSecureHandshake();
      await expectLater(
        pair.sessionA.startSecureHandshake(),
        throwsA(
          isA<BleLinkException>().having(
            (e) => e.message,
            'message',
            contains('cannot start in the current state'),
          ),
        ),
      );
    });

    test(
      'confirmSecurePeerIdentity is rejected before the handshake finishes',
      () async {
        final pair = _SecurePair();
        await pair.start();
        await pair.sessionB.startSecureHandshake();
        // B is handshaking (no messages exchanged yet).
        await expectLater(
          pair.sessionB.confirmSecurePeerIdentity(),
          throwsA(
            isA<BleLinkException>().having(
              (e) => e.message,
              'message',
              contains('awaiting confirmation'),
            ),
          ),
        );
      },
    );

    test('secure APIs fail closed on a legacy session', () async {
      final pair = _LegacyPair();
      await pair.start();

      await expectLater(
        pair.sessionA.startSecureHandshake(),
        throwsA(
          isA<BleLinkException>().having(
            (e) => e.message,
            'message',
            contains('Secure mode is not enabled'),
          ),
        ),
      );
      await expectLater(
        pair.sessionA.confirmSecurePeerIdentity(),
        throwsA(isA<BleLinkException>()),
      );
    });
  });

  group('remote identity and pinned-key behaviour', () {
    test('the authenticated identity is surfaced and never overwritten by '
        'the plaintext HELLO', () async {
      RemoteAuthenticatedIdentity? surfaced;
      final pair = _SecurePair(onIdentityA: (identity) => surfaced = identity);
      await pair.start();
      expect(
        pair.sessionA.linkInfo?.deviceId,
        'device-b',
        reason: 'the HELLO hint stays as exchanged',
      );

      await pair.authorize();
      await pair.pump();

      final remote = pair.sessionA.secureRemoteIdentity;
      expect(remote, isNotNull);
      expect(remote!.deviceId, 'device-b');
      expect(remote.displayName, 'Bob');
      expect(remote.publicKeyHex, _hex(_deviceB.staticKey));
      expect(
        surfaced,
        same(remote),
        reason: 'the callback surfaces the same authenticated identity',
      );
      // The HELLO was advisory only; it never clobbered authenticated fields.
      expect(pair.sessionA.linkInfo?.deviceId, 'device-b');
    });

    test('an authenticated device ID that mismatches the expected peer fails '
        'closed and persists nothing', () async {
      final pair = _SecurePair(expectedPeerDeviceIdA: 'device-x');
      await pair.start();
      await pair.authorize();
      await pair.pump();

      expect(pair.sessionA.secureState, BleSecureLinkState.failed);
      expect(pair.sessionA.isSecureReady, isFalse);
      expect(pair.sessionA.state, BleSessionState.closed);
      expect(
        pair.closedErrorsA.single,
        isA<BleLinkException>().having(
          (e) => e.message,
          'message',
          contains('does not match the expected peer'),
        ),
      );
      // The native session was torn down; no plaintext fallback was written.
      expect(pair.gateway.closedHandles, contains(pair.sessionAHandle));
      expect(_v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
    });

    test('a wrong pinned key fails closed; the pin is forwarded to the '
        'engine and never overwritten', () async {
      final wrongPin = Uint8List.fromList(List.filled(32, 0x09));
      final pair = _SecurePair(pinA: wrongPin);
      await pair.start();
      await pair.authorize();
      await pair.pump();

      // The fake engine enforced the pin exactly where the real one does:
      // at handshake completion.
      expect(pair.sessionA.secureState, BleSecureLinkState.failed);
      expect(pair.sessionA.isSecureReady, isFalse);
      expect(pair.gateway.closedHandles, contains(pair.sessionAHandle));
      expect(pair.gateway.pinForwardedA, wrongPin);
      expect(
        _v1KindsWritten(pair.transportA),
        [BleTransferKind.hello],
        reason: 'no plaintext application traffic after the failure',
      );
    });

    test('the correct pinned key lets the handshake finish', () async {
      final pair = _SecurePair(pinA: _deviceB.staticKey);
      await pair.start();
      await pair.authorize();
      await pair.pump();

      expect(
        pair.sessionA.secureState,
        BleSecureLinkState.awaitingConfirmation,
      );
      expect(pair.sessionA.isSecureReady, isFalse);
    });

    test('HELLO binding mismatch fails closed when binding is required, and '
        'passes when the identities agree', () async {
      // Mismatch: the authenticated identity says device-evil while the
      // plaintext HELLO said device-b.
      final mismatch = _SecurePair(
        requireHelloBindingA: true,
        remoteIdentityForA: const RemoteAuthenticatedIdentity(
          publicKeyHex: 'aa',
          deviceId: 'device-evil',
          displayName: 'Eve',
          protocolVersion: 1,
          capabilities: 1,
        ),
      );
      await mismatch.start();
      await mismatch.authorize();
      await mismatch.pump();

      expect(mismatch.sessionA.secureState, BleSecureLinkState.failed);
      expect(
        mismatch.closedErrorsA.single,
        isA<BleLinkException>().having(
          (e) => e.message,
          'message',
          contains('does not match the exchanged HELLO'),
        ),
      );

      // Control: binding required but identities agree -> completes.
      final match = _SecurePair(requireHelloBindingA: true);
      await match.start();
      await match.authorize();
      await match.pump();
      expect(
        match.sessionA.secureState,
        BleSecureLinkState.awaitingConfirmation,
      );
    });
  });

  group('invalid input and unexpected traffic fail closed', () {
    test('a handshake message in the wrong state is rejected', () async {
      final pair = _SecurePair();
      await pair.start();
      // B is only awaiting authorization; deliver a v2 handshake transfer.
      for (final frame in BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureHandshake,
        payload: _msg1,
        maxWriteLength: pair.transportB.maximumWriteLength,
        transferId: 42,
      )) {
        pair.transportB.deliver(frame);
      }
      await pair.pump();

      expect(pair.sessionB.secureState, BleSecureLinkState.failed);
      expect(
        pair.closedErrorsB.single,
        isA<BleLinkException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected secure handshake message'),
        ),
      );
      expect(pair.gateway.calls, isEmpty);
    });

    test('a truncated secure frame fails the link', () async {
      final pair = _SecurePair();
      await pair.start();
      await pair.authorize();
      await pair.pump();

      pair.transportB.deliver(Uint8List.fromList([BleSecureProtocol.magic, 2]));
      await pair.pump();

      expect(pair.sessionB.secureState, BleSecureLinkState.failed);
      expect(pair.sessionB.isSecureReady, isFalse);
    });

    test('an unsupported protocol version fails the link', () async {
      final pair = _SecurePair();
      await pair.start();
      await pair.authorize();
      await pair.pump();

      // magic, version 3, then garbage: neither decoder accepts it.
      pair.transportB.deliver(Uint8List.fromList([0x42, 3, 0, 0]));
      await pair.pump();

      expect(pair.sessionB.state, BleSessionState.closed);
      expect(pair.sessionB.isSecureReady, isFalse);
    });

    test('an invalid fragment sequence fails the link', () async {
      final pair = _SecurePair();
      await pair.start();
      await pair.authorize();
      await pair.pump();

      pair.transportB.deliver(
        BleSecureFrame(
          type: BleFrameType.start,
          transferId: 9,
          sequence: 0,
          payload: BleSecureStartPayload(
            kind: BleSecureTransferKind.secureHandshake,
            totalLength: _msg1.length,
            checksum: BleSecureTransferCodec.checksum(_msg1),
          ).encode(),
        ).encode(),
      );
      pair.transportB.deliver(
        BleSecureFrame(
          type: BleFrameType.data,
          transferId: 9,
          sequence: 5, // must be 1
          payload: _msg1,
        ).encode(),
      );
      await pair.pump();

      expect(pair.sessionB.secureState, BleSecureLinkState.failed);
    });

    test('an oversized handshake transfer is rejected on receive', () async {
      final pair = _SecurePair();
      await pair.start();
      await pair.authorize();
      await pair.pump();
      int handshakeCalls(String device) => pair.gateway
          .callsFor(device)
          .where((c) => c.startsWith('processHandshake'))
          .length;
      final handshakeCallsBefore = handshakeCalls('device-b');

      for (final frame in _craftOversizedHandshake(
        BleSecureProtocol.maxHandshakeBytes + 76,
      )) {
        pair.transportB.deliver(frame);
      }
      await pair.pump();

      expect(pair.sessionB.secureState, BleSecureLinkState.failed);
      expect(
        pair.closedErrorsB.single,
        isA<BleProtocolException>().having(
          (e) => e.message,
          'message',
          contains('too large'),
        ),
      );
      expect(
        handshakeCalls('device-b'),
        handshakeCallsBefore,
        reason: 'the oversized payload never reached the native engine',
      );
    });

    test('a plaintext v1 message frame on a secure link is rejected and never '
        'reaches onMessage', () async {
      final pair = _SecurePair();
      await pair.ready();

      final payload = BleMessagePayload(
        metadata: BleMessageMetadata(
          messageId: 'msg-injected',
          senderId: 'device-b',
          receiverId: 'device-a',
          messageType: MessageType.text.name,
          timestamp: DateTime.utc(2026, 5, 6),
          ttl: 60,
          contentLength: 4,
          isEncrypted: false,
        ),
        content: 'evil',
      ).encode();
      for (final frame in BleTransferCodec.fragment(
        kind: BleTransferKind.message,
        payload: payload,
        maxWriteLength: pair.transportA.maximumWriteLength,
        transferId: 7,
      )) {
        pair.transportA.deliver(frame);
      }
      await pair.pump();

      expect(pair.sessionA.isSecureReady, isFalse);
      expect(pair.sessionA.state, BleSessionState.closed);
      expect(pair.receivedOnA, isEmpty);
      expect(
        pair.closedErrorsA.single,
        isA<BleLinkException>().having(
          (e) => e.message,
          'message',
          contains('Plaintext application traffic'),
        ),
      );
    });

    test(
      'a plaintext v1 acknowledgement on a secure link is rejected',
      () async {
        final pair = _SecurePair();
        await pair.ready();

        final ack = BleAck(
          messageId: 'msg-injected',
          result: BleAckResult.stored,
        ).encode();
        for (final frame in BleTransferCodec.fragment(
          kind: BleTransferKind.acknowledgement,
          payload: ack,
          maxWriteLength: pair.transportA.maximumWriteLength,
          transferId: 8,
        )) {
          pair.transportA.deliver(frame);
        }
        await pair.pump();

        expect(pair.sessionA.state, BleSessionState.closed);
        expect(
          pair.closedErrorsA.single,
          isA<BleLinkException>().having(
            (e) => e.message,
            'message',
            contains('Plaintext application traffic'),
          ),
        );
      },
    );

    test('a v2 secureMessage frame is rejected until the secure messaging '
        'path exists', () async {
      final pair = _SecurePair();
      await pair.ready();

      for (final frame in BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureMessage,
        payload: Uint8List.fromList(List.filled(32, 0x77)),
        maxWriteLength: pair.transportA.maximumWriteLength,
        transferId: 11,
      )) {
        pair.transportA.deliver(frame);
      }
      await pair.pump();

      expect(pair.sessionA.state, BleSessionState.closed);
      expect(pair.receivedOnA, isEmpty);
      expect(
        pair.closedErrorsA.single,
        isA<BleLinkException>().having(
          (e) => e.message,
          'message',
          contains('not yet integrated'),
        ),
      );
    });
  });

  group('application message boundary', () {
    test('sendMessage fails closed in every secure state and never emits a '
        'plaintext message frame', () async {
      final pair = _SecurePair();
      await pair.start();
      await expectLater(
        pair.sessionA.sendMessage(_message()),
        throwsA(isA<BleLinkException>()),
      );

      await pair.authorize();
      await pair.pump();
      await expectLater(
        pair.sessionA.sendMessage(_message()),
        throwsA(isA<BleLinkException>()),
      );

      await pair.confirmBoth();
      await expectLater(
        pair.sessionA.sendMessage(_message()),
        throwsA(
          isA<BleLinkException>().having(
            (e) => e.message,
            'message',
            contains('not yet integrated'),
          ),
        ),
      );

      expect(_v1KindsWritten(pair.transportA), [BleTransferKind.hello]);
      expect(
        pair.gateway.applicationCryptoCalls,
        isEmpty,
        reason: 'no encrypt/decrypt may happen before the messaging phase',
      );
    });
  });

  group('timeouts, disconnects and teardown', () {
    test('a handshake timeout fails the link closed and closes the native '
        'session', () async {
      final pair = _SecurePair(
        handshakeTimeout: const Duration(milliseconds: 60),
      );
      await pair.start();
      // Only B authorizes: it waits for message 1 that never arrives.
      await pair.sessionB.startSecureHandshake();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await pair.pump();

      expect(pair.sessionB.secureState, BleSecureLinkState.failed);
      expect(pair.sessionB.isSecureReady, isFalse);
      expect(pair.sessionB.state, BleSessionState.closed);
      expect(
        pair.closedErrorsB.single,
        isA<BleSecureHandshakeTimeoutException>(),
      );
      expect(pair.gateway.closedHandles, contains(pair.sessionBHandle));
    });

    test(
      'a disconnect during the handshake closes the native session',
      () async {
        final pair = _SecurePair();
        await pair.start();
        await pair.authorize();
        await pair.pump(2);

        // Simulate the transport dropping underneath A.
        await pair.transportA.close();
        await pair.pump();

        expect(pair.sessionA.state, BleSessionState.closed);
        expect(pair.sessionA.isSecureReady, isFalse);
        expect(pair.gateway.closedHandles, contains(pair.sessionAHandle));
      },
    );

    test('a late handshake result for a closed session is ignored', () async {
      final pair = _SecurePair();
      await pair.start();
      pair.gateway.parkProcessHandshakeFor = 'device-b';
      await pair.sessionB.startSecureHandshake();

      // Deliver message 1 to B; its native call parks in flight.
      for (final frame in BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureHandshake,
        payload: _msg1,
        maxWriteLength: pair.transportB.maximumWriteLength,
        transferId: 21,
      )) {
        pair.transportB.deliver(frame);
      }
      await pair.pump();
      expect(
        pair.gateway.callsFor('device-b'),
        contains('processHandshake(device-b)'),
      );

      // Close the link while the native call is still in flight.
      await pair.sessionB.close();
      expect(pair.sessionB.secureState, BleSecureLinkState.closed);

      // The stale call now resolves with a finished step.
      pair.gateway.releaseParked!(
        HandshakeStepResult(
          outgoing: _empty,
          finished: true,
          confirmationRequired: true,
          remoteIdentity: _remoteA,
        ),
      );
      await pair.pump();

      // The stale result changed nothing.
      expect(pair.sessionB.secureState, BleSecureLinkState.closed);
      expect(pair.sessionB.isSecureReady, isFalse);
      expect(pair.identitySeenOnB, isNull);
      expect(
        pair.gateway.callsFor('device-b'),
        isNot(contains('confirmPeerIdentity(device-b)')),
      );
    });

    test('close is idempotent: one native close, one onClosed', () async {
      final pair = _SecurePair();
      await pair.ready();

      await pair.sessionA.close();
      await pair.sessionA.close();

      expect(
        pair.gateway.closedHandles.where(
          (h) => identical(h, pair.sessionAHandle),
        ),
        hasLength(1),
      );
      expect(pair.closedErrorsA, hasLength(1));
    });

    test(
      'a gateway failure during authorization fails the link closed',
      () async {
        final pair = _SecurePair();
        await pair.start();
        pair.gateway.failCreateSession = const SecureSessionNativeFailure(
          'the secure session service is unavailable',
        );

        await expectLater(
          pair.sessionA.startSecureHandshake(),
          throwsA(isA<SecureSessionNativeFailure>()),
        );
        expect(pair.sessionA.secureState, BleSecureLinkState.failed);
        expect(pair.sessionA.state, BleSessionState.closed);
        expect(pair.sessionA.isSecureReady, isFalse);
      },
    );
  });

  group('no persistence or verification side effects', () {
    test('the link session performs only gateway coordination: no extra '
        'native operations, no crypto, no verification labelling', () async {
      final pair = _SecurePair();
      await pair.ready();
      await pair.sessionA.close();
      await pair.sessionB.close();

      // The complete native call vocabulary is the handshake contract and
      // teardown; there is no persistence, verification or messaging call.
      final verbs = pair.gateway.calls.map((c) => c.split('(').first).toSet();
      expect(verbs, {
        'createSession',
        'startHandshake',
        'processHandshake',
        'confirmPeerIdentity',
        'closeSession',
      });
      expect(pair.gateway.applicationCryptoCalls, isEmpty);
      // The surfaced identity is plain data; no verification label exists
      // on it and no DB is reachable from the link session at all.
      expect(pair.sessionA.secureRemoteIdentity!.deviceId, 'device-b');
    });
  });
}

// ---------------------------------------------------------------- fixtures

final Uint8List _empty = Uint8List(0);
final Uint8List _msg1 = Uint8List.fromList([0x11, 0x11, 0x11]);
final Uint8List _msg2 = Uint8List.fromList([0x22, 0x22]);
final Uint8List _msg3 = Uint8List.fromList([0x33, 0x33, 0x33, 0x33]);

const RemoteAuthenticatedIdentity _remoteA = RemoteAuthenticatedIdentity(
  publicKeyHex: 'aa',
  deviceId: 'device-a',
  displayName: 'Alice',
  protocolVersion: 1,
  capabilities: 1,
);

class _FakeDevice {
  const _FakeDevice(this.deviceId, this.displayName, this.staticKey);

  final String deviceId;
  final String displayName;
  final Uint8List staticKey;

  RemoteAuthenticatedIdentity get identity => RemoteAuthenticatedIdentity(
    publicKeyHex: _hex(staticKey),
    deviceId: deviceId,
    displayName: displayName,
    protocolVersion: 1,
    capabilities: 1,
  );
}

final _deviceA = _FakeDevice(
  'device-a',
  'Alice',
  Uint8List.fromList(List.filled(32, 0xaa)),
);

final _deviceB = _FakeDevice(
  'device-b',
  'Bob',
  Uint8List.fromList(List.filled(32, 0xbb)),
);

String _hex(Uint8List bytes) {
  const digits = '0123456789abcdef';
  final out = StringBuffer();
  for (final byte in bytes) {
    out.write(digits[byte >> 4]);
    out.write(digits[byte & 0x0f]);
  }
  return out.toString();
}

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
}

/// Simulates the native Noise engine's *call contract*: XX message ordering,
/// finishing steps that carry the authenticated identity, pin enforcement at
/// completion, and explicit confirmation. It performs no cryptography.
class _FakeSecureGateway implements SecureSessionGateway {
  _FakeSecureGateway({
    required List<_FakeDevice> devices,
    this.remoteIdentityOverride,
  }) : _devices = {for (final d in devices) d.deviceId: d};

  final Map<String, _FakeDevice> _devices;

  /// Local deviceId -> identity to present as that session's remote peer.
  /// Used to script authenticated-identity mismatches.
  final RemoteAuthenticatedIdentity? Function(String localDeviceId)?
  remoteIdentityOverride;

  final List<String> calls = [];
  final List<SecureSessionHandle> createdHandles = [];
  final List<SecureSessionHandle> closedHandles = [];
  final List<Uint8List> applicationCryptoCalls = [];

  Uint8List? pinForwardedA;

  SecureSessionException? failCreateSession;
  String? parkProcessHandshakeFor;
  Completer<HandshakeStepResult>? _parked;
  void Function(HandshakeStepResult step)? releaseParked;

  final Map<SecureSessionHandle, _FakeSession> _sessions = {};
  int _nextHandleValue = 100;

  List<String> callsFor(String deviceId) => calls
      .where((c) => c.contains('($deviceId,') || c.contains('($deviceId)'))
      .toList();

  _FakeDevice _remoteOf(String localDeviceId) =>
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
      outgoing: _msg1,
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
      releaseParked = (step) => _parked!.complete(step);
      return _parked!.future;
    }
    if (s.initiator) {
      if (s.step != 1 || !_bytesEqual(incoming, _msg2)) {
        throw const SecureSessionNativeFailure('unexpected handshake message');
      }
      s.step = 2;
      _finish(s);
      return HandshakeStepResult(
        outgoing: _msg3,
        finished: true,
        confirmationRequired: true,
        remoteIdentity: _identityFor(s),
      );
    }
    if (s.step == 0 && _bytesEqual(incoming, _msg1)) {
      s.step = 1;
      return HandshakeStepResult(
        outgoing: _msg2,
        finished: false,
        confirmationRequired: false,
      );
    }
    if (s.step == 1 && _bytesEqual(incoming, _msg3)) {
      s.step = 2;
      _finish(s);
      return HandshakeStepResult(
        outgoing: _empty,
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
    _require(session);
    throw UnimplementedError('the link session never queries status');
  }

  @override
  Future<void> confirmPeerIdentity(SecureSessionHandle session) async {
    final s = _require(session);
    calls.add('confirmPeerIdentity(${s.localDeviceId})');
    if (!s.finished) {
      throw const SecureSessionNativeFailure('handshake not finished');
    }
  }

  @override
  Future<Uint8List> encrypt(SecureSessionHandle session, Uint8List plaintext) {
    _require(session);
    applicationCryptoCalls.add(plaintext);
    throw UnimplementedError('secure messaging is not integrated yet');
  }

  @override
  Future<Uint8List> decrypt(SecureSessionHandle session, Uint8List ciphertext) {
    _require(session);
    applicationCryptoCalls.add(ciphertext);
    throw UnimplementedError('secure messaging is not integrated yet');
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
  void _finish(_FakeSession s) {
    final remote = _remoteOf(s.localDeviceId);
    final pin = s.pinned;
    if (pin != null && !_bytesEqual(pin, remote.staticKey)) {
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

class _FakeTransport implements BleTransport {
  _FakeTransport(this.maximumWriteLength);

  @override
  final int maximumWriteLength;

  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final List<Uint8List> writes = [];
  _FakeTransport? peer;
  bool _closed = false;

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

/// Reassembles every v1 frame a side wrote and returns the transfer kinds,
/// letting tests prove no plaintext message/ACK was ever emitted.
List<BleTransferKind> _v1KindsWritten(_FakeTransport transport) {
  final assembler = BleTransferAssembler();
  final kinds = <BleTransferKind>[];
  for (final frame in transport.writes) {
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

List<Uint8List> _craftOversizedHandshake(
  int totalLength, {
  int transferId = 77,
}) {
  final payload = Uint8List(totalLength);
  final frames = <Uint8List>[
    BleSecureFrame(
      type: BleFrameType.start,
      transferId: transferId,
      sequence: 0,
      payload: BleSecureStartPayload(
        kind: BleSecureTransferKind.secureHandshake,
        totalLength: totalLength,
        checksum: BleSecureTransferCodec.checksum(payload),
      ).encode(),
    ).encode(),
  ];
  var sequence = 1;
  var offset = 0;
  const chunk = 100;
  while (offset < totalLength) {
    final end = offset + chunk > totalLength ? totalLength : offset + chunk;
    frames.add(
      BleSecureFrame(
        type: BleFrameType.data,
        transferId: transferId,
        sequence: sequence,
        payload: payload.sublist(offset, end),
      ).encode(),
    );
    sequence++;
    offset = end;
  }
  frames.add(
    BleSecureFrame(
      type: BleFrameType.end,
      transferId: transferId,
      sequence: sequence,
      payload: _empty,
    ).encode(),
  );
  return frames;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Message _message() {
  final now = DateTime.utc(2026, 2, 3, 4, 5, 6);
  return Message(
    messageId: 'msg-1',
    chatId: 'chat-1',
    senderId: 'device-a',
    receiverId: 'device-b',
    content: 'Hello from A',
    timestamp: now,
    ttl: 3600,
    createdAt: now,
    updatedAt: now,
  );
}

Identity _identity(String id, String name) =>
    Identity(deviceId: id, displayName: name);

/// A legacy v1 pair wired exactly like BleRuntimeController wires sessions.
class _LegacyPair {
  _LegacyPair() {
    transportA = _FakeTransport(64);
    transportB = _FakeTransport(48);
    transportA.peer = transportB;
    transportB.peer = transportA;

    sessionA = BleLinkSession(
      transport: transportA,
      identity: _identity('device-a', 'Alice'),
      onHello: (hello) async {},
      onMessage: (payload) async => BleAckResult.stored,
      transferIdFactory: () => 1,
    );
    sessionB = BleLinkSession(
      transport: transportB,
      identity: _identity('device-b', 'Bob'),
      onHello: (hello) async {},
      onMessage: (payload) async {
        receivedOnB.add(payload);
        return BleAckResult.stored;
      },
      transferIdFactory: () => 2,
    );
  }

  late final _FakeTransport transportA;
  late final _FakeTransport transportB;
  late final BleLinkSession sessionA;
  late final BleLinkSession sessionB;
  final List<BleMessagePayload> receivedOnB = [];

  Future<void> start() => Future.wait([sessionA.start(), sessionB.start()]);
}

/// A secure pair: A is the BLE peripheral (Noise initiator), B the BLE
/// central (Noise responder), sharing one fake native engine.
class _SecurePair {
  _SecurePair({
    Uint8List? pinA,
    String? expectedPeerDeviceIdA,
    bool requireHelloBindingA = false,
    RemoteAuthenticatedIdentity? remoteIdentityForA,
    void Function(RemoteAuthenticatedIdentity identity)? onIdentityA,
    Duration handshakeTimeout = const Duration(seconds: 2),
    bool rejectHelloOnB = false,
  }) {
    gateway = _FakeSecureGateway(
      devices: [_deviceA, _deviceB],
      remoteIdentityOverride: remoteIdentityForA == null
          ? null
          : (localDeviceId) =>
                localDeviceId == 'device-a' ? remoteIdentityForA : null,
    );
    transportA = _FakeTransport(64);
    transportB = _FakeTransport(48);
    transportA.peer = transportB;
    transportB.peer = transportA;

    sessionA = BleLinkSession(
      transport: transportA,
      identity: _identity('device-a', 'Alice'),
      onHello: (hello) async {},
      onMessage: (payload) async {
        receivedOnA.add(payload);
        return BleAckResult.stored;
      },
      onClosed: closedErrorsA.add,
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
      identity: _identity('device-b', 'Bob'),
      onHello: (hello) async {
        if (rejectHelloOnB) {
          throw const BleLinkException('Peer is blocked');
        }
      },
      onMessage: (payload) async => BleAckResult.stored,
      onClosed: closedErrorsB.add,
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

  late final _FakeSecureGateway gateway;
  late final _FakeTransport transportA;
  late final _FakeTransport transportB;
  late final BleLinkSession sessionA;
  late final BleLinkSession sessionB;
  final List<Object?> closedErrorsA = [];
  final List<Object?> closedErrorsB = [];
  final List<BleMessagePayload> receivedOnA = [];
  RemoteAuthenticatedIdentity? identitySeenOnB;

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
