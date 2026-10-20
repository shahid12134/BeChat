import 'dart:convert';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/data/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('frame codec', () {
    test('round-trips a frame with big-endian header fields', () {
      final frame = BleFrame(
        type: BleFrameType.data,
        transferId: 0x1234,
        sequence: 0xabcd,
        payload: Uint8List.fromList([1, 2, 3]),
      );

      final encoded = frame.encode();
      expect(encoded[0], BleProtocol.magic);
      expect(encoded[4], 0x12);
      expect(encoded[5], 0x34);
      expect(encoded[6], 0xab);
      expect(encoded[7], 0xcd);
      expect(encoded[8], 0);
      expect(encoded[9], 3);

      final decoded = BleFrame.decode(encoded);
      expect(decoded.type, BleFrameType.data);
      expect(decoded.transferId, 0x1234);
      expect(decoded.sequence, 0xabcd);
      expect(decoded.payload, [1, 2, 3]);
    });

    test('rejects invalid magic, version, and mismatched lengths', () {
      final encoded = BleFrame(
        type: BleFrameType.start,
        transferId: 1,
        sequence: 0,
        payload: Uint8List.fromList([0, 0, 0, 0, 0, 0, 0]),
      ).encode();

      final badMagic = Uint8List.fromList(encoded)..[0] = 0;
      expect(
        () => BleFrame.decode(badMagic),
        throwsA(isA<BleProtocolException>()),
      );

      final badVersion = Uint8List.fromList(encoded)..[1] = 99;
      expect(
        () => BleFrame.decode(badVersion),
        throwsA(isA<BleProtocolException>()),
      );

      expect(
        () => BleFrame.decode(encoded.sublist(0, encoded.length - 1)),
        throwsA(isA<BleProtocolException>()),
      );
    });
  });

  group('transfer framing', () {
    for (final writeLength in [26, 64, 512]) {
      test('fragments and reassembles with write length $writeLength', () {
        final payload = Uint8List.fromList(
          List.generate(257, (index) => index % 256),
        );
        final frames = BleTransferCodec.fragment(
          kind: BleTransferKind.message,
          payload: payload,
          maxWriteLength: writeLength,
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
    }

    test('rejects missing, reordered, and duplicate fragments', () {
      final frames = BleTransferCodec.fragment(
        kind: BleTransferKind.message,
        payload: Uint8List.fromList(List.generate(50, (index) => index)),
        maxWriteLength: 26,
        transferId: 7,
      );
      final assembler = BleTransferAssembler();
      assembler.add(BleFrame.decode(frames.first));

      expect(
        () => assembler.add(BleFrame.decode(frames[2])),
        throwsA(isA<BleProtocolException>()),
      );

      final second = BleTransferAssembler()
        ..add(BleFrame.decode(frames.first))
        ..add(BleFrame.decode(frames[1]));
      expect(
        () => second.add(BleFrame.decode(frames[1])),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects checksum mismatches', () {
      final frames = BleTransferCodec.fragment(
        kind: BleTransferKind.acknowledgement,
        payload: Uint8List.fromList(utf8.encode('{"ok":true}')),
        maxWriteLength: 26,
        transferId: 3,
      );
      final last = Uint8List.fromList(frames.last);
      final corruptData = Uint8List.fromList(frames[1]);
      corruptData[corruptData.length - 1] ^= 0xff;

      final assembler = BleTransferAssembler();
      assembler.add(BleFrame.decode(frames.first));
      assembler.add(BleFrame.decode(corruptData));

      expect(
        () => assembler.add(BleFrame.decode(last)),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects declared lengths above the protocol limit', () {
      final bytes = Uint8List(7);
      final data = ByteData.sublistView(bytes);
      data.setUint8(0, BleTransferKind.message.value);
      data.setUint16(1, BleProtocol.maxTransferLength + 1, Endian.big);
      data.setUint32(3, 0, Endian.big);

      expect(
        () => BleStartPayload.decode(bytes),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('requires enough space for the header and start payload', () {
      for (final length in [BleProtocol.frameHeaderLength, 16]) {
        expect(
          () => BleTransferCodec.fragment(
            kind: BleTransferKind.hello,
            payload: Uint8List(0),
            maxWriteLength: length,
            transferId: 1,
          ),
          throwsA(isA<BleProtocolException>()),
        );
      }
    });
  });

  group('HELLO', () {
    test('round-trips and validates', () {
      const hello = BleHello(
        deviceId: 'device-remote',
        displayName: 'Remote phone',
      );
      final decoded = BleHello.decode(hello.encode());
      decoded.validate(localDeviceId: 'device-local');

      expect(decoded.deviceId, 'device-remote');
      expect(decoded.displayName, 'Remote phone');
      expect(decoded.maxMessageSize, BleProtocol.maxMessageContentBytes);
      expect(decoded.capabilities, contains(BleProtocol.capabilityAck));
    });

    test('rejects the local device id and unsupported versions', () {
      const hello = BleHello(
        deviceId: 'device-local',
        displayName: 'Remote phone',
      );
      expect(
        () => hello.validate(localDeviceId: 'device-local'),
        throwsA(isA<BleProtocolException>()),
      );

      final json =
          jsonDecode(utf8.decode(hello.encode())) as Map<String, dynamic>;
      json['protocolVersion'] = 2;
      expect(
        () =>
            BleHello.decode(Uint8List.fromList(utf8.encode(jsonEncode(json)))),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects missing capabilities', () {
      const hello = BleHello(
        deviceId: 'device-remote',
        displayName: 'Remote phone',
        capabilities: [BleProtocol.capabilityText],
      );
      expect(() => hello.encode(), throwsA(isA<BleProtocolException>()));
    });
  });

  group('message payload', () {
    test('preserves UTF-8 byte length independently of character count', () {
      final timestamp = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final content = '${List.filled(1000, '😀').join()}ok';
      final payload = BleMessagePayload(
        metadata: BleMessageMetadata(
          messageId: 'msg-1',
          senderId: 'device-a',
          receiverId: 'device-b',
          messageType: MessageType.text.name,
          timestamp: timestamp,
          ttl: 86400,
          contentLength: content.length,
          isEncrypted: false,
        ),
        content: content,
      );
      final bytes = payload.encode();
      final decoded = BleMessagePayload.decode(bytes);

      expect(decoded.content, content);
      expect(decoded.metadata.contentLength, utf8.encode(content).length);
      expect(decoded.metadata.timestamp, timestamp);
    });

    test('rejects malformed UTF-8 and content over 4096 bytes', () {
      final metadata = BleMessageMetadata(
        messageId: 'msg-1',
        senderId: 'device-a',
        receiverId: 'device-b',
        messageType: MessageType.text.name,
        timestamp: DateTime.utc(2026),
        ttl: 60,
        contentLength: 1,
        isEncrypted: false,
      );
      final metadataBytes = utf8.encode(jsonEncode(metadata.toJson()));
      final malformed = Uint8List(2 + metadataBytes.length + 1);
      ByteData.sublistView(
        malformed,
      ).setUint16(0, metadataBytes.length, Endian.big);
      malformed.setRange(2, 2 + metadataBytes.length, metadataBytes);
      malformed[malformed.length - 1] = 0xff;

      expect(
        () => BleMessagePayload.decode(malformed),
        throwsA(isA<BleProtocolException>()),
      );

      final oversized = BleMessagePayload(
        metadata: metadata,
        content: 'a' * (BleProtocol.maxMessageContentBytes + 1),
      );
      expect(() => oversized.encode(), throwsA(isA<BleProtocolException>()));
    });

    test('rejects encrypted messages in Phase 2', () {
      final payload = BleMessagePayload(
        metadata: BleMessageMetadata(
          messageId: 'msg-1',
          senderId: 'device-a',
          receiverId: 'device-b',
          messageType: MessageType.text.name,
          timestamp: DateTime.utc(2026),
          ttl: 60,
          contentLength: 5,
          isEncrypted: true,
        ),
        content: 'hello',
      );
      final bytes = payload.encode();
      expect(
        () => BleMessagePayload.decode(bytes),
        throwsA(isA<BleProtocolException>()),
      );
    });
  });

  group('acknowledgements', () {
    test('round-trips stored, duplicate, and rejected results', () {
      for (final result in BleAckResult.values) {
        final ack = BleAck(
          messageId: 'msg-1',
          result: result,
          reason: result == BleAckResult.rejected ? 'blocked' : null,
        );
        final decoded = BleAck.decode(ack.encode());
        expect(decoded.messageId, 'msg-1');
        expect(decoded.result, result);
        expect(
          decoded.reason,
          result == BleAckResult.rejected ? 'blocked' : null,
        );
      }
    });

    test('rejects unknown acknowledgement results', () {
      final bytes = Uint8List.fromList(
        utf8.encode('{"messageId":"msg-1","result":"maybe"}'),
      );
      expect(() => BleAck.decode(bytes), throwsA(isA<BleProtocolException>()));
    });
  });
}
