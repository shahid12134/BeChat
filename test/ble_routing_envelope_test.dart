import 'dart:typed_data';

import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_routing_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List buildMessagePayload({String content = 'hello mesh'}) {
  return BleMessagePayload(
    metadata: BleMessageMetadata(
      messageId: 'msg-envelope-1',
      senderId: 'device-a',
      receiverId: 'device-b',
      messageType: 'text',
      timestamp: DateTime.utc(2026, 6, 1, 10),
      ttl: 86400,
      contentLength: 0, // replaced by encode()
      isEncrypted: false,
    ),
    content: content,
  ).encode();
}

BleRoutingEnvelope buildEnvelope({
  String envelopeId = 'env-1',
  String origin = 'device-a',
  String destination = 'device-b',
  DateTime? createdAt,
  DateTime? expiresAt,
  int hopLimit = 5,
  int hopCount = 0,
  Uint8List? payload,
}) {
  final created = createdAt ?? DateTime.utc(2026, 6, 1, 10);
  return BleRoutingEnvelope(
    envelopeId: envelopeId,
    originDeviceId: origin,
    destinationDeviceId: destination,
    createdAt: created,
    expiresAt: expiresAt ?? created.add(const Duration(hours: 1)),
    hopLimit: hopLimit,
    hopCount: hopCount,
    payload: payload ?? buildMessagePayload(),
  );
}

void main() {
  group('BleRoutingEnvelope round-trip', () {
    test('preserves every field through encode/decode', () {
      final original = buildEnvelope();
      final decoded = BleRoutingEnvelope.decode(original.encode());

      expect(decoded.envelopeType, BleRoutingEnvelopeType.message);
      expect(decoded.envelopeId, original.envelopeId);
      expect(decoded.originDeviceId, original.originDeviceId);
      expect(decoded.destinationDeviceId, original.destinationDeviceId);
      expect(decoded.createdAt, original.createdAt);
      expect(decoded.expiresAt, original.expiresAt);
      expect(decoded.hopLimit, original.hopLimit);
      expect(decoded.hopCount, original.hopCount);
      expect(decoded.payload, original.payload);
    });

    test('preserves a non-zero hop count', () {
      final original = buildEnvelope(hopLimit: 8, hopCount: 3);
      final decoded = BleRoutingEnvelope.decode(original.encode());
      expect(decoded.hopCount, 3);
      expect(decoded.remainingHops, 5);
    });

    test('wraps an intact BleMessagePayload', () {
      final payload = buildMessagePayload(content: 'opaque inner bytes');
      final decoded = BleRoutingEnvelope.decode(
        buildEnvelope(payload: payload).encode(),
      );

      final inner = BleMessagePayload.decode(decoded.payload);
      expect(inner.content, 'opaque inner bytes');
      expect(inner.metadata.messageId, 'msg-envelope-1');
      expect(inner.metadata.senderId, 'device-a');
      expect(inner.metadata.receiverId, 'device-b');
    });

    test('encoded bytes start with the routing magic and version', () {
      final bytes = buildEnvelope().encode();
      expect(bytes[0], BleRoutingEnvelope.magic);
      expect(bytes[1], BleRoutingEnvelope.protocolVersion);
    });
  });

  group('BleRoutingEnvelope validation', () {
    test('rejects a truncated header', () {
      expect(
        () => BleRoutingEnvelope.decode(Uint8List(8)),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects a wrong magic byte', () {
      final bytes = buildEnvelope().encode();
      bytes[0] = 0x42; // v1 frame magic
      expect(
        () => BleRoutingEnvelope.decode(bytes),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects an unsupported version', () {
      final bytes = buildEnvelope().encode();
      bytes[1] = 99;
      expect(
        () => BleRoutingEnvelope.decode(bytes),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects unknown envelope flags', () {
      final bytes = buildEnvelope().encode();
      bytes[3] = 0x01;
      expect(
        () => BleRoutingEnvelope.decode(bytes),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects an unknown envelope type', () {
      final bytes = buildEnvelope().encode();
      bytes[2] = 7;
      expect(
        () => BleRoutingEnvelope.decode(bytes),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects a length that disagrees with the header', () {
      final bytes = buildEnvelope().encode();
      final truncated = Uint8List.fromList(bytes.sublist(0, bytes.length - 1));
      expect(
        () => BleRoutingEnvelope.decode(truncated),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects payload bytes that are not a valid message', () {
      // Encode trusts the caller's payload; decode is where the inner bytes
      // must prove they are a well-formed BleMessagePayload.
      final bytes = buildEnvelope(
        payload: Uint8List.fromList([1, 2, 3]),
      ).encode();
      expect(
        () => BleRoutingEnvelope.decode(bytes),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects a hop limit above the maximum', () {
      expect(
        () => buildEnvelope(
          hopLimit: BleRoutingEnvelope.maxHopLimit + 1,
        ).encode(),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects a hop count above the hop limit', () {
      expect(
        () => buildEnvelope(hopLimit: 2, hopCount: 3).encode(),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects identical origin and destination', () {
      expect(
        () =>
            buildEnvelope(origin: 'device-a', destination: 'device-a').encode(),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects an empty envelope id', () {
      expect(
        () => buildEnvelope(envelopeId: '   ').encode(),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects device ids above the maximum length', () {
      final longId = 'd' * (BleRoutingEnvelope.maxDeviceIdBytes + 1);
      expect(
        () => buildEnvelope(origin: longId).encode(),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects an expiry before creation', () {
      final created = DateTime.utc(2026, 6, 1, 10);
      expect(
        () => buildEnvelope(
          createdAt: created,
          expiresAt: created.subtract(const Duration(minutes: 1)),
        ).encode(),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects a zero-length TTL', () {
      final created = DateTime.utc(2026, 6, 1, 10);
      expect(
        () => buildEnvelope(createdAt: created, expiresAt: created).encode(),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('rejects a TTL beyond the 7-day maximum', () {
      final created = DateTime.utc(2026, 6, 1, 10);
      expect(
        () => buildEnvelope(
          createdAt: created,
          expiresAt: created.add(
            const Duration(seconds: BleRoutingEnvelope.maxTtlSeconds + 1),
          ),
        ).encode(),
        throwsA(isA<BleProtocolException>()),
      );
    });

    test('accepts a TTL exactly at the 7-day maximum', () {
      final created = DateTime.utc(2026, 6, 1, 10);
      final envelope = buildEnvelope(
        createdAt: created,
        expiresAt: created.add(
          const Duration(seconds: BleRoutingEnvelope.maxTtlSeconds),
        ),
      );
      expect(envelope.ttlSeconds, BleRoutingEnvelope.maxTtlSeconds);
    });

    test('rejects timestamps outside the uint32 epoch range', () {
      final created = DateTime.utc(1900, 1, 1);
      expect(
        () => buildEnvelope(
          createdAt: created,
          expiresAt: DateTime.utc(1900, 1, 2),
        ).encode(),
        throwsA(isA<BleProtocolException>()),
      );
    });
  });

  group('BleRoutingEnvelope expiry', () {
    test('is not expired before the expiry instant', () {
      final envelope = buildEnvelope(expiresAt: DateTime.utc(2026, 6, 1, 11));
      expect(envelope.isExpiredAt(DateTime.utc(2026, 6, 1, 10, 59)), isFalse);
    });

    test('is expired at and after the expiry instant', () {
      final envelope = buildEnvelope(expiresAt: DateTime.utc(2026, 6, 1, 11));
      expect(envelope.isExpiredAt(DateTime.utc(2026, 6, 1, 11)), isTrue);
      expect(envelope.isExpiredAt(DateTime.utc(2026, 6, 1, 12)), isTrue);
    });

    test('round-trips a future-dated envelope unchanged', () {
      final created = DateTime.utc(2030, 1, 1, 12);
      final original = buildEnvelope(
        createdAt: created,
        expiresAt: created.add(const Duration(hours: 2)),
      );
      final decoded = BleRoutingEnvelope.decode(original.encode());
      expect(decoded.createdAt, created);
      expect(decoded.isExpiredAt(DateTime.utc(2026, 6, 1)), isFalse);
    });
  });

  group('BleRoutingEnvelope forwarding', () {
    test('forward() increments only hop count', () {
      final original = buildEnvelope(hopLimit: 5, hopCount: 1);
      final forwarded = original.forward();

      expect(forwarded.hopCount, 2);
      expect(forwarded.envelopeId, original.envelopeId);
      expect(forwarded.envelopeType, original.envelopeType);
      expect(forwarded.originDeviceId, original.originDeviceId);
      expect(forwarded.destinationDeviceId, original.destinationDeviceId);
      expect(forwarded.createdAt, original.createdAt);
      expect(forwarded.expiresAt, original.expiresAt);
      expect(forwarded.hopLimit, original.hopLimit);
      expect(forwarded.payload, original.payload);
    });

    test('forwarded envelope still round-trips', () {
      final forwarded = buildEnvelope(hopLimit: 5).forward().forward();
      final decoded = BleRoutingEnvelope.decode(forwarded.encode());
      expect(decoded.hopCount, 2);
    });

    test('forward() fails closed when the hop budget is exhausted', () {
      final exhausted = buildEnvelope(hopLimit: 2, hopCount: 2);
      expect(exhausted.forward, throwsA(isA<BleProtocolException>()));
    });

    test('forward() refuses a zero-hop envelope at the limit', () {
      final atLimit = buildEnvelope(hopLimit: 0, hopCount: 0);
      expect(atLimit.forward, throwsA(isA<BleProtocolException>()));
    });
  });
}
