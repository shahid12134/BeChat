import 'dart:convert';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_protocol.dart';

/// Envelope type for [BleRoutingEnvelope].
///
/// Only [message] exists today. The numeric value is carried in the header so a
/// future type (ack, probe) can be added without a protocol-version bump, and
/// a decoder rejects any value it does not understand rather than guessing.
enum BleRoutingEnvelopeType {
  message(1);

  const BleRoutingEnvelopeType(this.value);

  final int value;

  static BleRoutingEnvelopeType fromValue(int value) {
    for (final type in values) {
      if (type.value == value) return type;
    }
    throw const BleProtocolException('Unknown routing envelope type');
  }
}

/// Multi-hop routing envelope (protocol v3).
///
/// A **pure framing layer** for future multi-hop messaging. It wraps an
/// existing [BleMessagePayload] — the exact bytes the secure v2 transfer
/// already carries — together with the routing metadata a relay needs to
/// forward it: who sent it, who it is for, how long it stays valid, and how
/// many more hops it may take.
///
/// ## Encryption boundary
///
/// This codec adds **no** cryptography. An envelope travels inside a hop-by-hop
/// Noise secure session (v2 `secureMessage`), so every individual hop is
/// authenticated and encrypted by the existing engine. That is **hop-by-hop**
/// protection only: each relay decrypts its own hop and sees the routing header
/// and inner payload in the clear. This codec deliberately does **not** claim
/// end-to-end encryption. A future end-to-end layer would encrypt [payload]
/// before wrapping; until then the payload is plaintext bytes.
///
/// ## Immutability during forwarding
///
/// Only [hopCount] changes as an envelope is relayed. Every other field is set
/// by the origin and stays byte-identical for the envelope's lifetime.
/// [forward] is the single sanctioned way to increment the hop count; there is
/// no setter for any other field, and the decoder re-validates the immutable
/// fields before an envelope is accepted.
///
/// ## Version / downgrade policy
///
/// [decode] accepts **only** [BleRoutingEnvelope.protocolVersion]. An unknown
/// version is rejected outright — never reinterpreted and never silently
/// downgraded to a v1/v2 payload — because a routing envelope means "multi-hop"
/// and must never be confused with a direct v1 message.
class BleRoutingEnvelope {
  const BleRoutingEnvelope({
    required this.envelopeId,
    required this.originDeviceId,
    required this.destinationDeviceId,
    required this.createdAt,
    required this.expiresAt,
    required this.hopLimit,
    required this.payload,
    this.envelopeType = BleRoutingEnvelopeType.message,
    this.hopCount = 0,
  });

  /// Routing-envelope protocol version carried in the header.
  static const int protocolVersion = 3;

  /// Distinct magic so a routing envelope can never be mistaken for a v1/v2
  /// message frame on the wire.
  static const int magic = 0x52; // 'R'

  /// Fixed header length: magic, version, type, flags, hop count, hop limit,
  /// the three variable-length fields' 16-bit length prefixes, plus the fixed
  /// 8-byte creation and expiry epoch-second stamps.
  static const int headerLength = 22;

  /// Upper bound on the opaque inner payload, matching the v2 transport
  /// plaintext limit so a wrapped envelope always fits one secure transfer.
  static const int maxPayloadBytes = 8176;

  /// Maximum lifetime of an envelope: 7 days, in seconds.
  static const int maxTtlSeconds = 7 * 24 * 60 * 60;

  /// Largest hop budget a origin may set. Chosen small for a phone-scale mesh;
  /// a relay never forwards an envelope whose remaining hops are exhausted.
  static const int maxHopLimit = 15;

  /// Longest accepted device id, mirroring the v1 identifier bound so routing
  /// ids stay the same shape as every other id in the app.
  static const int maxDeviceIdBytes = 128;

  /// Longest accepted envelope id — the unique deduplication key.
  static const int maxEnvelopeIdBytes = 128;

  final BleRoutingEnvelopeType envelopeType;

  /// Unique envelope id: the dedup key a relay uses to drop a copy it has
  /// already seen. Never changes during forwarding.
  final String envelopeId;

  /// Origin device that created the envelope. Never changes during forwarding.
  final String originDeviceId;

  /// Final destination device. Never changes during forwarding.
  final String destinationDeviceId;

  /// Creation instant (UTC). Never changes during forwarding.
  final DateTime createdAt;

  /// Instant after which the envelope must not be forwarded or delivered.
  /// Never changes during forwarding.
  final DateTime expiresAt;

  /// Total hop budget set by the origin.
  final int hopLimit;

  /// Hops taken so far. The **only** field that changes during forwarding.
  final int hopCount;

  /// Opaque inner bytes — the exact [BleMessagePayload] encoding, untouched.
  final Uint8List payload;

  /// Remaining hops an envelope may still take.
  int get remainingHops => hopLimit - hopCount;

  /// Whether [now] is at or past the expiry instant.
  bool isExpiredAt(DateTime now) => !now.toUtc().isBefore(expiresAt.toUtc());

  /// Total lifetime in seconds between creation and expiry.
  int get ttlSeconds =>
      expiresAt.toUtc().difference(createdAt.toUtc()).inSeconds;

  /// A copy of this envelope with [hopCount] incremented by one.
  ///
  /// Fails closed when no hop remains: forwarding an exhausted envelope would
  /// let a packet circle the mesh forever. Every other field is copied
  /// unchanged, preserving the immutability rule.
  BleRoutingEnvelope forward() {
    if (remainingHops <= 0) {
      throw const BleProtocolException('Routing envelope hop limit reached');
    }
    return BleRoutingEnvelope(
      envelopeId: envelopeId,
      envelopeType: envelopeType,
      originDeviceId: originDeviceId,
      destinationDeviceId: destinationDeviceId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      hopLimit: hopLimit,
      hopCount: hopCount + 1,
      payload: payload,
    );
  }

  /// Validates the immutable and bounded fields. Called by the codec on both
  /// encode and decode so a malformed envelope is rejected no matter which
  /// direction it travels.
  void _validate({required bool forEncode}) {
    if (envelopeId.trim().isEmpty || envelopeId.length > maxEnvelopeIdBytes) {
      throw const BleProtocolException('Invalid routing envelope id');
    }
    _validateDeviceId(originDeviceId, 'origin');
    _validateDeviceId(destinationDeviceId, 'destination');
    if (originDeviceId == destinationDeviceId) {
      throw const BleProtocolException(
        'Routing envelope origin and destination must differ',
      );
    }
    if (hopLimit < 0 || hopLimit > maxHopLimit) {
      throw const BleProtocolException('Invalid routing hop limit');
    }
    if (hopCount < 0 || hopCount > hopLimit) {
      throw const BleProtocolException('Invalid routing hop count');
    }
    final created = createdAt.toUtc();
    final expires = expiresAt.toUtc();
    // The header stores epoch seconds in a uint32, so anything outside
    // 1970..2106 cannot round-trip; reject it as malformed rather than letting
    // ByteData throw a raw RangeError deep inside encode.
    _validateEpochSeconds(created, 'creation');
    _validateEpochSeconds(expires, 'expiry');
    if (expires.isBefore(created)) {
      throw const BleProtocolException(
        'Routing envelope expires before it was created',
      );
    }
    final ttl = expires.difference(created).inSeconds;
    if (ttl <= 0 || ttl > maxTtlSeconds) {
      throw const BleProtocolException('Routing envelope TTL is out of bounds');
    }
    if (payload.length > maxPayloadBytes) {
      throw const BleProtocolException('Routing envelope payload is too large');
    }
    // On decode the inner bytes must already be a well-formed v2 message
    // payload; on encode the caller supplies them, so we only require bytes.
    if (forEncode) return;
    try {
      BleMessagePayload.decode(payload);
    } on BleProtocolException {
      throw const BleProtocolException(
        'Routing envelope payload is not a valid message',
      );
    }
  }

  static void _validateDeviceId(String value, String label) {
    if (value.trim().isEmpty || value.length > maxDeviceIdBytes) {
      throw BleProtocolException('Invalid routing envelope $label id');
    }
  }

  static void _validateEpochSeconds(DateTime value, String label) {
    const maxEpochSeconds = 0xFFFFFFFF; // uint32 ceiling, year 2106.
    final seconds = value.toUtc().millisecondsSinceEpoch ~/ 1000;
    if (seconds < 0 || seconds > maxEpochSeconds) {
      throw BleProtocolException('Routing envelope $label time out of bounds');
    }
  }

  Uint8List encode() {
    _validate(forEncode: true);

    final envelopeIdBytes = utf8.encode(envelopeId);
    final originBytes = utf8.encode(originDeviceId);
    final destinationBytes = utf8.encode(destinationDeviceId);
    final variableLength =
        envelopeIdBytes.length +
        originBytes.length +
        destinationBytes.length +
        payload.length;

    final bytes = Uint8List(headerLength + variableLength);
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, magic);
    data.setUint8(1, protocolVersion);
    data.setUint8(2, envelopeType.value);
    data.setUint8(3, 0); // flags, reserved
    data.setUint8(4, hopCount);
    data.setUint8(5, hopLimit);
    data.setUint16(6, envelopeIdBytes.length, Endian.big);
    data.setUint16(8, originBytes.length, Endian.big);
    data.setUint16(10, destinationBytes.length, Endian.big);
    data.setUint32(
      12,
      createdAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      Endian.big,
    );
    data.setUint32(
      16,
      expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      Endian.big,
    );
    data.setUint16(20, payload.length, Endian.big);

    var offset = headerLength;
    bytes.setRange(offset, offset + envelopeIdBytes.length, envelopeIdBytes);
    offset += envelopeIdBytes.length;
    bytes.setRange(offset, offset + originBytes.length, originBytes);
    offset += originBytes.length;
    bytes.setRange(offset, offset + destinationBytes.length, destinationBytes);
    offset += destinationBytes.length;
    bytes.setRange(offset, offset + payload.length, payload);
    return bytes;
  }

  static BleRoutingEnvelope decode(Uint8List bytes) {
    if (bytes.length < headerLength) {
      throw const BleProtocolException('Truncated routing envelope header');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint8(0) != magic) {
      throw const BleProtocolException('Invalid routing envelope magic');
    }
    if (data.getUint8(1) != protocolVersion) {
      throw const BleProtocolException('Unsupported routing envelope version');
    }
    if (data.getUint8(3) != 0) {
      throw const BleProtocolException('Unsupported routing envelope flags');
    }
    final envelopeType = BleRoutingEnvelopeType.fromValue(data.getUint8(2));
    final hopCount = data.getUint8(4);
    final hopLimit = data.getUint8(5);
    final envelopeIdLength = data.getUint16(6, Endian.big);
    final originLength = data.getUint16(8, Endian.big);
    final destinationLength = data.getUint16(10, Endian.big);
    final createdSeconds = data.getUint32(12, Endian.big);
    final expiresSeconds = data.getUint32(16, Endian.big);
    final payloadLength = data.getUint16(20, Endian.big);

    final expected =
        headerLength +
        envelopeIdLength +
        originLength +
        destinationLength +
        payloadLength;
    if (expected != bytes.length) {
      throw const BleProtocolException(
        'Routing envelope length does not match header',
      );
    }

    var offset = headerLength;
    String readString(int length, String label) {
      if (length == 0) {
        throw BleProtocolException('Routing envelope $label is empty');
      }
      final end = offset + length;
      final String value;
      try {
        value = utf8.decode(bytes.sublist(offset, end), allowMalformed: false);
      } on FormatException {
        throw BleProtocolException(
          'Routing envelope $label is not valid UTF-8',
        );
      }
      offset = end;
      return value;
    }

    final envelopeId = readString(envelopeIdLength, 'envelope id');
    final originDeviceId = readString(originLength, 'origin id');
    final destinationDeviceId = readString(destinationLength, 'destination id');
    final payload = Uint8List.fromList(
      bytes.sublist(offset, offset + payloadLength),
    );

    final envelope = BleRoutingEnvelope(
      envelopeId: envelopeId,
      envelopeType: envelopeType,
      originDeviceId: originDeviceId,
      destinationDeviceId: destinationDeviceId,
      createdAt: DateTime.fromMicrosecondsSinceEpoch(
        createdSeconds * Duration.microsecondsPerSecond,
        isUtc: true,
      ),
      expiresAt: DateTime.fromMicrosecondsSinceEpoch(
        expiresSeconds * Duration.microsecondsPerSecond,
        isUtc: true,
      ),
      hopLimit: hopLimit,
      hopCount: hopCount,
      payload: payload,
    );
    envelope._validate(forEncode: false);
    return envelope;
  }
}
