import 'dart:convert';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_secure_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A stand-in for Noise transport ciphertext: opaque, high-entropy-looking
  // bytes. The codec must treat it as an opaque blob and never parse it.
  Uint8List cipher(int length) =>
      Uint8List.fromList(List.generate(length, (i) => (i * 31 + 7) & 0xff));

  // Reassembles a list of encoded frames and returns the completed transfer.
  BleSecureTransfer reassemble(List<Uint8List> frames) {
    final assembler = BleSecureTransferAssembler();
    BleSecureTransfer? done;
    for (final encoded in frames) {
      final result = assembler.add(BleSecureFrame.decode(encoded));
      if (result != null) done = result;
    }
    return done!;
  }

  group('protocol constants and kind assignments', () {
    test('secure version is 2 and does not collide with the v1 default', () {
      expect(BleSecureProtocol.version, 2);
      expect(BleProtocol.version, 1);
      expect(BleSecureProtocol.version, isNot(BleProtocol.version));
    });

    test('secure transfer kinds sit above every v1 kind and never overlap', () {
      final v1Values = BleTransferKind.values.map((k) => k.value).toSet();
      for (final kind in BleSecureTransferKind.values) {
        expect(
          v1Values.contains(kind.value),
          isFalse,
          reason: '${kind.name} must not reuse a v1 kind value',
        );
      }
      expect(BleSecureTransferKind.secureHandshake.value, 5);
      expect(BleSecureTransferKind.secureMessage.value, 6);
      expect(BleSecureTransferKind.secureAck.value, 7);
    });

    test('engine transport limits are mirrored exactly', () {
      expect(BleSecureProtocol.maxHandshakeBytes, 1024);
      expect(BleSecureProtocol.maxTransportBytes, 8192);
      expect(BleSecureProtocol.maxTransportPlaintextBytes, 8176);
      expect(BleSecureProtocol.noiseAuthenticationTagBytes, 16);
      expect(
        BleSecureProtocol.maxTransportBytes,
        BleProtocol.maxTransferLength,
      );
      expect(
        BleSecureProtocol.maxFramePayloadLength,
        BleProtocol.maxFramePayloadLength,
      );
    });

    test('there is deliberately no secureError kind', () {
      expect(
        BleSecureTransferKind.values.map((k) => k.name),
        isNot(contains('secureError')),
      );
      // Unknown values, including a hypothetical 8, are rejected.
      expect(
        () => BleSecureTransferKind.fromValue(8),
        throwsA(isA<BleProtocolException>()),
      );
    });
  });

  group('secure frame round trip', () {
    test('preserves header fields big-endian and version 2', () {
      final frame = BleSecureFrame(
        type: BleFrameType.data,
        transferId: 0x1234,
        sequence: 0xabcd,
        payload: Uint8List.fromList([1, 2, 3]),
      );

      final encoded = frame.encode();
      expect(encoded[0], BleSecureProtocol.magic);
      expect(encoded[1], 2, reason: 'version byte must be 2');
      expect(encoded[4], 0x12);
      expect(encoded[5], 0x34);
      expect(encoded[6], 0xab);
      expect(encoded[7], 0xcd);
      expect(encoded[8], 0);
      expect(encoded[9], 3);

      final decoded = BleSecureFrame.decode(encoded);
      expect(decoded.type, BleFrameType.data);
      expect(decoded.version, 2);
      expect(decoded.transferId, 0x1234);
      expect(decoded.sequence, 0xabcd);
      expect(decoded.payload, [1, 2, 3]);
    });

    test('rejects bad magic, wrong version, truncated header, bad flags', () {
      final encoded = BleSecureFrame(
        type: BleFrameType.start,
        transferId: 1,
        sequence: 0,
        payload: Uint8List(7),
      ).encode();

      final badMagic = Uint8List.fromList(encoded)..[0] = 0;
      expect(
        () => BleSecureFrame.decode(badMagic),
        throwsA(isA<BleProtocolException>()),
      );

      final v1 = Uint8List.fromList(encoded)..[1] = 1;
      expect(
        () => BleSecureFrame.decode(v1),
        throwsA(isA<BleProtocolException>()),
        reason: 'a version-1 frame must never decode as secure',
      );

      final v3 = Uint8List.fromList(encoded)..[1] = 3;
      expect(
        () => BleSecureFrame.decode(v3),
        throwsA(isA<BleProtocolException>()),
      );

      final badFlags = Uint8List.fromList(encoded)..[3] = 0xff;
      expect(
        () => BleSecureFrame.decode(badFlags),
        throwsA(isA<BleProtocolException>()),
      );

      expect(
        () => BleSecureFrame.decode(encoded.sublist(0, 5)),
        throwsA(isA<BleProtocolException>()),
      );
    });
  });

  group('secure transfer fragmentation and reassembly', () {
    for (final writeLength in [26, 64, 512]) {
      test('round-trips a secureMessage with write length $writeLength', () {
        final payload = cipher(257);
        final frames = BleSecureTransferCodec.fragment(
          kind: BleSecureTransferKind.secureMessage,
          payload: payload,
          maxWriteLength: writeLength,
          transferId: 42,
        );
        final transfer = reassemble(frames);

        expect(transfer.kind, BleSecureTransferKind.secureMessage);
        expect(transfer.payload, payload, reason: 'binary must be preserved');
      });
    }

    test('round-trips each secure kind with exact binary preservation', () {
      for (final kind in BleSecureTransferKind.values) {
        final length = kind == BleSecureTransferKind.secureHandshake ? 64 : 200;
        final payload = cipher(length);
        final frames = BleSecureTransferCodec.fragment(
          kind: kind,
          payload: payload,
          maxWriteLength: 64,
          transferId: 7,
        );
        final transfer = reassemble(frames);

        expect(transfer.kind, kind);
        expect(transfer.payload, payload);
      }
    });

    test('a secureAck payload stays opaque and the codec adds no fields', () {
      // Model an encrypted ACK. In production this payload is Noise ciphertext
      // produced by the engine; here it is opaque, non-textual bytes. The
      // codec must preserve them exactly and introduce no JSON field names of
      // its own, so the ACK's real messageId/result (which live inside the
      // ciphertext) are never reconstructable from the outer frames.
      final ciphertext = cipher(96);

      final frames = BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureAck,
        payload: ciphertext,
        maxWriteLength: 64,
        transferId: 3,
      );
      final transfer = reassemble(frames);

      expect(transfer.kind, BleSecureTransferKind.secureAck);
      expect(transfer.payload, ciphertext);

      // The outer frames carry only the numeric secure kind (7) in the start
      // descriptor, never any ACK application field name.
      final outerText = String.fromCharCodes(frames.expand((f) => f));
      for (final field in [
        'messageId',
        'result',
        'reason',
        'stored',
        'rejected',
      ]) {
        expect(outerText.contains(field), isFalse);
      }
      // The first data frame's payload begins exactly with the ciphertext's
      // first bytes: nothing is prepended or wrapped by the codec.
      final firstData = BleSecureFrame.decode(frames[1]);
      expect(
        firstData.payload,
        ciphertext.sublist(0, firstData.payload.length),
      );
    });

    test('start descriptor exposes only kind, length and checksum', () {
      final payload = cipher(32);
      final start = BleSecureStartPayload(
        kind: BleSecureTransferKind.secureMessage,
        totalLength: payload.length,
        checksum: BleSecureTransferCodec.checksum(payload),
      );
      final encoded = start.encode();

      expect(encoded.length, 7);
      expect(encoded[0], BleSecureTransferKind.secureMessage.value);
      final decoded = BleSecureStartPayload.decode(encoded);
      expect(decoded.kind, BleSecureTransferKind.secureMessage);
      expect(decoded.totalLength, 32);
      expect(decoded.checksum, BleSecureTransferCodec.checksum(payload));
    });

    test('rejects missing, reordered and duplicate fragments', () {
      final frames = BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureMessage,
        payload: cipher(50),
        maxWriteLength: 26,
        transferId: 7,
      );

      final first = BleSecureTransferAssembler()
        ..add(BleSecureFrame.decode(frames.first));
      expect(
        () => first.add(BleSecureFrame.decode(frames[2])),
        throwsA(isA<BleProtocolException>()),
      );

      final second = BleSecureTransferAssembler()
        ..add(BleSecureFrame.decode(frames.first))
        ..add(BleSecureFrame.decode(frames[1]));
      expect(
        () => second.add(BleSecureFrame.decode(frames[1])),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects a checksum mismatch as an integrity failure', () {
      final frames = BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureMessage,
        payload: cipher(40),
        maxWriteLength: 26,
        transferId: 3,
      );
      final corrupt = Uint8List.fromList(frames[1]);
      corrupt[corrupt.length - 1] ^= 0xff;

      final assembler = BleSecureTransferAssembler()
        ..add(BleSecureFrame.decode(frames.first))
        ..add(BleSecureFrame.decode(corrupt));
      // Feed every remaining data frame (frames[2] .. frames[last-1]) so the
      // end frame's sequence matches and the checksum check is reached.
      for (var i = 2; i < frames.length - 1; i++) {
        assembler.add(BleSecureFrame.decode(frames[i]));
      }
      expect(
        () => assembler.add(BleSecureFrame.decode(frames.last)),
        throwsA(
          isA<BleProtocolException>().having(
            (e) => e.message,
            'message',
            contains('checksum'),
          ),
        ),
      );
    });

    test('caps concurrent transfers at two, mirroring v1 memory bounds', () {
      final assembler = BleSecureTransferAssembler();
      for (final id in [1, 2]) {
        final frames = BleSecureTransferCodec.fragment(
          kind: BleSecureTransferKind.secureMessage,
          payload: cipher(20),
          maxWriteLength: 64,
          transferId: id,
        );
        assembler.add(BleSecureFrame.decode(frames.first));
      }
      final third = BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureMessage,
        payload: cipher(20),
        maxWriteLength: 64,
        transferId: 3,
      );
      expect(
        () => assembler.add(BleSecureFrame.decode(third.first)),
        throwsA(isA<BleProtocolException>()),
      );
    });
  });

  group('size-limit enforcement before allocation', () {
    test('rejects an empty or oversized handshake payload', () {
      expect(
        () => BleSecureTransferCodec.validatePayload(
          BleSecureTransferKind.secureHandshake,
          Uint8List(0),
        ),
        throwsA(isA<BleProtocolException>()),
      );
      expect(
        () => BleSecureTransferCodec.fragment(
          kind: BleSecureTransferKind.secureHandshake,
          payload: cipher(BleSecureProtocol.maxHandshakeBytes + 1),
          maxWriteLength: 64,
          transferId: 1,
        ),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects an oversized encrypted message payload', () {
      expect(
        () => BleSecureTransferCodec.fragment(
          kind: BleSecureTransferKind.secureMessage,
          payload: cipher(BleSecureProtocol.maxTransportBytes + 1),
          maxWriteLength: 64,
          transferId: 1,
        ),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects an oversized secure ack payload', () {
      expect(
        () => BleSecureTransferCodec.fragment(
          kind: BleSecureTransferKind.secureAck,
          payload: cipher(BleSecureProtocol.maxTransportBytes + 1),
          maxWriteLength: 64,
          transferId: 1,
        ),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects a transport payload smaller than the AEAD tag', () {
      expect(
        () => BleSecureTransferCodec.validatePayload(
          BleSecureTransferKind.secureMessage,
          cipher(BleSecureProtocol.minTransportBytes - 1),
        ),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('accepts a payload exactly at each boundary', () {
      expect(
        () => BleSecureTransferCodec.validatePayload(
          BleSecureTransferKind.secureHandshake,
          cipher(BleSecureProtocol.maxHandshakeBytes),
        ),
        returnsNormally,
      );
      expect(
        () => BleSecureTransferCodec.validatePayload(
          BleSecureTransferKind.secureMessage,
          cipher(BleSecureProtocol.maxTransportBytes),
        ),
        returnsNormally,
      );
      expect(
        () => BleSecureTransferCodec.validatePayload(
          BleSecureTransferKind.secureMessage,
          cipher(BleSecureProtocol.minTransportBytes),
        ),
        returnsNormally,
      );
    });

    test('rejects a declared start length above the transfer limit', () {
      final bytes = Uint8List(7);
      final data = ByteData.sublistView(bytes);
      data.setUint8(0, BleSecureTransferKind.secureMessage.value);
      data.setUint16(1, BleSecureProtocol.maxTransferLength + 1, Endian.big);
      data.setUint32(3, 0, Endian.big);

      expect(
        () => BleSecureStartPayload.decode(bytes),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('requires enough negotiated write length for the secure header', () {
      for (final length in [
        BleSecureProtocol.frameHeaderLength,
        BleSecureProtocol.minWriteLength - 1,
      ]) {
        expect(
          () => BleSecureTransferCodec.fragment(
            kind: BleSecureTransferKind.secureHandshake,
            payload: cipher(32),
            maxWriteLength: length,
            transferId: 1,
          ),
          throwsA(isA<BleProtocolException>()),
        );
      }
    });
  });

  group('version and kind validation at the boundary', () {
    test('the v2 decoder rejects a v1 kind smuggled into a v2 frame', () {
      // Build a v2 frame whose start descriptor claims the v1 "message" kind.
      final startBytes = Uint8List(7);
      final data = ByteData.sublistView(startBytes);
      data.setUint8(0, BleTransferKind.message.value); // v1 kind 2
      data.setUint16(1, 0, Endian.big);
      data.setUint32(3, 0, Endian.big);
      final frame = BleSecureFrame(
        type: BleFrameType.start,
        transferId: 1,
        sequence: 0,
        payload: startBytes,
      ).encode();

      final assembler = BleSecureTransferAssembler();
      expect(
        () => assembler.add(BleSecureFrame.decode(frame)),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('the legacy v1 frame decoder rejects every v2 frame', () {
      final frames = BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureMessage,
        payload: cipher(20),
        maxWriteLength: 64,
        transferId: 1,
      );
      for (final encoded in frames) {
        expect(
          () => BleFrame.decode(encoded),
          throwsA(isA<BleProtocolException>()),
          reason: 'a secure frame must never decode as a legacy frame',
        );
      }
    });

    test('the legacy v1 transfer-kind set rejects secure kind values', () {
      for (final kind in BleSecureTransferKind.values) {
        expect(
          () => BleTransferKind.fromValue(kind.value),
          throwsA(isA<BleProtocolException>()),
        );
      }
    });

    test('a v1 HELLO still rejects protocol version 2', () {
      const hello = BleHello(deviceId: 'remote', displayName: 'Remote');
      final json =
          jsonDecode(utf8.decode(hello.encode())) as Map<String, dynamic>;
      json['protocolVersion'] = 2;
      expect(
        () =>
            BleHello.decode(Uint8List.fromList(utf8.encode(jsonEncode(json)))),
        throwsA(isA<BleProtocolException>()),
      );
    });
  });

  group('security boundaries', () {
    test('a secure payload is never a decodable legacy message', () {
      // Opaque ciphertext fed to the v1 message codec must fail: it is not
      // valid UTF-8/JSON metadata.
      final ciphertext = cipher(64);
      expect(
        () => BleMessagePayload.decode(ciphertext),
        throwsA(isA<BleProtocolException>()),
      );
      expect(
        () => BleAck.decode(ciphertext),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('no application message id or sender appears in the outer frame', () {
      // The caller (runtime) would encrypt the real message; here we assert
      // the codec adds nothing: the encoded frames contain only the fixed
      // header bytes plus the exact opaque payload, no JSON fields.
      final ciphertext = cipher(48);
      final frames = BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureMessage,
        payload: ciphertext,
        maxWriteLength: 64,
        transferId: 9,
      );
      final concatenated = String.fromCharCodes(frames.expand((f) => f));

      for (final leaked in [
        'messageId',
        'senderId',
        'receiverId',
        'timestamp',
        'ttl',
        'contentLength',
        'isEncrypted',
      ]) {
        expect(
          concatenated.contains(leaked),
          isFalse,
          reason: '$leaked must not be exposed in the secure outer frame',
        );
      }
    });

    test(
      'decoding a transfer yields the ciphertext untouched, not plaintext',
      () {
        final ciphertext = cipher(40);
        final frames = BleSecureTransferCodec.fragment(
          kind: BleSecureTransferKind.secureMessage,
          payload: ciphertext,
          maxWriteLength: 64,
          transferId: 2,
        );
        final transfer = reassemble(frames);

        // The codec hands back the same bytes; it never decrypts or transforms.
        expect(transfer.payload, ciphertext);
        expect(transfer.payload.length, ciphertext.length);
      },
    );

    test('a successful decode is not an authentication claim', () {
      // A payload whose bytes happen to pass the FNV checksum still round-trips
      // as opaque bytes. The codec exposes no field asserting authenticity;
      // only the Noise engine can authenticate. This documents that boundary.
      final frames = BleSecureTransferCodec.fragment(
        kind: BleSecureTransferKind.secureAck,
        payload: cipher(24),
        maxWriteLength: 64,
        transferId: 5,
      );
      final transfer = reassemble(frames);
      expect(transfer.kind, BleSecureTransferKind.secureAck);
      // No `isAuthenticated`/`verified` member exists on the transfer type.
      expect(() => (transfer as dynamic).isAuthenticated, throwsA(anything));
    });
  });

  group('v1 compatibility is untouched', () {
    test('v1 frame still round-trips with version 1', () {
      final frame = BleFrame(
        type: BleFrameType.data,
        transferId: 5,
        sequence: 1,
        payload: Uint8List.fromList([9, 9, 9]),
      );
      final decoded = BleFrame.decode(frame.encode());
      expect(decoded.version, 1);
      expect(decoded.payload, [9, 9, 9]);
    });

    test('v1 fragmentation and reassembly still work unchanged', () {
      final payload = Uint8List.fromList(List.generate(257, (i) => i % 256));
      final frames = BleTransferCodec.fragment(
        kind: BleTransferKind.message,
        payload: payload,
        maxWriteLength: 64,
        transferId: 42,
      );
      final assembler = BleTransferAssembler();
      BleTransfer? transfer;
      for (final encoded in frames) {
        final result = assembler.add(BleFrame.decode(encoded));
        if (result != null) transfer = result;
      }
      expect(transfer, isNotNull);
      expect(transfer!.kind, BleTransferKind.message);
      expect(transfer.payload, payload);
    });
  });
}
