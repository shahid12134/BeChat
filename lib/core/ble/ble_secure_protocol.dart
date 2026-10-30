import 'dart:typed_data';

import 'package:bechat/core/ble/ble_protocol.dart';

/// Secure BLE protocol v2: versioned framing for the Rust Noise session
/// engine.
///
/// This codec is a **pure framing layer**. It never performs cryptography and
/// never parses application data. Every payload it carries is opaque bytes
/// produced or consumed by the Rust Noise engine through the Dart secure
/// session gateway. Authenticated encryption is the engine's job; this layer
/// only bounds, frames, and integrity-checks the transport of those bytes.
///
/// ## Security boundary
///
/// The boundary between legacy plaintext traffic and secure traffic is the
/// **protocol version byte** (`2`) together with an explicit **secure
/// transfer kind**. There is deliberately no `isEncrypted` boolean: a frame is
/// secure if and only if it carries version 2 and one of [BleSecureTransferKind]'s
/// values. A version-1 frame can never be reinterpreted as secure, and a
/// version-2 frame is rejected outright by the legacy v1 `BleFrame` decoder.
///
/// ## What stays in the clear vs. what is encrypted
///
/// The outer secure frame exposes only *transport* metadata required for
/// fragmentation and reassembly: the `transferId`, the frame `sequence`, the
/// `type` (start/data/end), and the transfer `kind`. All *application*
/// metadata — sender and receiver IDs, message ID, timestamp, TTL, content,
/// content length, and any acknowledgement result or reason — lives **inside**
/// the encrypted payload and is never encoded by this codec.
///
/// ## Checksums are not authentication
///
/// Reassembled transfers carry an FNV-1a checksum (reused from the v1
/// [BleTransferCodec]) purely as a cheap corruption detector for the BLE link.
/// A checksum mismatch is a *framing/integrity* failure. A checksum **match is
/// not authentication**: only the Noise engine's AEAD tag authenticates a
/// transport payload. Decoding a secure frame successfully therefore never
/// implies the ciphertext is authentic or decrypted.
///
/// ## Version / downgrade policy
///
/// This decoder accepts **only** version 2 and **only** secure kinds. It
/// rejects version-1 frames, unknown versions, v1 kinds (hello/message/ACK/
/// error) presented as secure, and secure kinds presented at the wrong
/// version. The future secure runtime must additionally refuse all plaintext
/// message and ACK kinds on a confirmed secure link; updated and legacy
/// clients will then require explicit secure-version negotiation and must
/// never silently fall back to plaintext. That runtime wiring is out of scope
/// here: v1 behaviour is untouched.
///
/// ## No `secureError` kind
///
/// There is intentionally no `secureError` transfer kind. Pre-session protocol
/// errors already travel over the v1 `error` kind during plaintext negotiation
/// and are fixed, non-secret, and unauthenticated by design. Once a secure
/// session exists, application-level errors must be carried as an authenticated
/// `secureMessage` through the Noise engine. Adding an unauthenticated secure
/// error kind would open a plaintext channel for post-handshake errors, which
/// is forbidden.
class BleSecureProtocol {
  BleSecureProtocol._();

  /// The secure protocol version carried in the frame header.
  static const int version = 2;

  /// Reuses the v1 magic so both protocols share one framing layer on the wire.
  static const int magic = BleProtocol.magic;

  /// Reuses the v1 10-byte frame header layout.
  static const int frameHeaderLength = BleProtocol.frameHeaderLength;

  /// Reuses the v1 per-frame payload cap.
  static const int maxFramePayloadLength = BleProtocol.maxFramePayloadLength;

  /// Reuses the v1 reassembled-transfer cap so a v2 payload can never consume
  /// more memory than a v1 one.
  static const int maxTransferLength = BleProtocol.maxTransferLength;

  /// The size of the start-frame descriptor (kind + total length + checksum).
  static const int startPayloadLength = 7;

  /// ChaCha20-Poly1305 AEAD tag appended to every Noise transport message.
  static const int noiseAuthenticationTagBytes = 16;

  /// Mirrors the Rust engine's `MAX_HANDSHAKE_MESSAGE_LENGTH` (1024): bounds
  /// every inbound handshake allocation well below the BLE transfer limit.
  static const int maxHandshakeBytes = 1024;

  /// Mirrors the Rust engine's `MAX_TRANSPORT_MESSAGE_LENGTH` (8192), which
  /// already includes the AEAD tag. Matches the BLE `maxTransferLength` so an
  /// encrypted message always fits one reassembled transfer.
  static const int maxTransportBytes = 8192;

  /// Mirrors the Rust engine's `MAX_TRANSPORT_PLAINTEXT_LENGTH` (8176).
  static const int maxTransportPlaintextBytes =
      maxTransportBytes - noiseAuthenticationTagBytes;

  /// The smallest valid Noise transport ciphertext is exactly one AEAD tag.
  static const int minTransportBytes = noiseAuthenticationTagBytes;

  /// The smallest a fragmenting writer may negotiate: room for the frame
  /// header plus the start descriptor.
  static const int minWriteLength = frameHeaderLength + startPayloadLength;

  /// Mirrors the Rust engine's `IDENTITY_PAYLOAD_FORMAT_VERSION` (1): the
  /// version of the AEAD-protected remote identity payload carried inside the
  /// handshake. A remote payload with any other version is not understood and
  /// must fail closed before the link is used.
  static const int identityFormatVersion = 1;

  /// Mirrors the Rust engine's `CAPABILITY_SECURE_TEXT` (0b0000_0001): the
  /// authenticated-capability bit that says the peer can carry application
  /// text over the secure transport. The plaintext HELLO capability strings
  /// and this authenticated bit are separate signals; only this one is bound
  /// to the peer's static key.
  static const int capabilitySecureText = 0x01;
}

/// Transfer kinds carried by secure protocol v2 frames.
///
/// The numeric values are deliberately chosen to sit **above** the v1 kinds
/// (`hello`=1, `message`=2, `acknowledgement`=3, `error`=4) so they can never
/// collide with legacy traffic. V1 kinds are never renumbered, and these v2
/// values are absent from the v1 [BleTransferKind] enum, so the legacy decoder
/// rejects them as unknown.
enum BleSecureTransferKind {
  /// An opaque Noise handshake message (message 1/2/3). Never parsed here.
  secureHandshake(5),

  /// An opaque Noise-encrypted application message. The ciphertext is the
  /// engine's transport output; no application field is exposed out here.
  secureMessage(6),

  /// An opaque Noise-encrypted acknowledgement. The ACK's message ID, result
  /// and reason are inside the ciphertext, never in this frame.
  secureAck(7);

  const BleSecureTransferKind(this.value);

  final int value;

  static BleSecureTransferKind fromValue(int value) {
    for (final kind in values) {
      if (kind.value == value) return kind;
    }
    throw const BleProtocolException('Unknown secure transfer kind');
  }
}

/// A protocol-v2 frame. The byte layout is identical to the v1 [BleFrame]
/// header, but the version byte is fixed to [BleSecureProtocol.version] and a
/// version-1 frame is rejected on decode.
class BleSecureFrame {
  const BleSecureFrame({
    required this.type,
    required this.transferId,
    required this.sequence,
    required this.payload,
    this.flags = 0,
  }) : version = BleSecureProtocol.version;

  /// Always [BleSecureProtocol.version]; set by the constructor.
  final int version;

  /// Reuses the v1 frame-type set (start/data/end/abort): these describe
  /// fragmentation mechanics, not the security boundary.
  final BleFrameType type;

  final int flags;
  final int transferId;
  final int sequence;
  final Uint8List payload;

  Uint8List encode() {
    if (version != BleSecureProtocol.version) {
      throw const BleProtocolException('Unsupported secure protocol version');
    }
    if (flags != 0) {
      throw const BleProtocolException('Unsupported secure frame flags');
    }
    if (transferId < 0 || transferId > 0xffff) {
      throw const BleProtocolException('Invalid secure transfer id');
    }
    if (sequence < 0 || sequence > 0xffff) {
      throw const BleProtocolException('Invalid secure sequence number');
    }
    if (payload.length > BleSecureProtocol.maxFramePayloadLength) {
      throw const BleProtocolException('Secure frame payload is too large');
    }

    final bytes = Uint8List(
      BleSecureProtocol.frameHeaderLength + payload.length,
    );
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, BleSecureProtocol.magic);
    data.setUint8(1, version);
    data.setUint8(2, type.value);
    data.setUint8(3, flags);
    data.setUint16(4, transferId, Endian.big);
    data.setUint16(6, sequence, Endian.big);
    data.setUint16(8, payload.length, Endian.big);
    bytes.setRange(BleSecureProtocol.frameHeaderLength, bytes.length, payload);
    return bytes;
  }

  static BleSecureFrame decode(Uint8List bytes) {
    if (bytes.length < BleSecureProtocol.frameHeaderLength) {
      throw const BleProtocolException('Truncated secure frame header');
    }

    final data = ByteData.sublistView(bytes);
    if (data.getUint8(0) != BleSecureProtocol.magic) {
      throw const BleProtocolException('Invalid secure frame magic');
    }

    final version = data.getUint8(1);
    if (version != BleSecureProtocol.version) {
      // Reject version 1 and every other version: no silent downgrade and no
      // reinterpretation of legacy traffic as secure.
      throw const BleProtocolException('Unsupported secure protocol version');
    }

    final flags = data.getUint8(3);
    if (flags != 0) {
      throw const BleProtocolException('Unsupported secure frame flags');
    }

    final payloadLength = data.getUint16(8, Endian.big);
    if (payloadLength > BleSecureProtocol.maxFramePayloadLength) {
      throw const BleProtocolException('Secure frame payload is too large');
    }
    if (bytes.length != BleSecureProtocol.frameHeaderLength + payloadLength) {
      throw const BleProtocolException(
        'Secure frame length does not match header',
      );
    }

    return BleSecureFrame(
      type: BleFrameType.fromValue(data.getUint8(2)),
      flags: flags,
      transferId: data.getUint16(4, Endian.big),
      sequence: data.getUint16(6, Endian.big),
      payload: Uint8List.fromList(
        bytes.sublist(BleSecureProtocol.frameHeaderLength),
      ),
    );
  }
}

/// The start descriptor of a v2 transfer: which secure kind, how many bytes
/// total, and the FNV-1a corruption checksum. It carries no application field.
class BleSecureStartPayload {
  const BleSecureStartPayload({
    required this.kind,
    required this.totalLength,
    required this.checksum,
  });

  final BleSecureTransferKind kind;
  final int totalLength;
  final int checksum;

  static const int encodedLength = BleSecureProtocol.startPayloadLength;

  Uint8List encode() {
    if (totalLength < 0 || totalLength > BleSecureProtocol.maxTransferLength) {
      throw const BleProtocolException('Invalid secure transfer length');
    }
    final bytes = Uint8List(encodedLength);
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, kind.value);
    data.setUint16(1, totalLength, Endian.big);
    data.setUint32(3, checksum, Endian.big);
    return bytes;
  }

  static BleSecureStartPayload decode(Uint8List bytes) {
    if (bytes.length != encodedLength) {
      throw const BleProtocolException('Invalid secure start frame payload');
    }
    final data = ByteData.sublistView(bytes);
    final totalLength = data.getUint16(1, Endian.big);
    if (totalLength > BleSecureProtocol.maxTransferLength) {
      throw const BleProtocolException('Secure transfer is too large');
    }
    return BleSecureStartPayload(
      kind: BleSecureTransferKind.fromValue(data.getUint8(0)),
      totalLength: totalLength,
      checksum: data.getUint32(3, Endian.big),
    );
  }
}

/// A reassembled secure transfer: a secure [kind] plus an **opaque** payload.
///
/// The payload is Noise bytes. Decoding this transfer never decrypts it; the
/// secure runtime must pass [payload] to the Noise engine (via the Dart
/// gateway) to obtain plaintext. A non-null [BleSecureTransfer] therefore
/// means only "framing completed", never "message authenticated".
class BleSecureTransfer {
  const BleSecureTransfer({required this.kind, required this.payload});

  final BleSecureTransferKind kind;
  final Uint8List payload;
}

/// Fragmentation and reassembly for secure protocol v2, mirroring the v1
/// [BleTransferCodec]/[BleTransferAssembler] bounds (FNV-1a checksum, at most
/// two concurrent transfers, strict sequence ordering) so a v2 payload can
/// never bypass the memory limits that protect v1.
class BleSecureTransferCodec {
  BleSecureTransferCodec._();

  /// Reuses the v1 FNV-1a checksum: a cheap corruption detector, not
  /// authentication.
  static int checksum(List<int> bytes) => BleTransferCodec.checksum(bytes);

  /// Enforces the per-kind size bound **before** any allocation or
  /// reassembly. Handshake payloads are opaque Noise messages up to
  /// [BleSecureProtocol.maxHandshakeBytes]; transport (message/ACK) payloads
  /// are Noise ciphertext between [BleSecureProtocol.minTransportBytes] and
  /// [BleSecureProtocol.maxTransportBytes].
  static void validatePayload(BleSecureTransferKind kind, Uint8List payload) {
    switch (kind) {
      case BleSecureTransferKind.secureHandshake:
        if (payload.isEmpty) {
          throw const BleProtocolException('Secure handshake payload is empty');
        }
        if (payload.length > BleSecureProtocol.maxHandshakeBytes) {
          throw const BleProtocolException(
            'Secure handshake payload is too large',
          );
        }
      case BleSecureTransferKind.secureMessage:
      case BleSecureTransferKind.secureAck:
        if (payload.length < BleSecureProtocol.minTransportBytes) {
          throw const BleProtocolException(
            'Secure transport payload is smaller than the authentication tag',
          );
        }
        if (payload.length > BleSecureProtocol.maxTransportBytes) {
          throw const BleProtocolException(
            'Secure transport payload is too large',
          );
        }
    }
  }

  /// Fragments one opaque secure payload into v2 frames after validating its
  /// size against [kind]'s bound.
  static List<Uint8List> fragment({
    required BleSecureTransferKind kind,
    required Uint8List payload,
    required int maxWriteLength,
    required int transferId,
  }) {
    validatePayload(kind, payload);
    if (payload.length > BleSecureProtocol.maxTransferLength) {
      throw const BleProtocolException('Secure transfer is too large');
    }
    final maxFramePayload =
        maxWriteLength - BleSecureProtocol.frameHeaderLength;
    if (maxFramePayload < 1 ||
        maxWriteLength < BleSecureProtocol.minWriteLength) {
      throw const BleProtocolException(
        'Negotiated BLE write length is too small for the secure header',
      );
    }

    final frames = <Uint8List>[];
    final start = BleSecureStartPayload(
      kind: kind,
      totalLength: payload.length,
      checksum: checksum(payload),
    );
    frames.add(
      BleSecureFrame(
        type: BleFrameType.start,
        transferId: transferId,
        sequence: 0,
        payload: start.encode(),
      ).encode(),
    );

    var sequence = 1;
    var offset = 0;
    while (offset < payload.length) {
      final end = (offset + maxFramePayload).clamp(0, payload.length);
      final chunk = Uint8List.fromList(payload.sublist(offset, end));
      frames.add(
        BleSecureFrame(
          type: BleFrameType.data,
          transferId: transferId,
          sequence: sequence,
          payload: chunk,
        ).encode(),
      );
      sequence++;
      offset = end;
    }

    if (sequence > 0xffff) {
      throw const BleProtocolException(
        'Secure transfer requires too many frames',
      );
    }
    frames.add(
      BleSecureFrame(
        type: BleFrameType.end,
        transferId: transferId,
        sequence: sequence,
        payload: Uint8List(0),
      ).encode(),
    );
    return frames;
  }
}

class _IncomingSecureTransfer {
  _IncomingSecureTransfer({
    required this.kind,
    required this.expectedLength,
    required this.expectedChecksum,
  });

  final BleSecureTransferKind kind;
  final int expectedLength;
  final int expectedChecksum;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int nextSequence = 1;

  int get length => _builder.length;
}

/// Reassembles v2 frames into a [BleSecureTransfer], enforcing the same bounds
/// as the v1 assembler: strict start/data/end ordering, at most two concurrent
/// transfers, a declared-length cap, and a final FNV-1a corruption check. It
/// returns the payload **opaque**; authentication happens in the Noise engine.
class BleSecureTransferAssembler {
  final Map<int, _IncomingSecureTransfer> _transfers = {};

  BleSecureTransfer? add(BleSecureFrame frame) {
    switch (frame.type) {
      case BleFrameType.start:
        return _start(frame);
      case BleFrameType.data:
        return _data(frame);
      case BleFrameType.end:
        return _end(frame);
      case BleFrameType.abort:
        _transfers.remove(frame.transferId);
        throw const BleProtocolException('Secure transfer aborted by peer');
    }
  }

  BleSecureTransfer? _start(BleSecureFrame frame) {
    if (frame.sequence != 0) {
      throw const BleProtocolException(
        'Secure start frame must use sequence zero',
      );
    }
    if (!_transfers.containsKey(frame.transferId) && _transfers.length >= 2) {
      throw const BleProtocolException('Too many concurrent secure transfers');
    }
    if (_transfers.containsKey(frame.transferId)) {
      throw const BleProtocolException('Duplicate secure start frame');
    }
    final start = BleSecureStartPayload.decode(frame.payload);
    if (start.totalLength > BleSecureProtocol.maxTransferLength) {
      throw const BleProtocolException('Secure transfer is too large');
    }
    _transfers[frame.transferId] = _IncomingSecureTransfer(
      kind: start.kind,
      expectedLength: start.totalLength,
      expectedChecksum: start.checksum,
    );
    return null;
  }

  BleSecureTransfer? _data(BleSecureFrame frame) {
    final transfer = _transfers[frame.transferId];
    if (transfer == null) {
      throw const BleProtocolException('Secure data frame without start frame');
    }
    if (frame.sequence != transfer.nextSequence) {
      _transfers.remove(frame.transferId);
      throw const BleProtocolException('Unexpected secure data sequence');
    }
    if (frame.payload.isEmpty) {
      _transfers.remove(frame.transferId);
      throw const BleProtocolException('Empty secure data frame');
    }
    if (transfer.length + frame.payload.length > transfer.expectedLength) {
      _transfers.remove(frame.transferId);
      throw const BleProtocolException(
        'Secure transfer exceeds declared length',
      );
    }
    transfer._builder.add(frame.payload);
    transfer.nextSequence++;
    return null;
  }

  BleSecureTransfer? _end(BleSecureFrame frame) {
    final transfer = _transfers.remove(frame.transferId);
    if (transfer == null) {
      throw const BleProtocolException('Secure end frame without start frame');
    }
    if (frame.sequence != transfer.nextSequence) {
      throw const BleProtocolException('Unexpected secure end sequence');
    }
    if (frame.payload.isNotEmpty) {
      throw const BleProtocolException('Secure end frame must be empty');
    }
    final payload = transfer._builder.takeBytes();
    if (payload.length != transfer.expectedLength) {
      throw const BleProtocolException('Truncated secure transfer');
    }
    if (BleSecureTransferCodec.checksum(payload) != transfer.expectedChecksum) {
      throw const BleProtocolException('Secure transfer checksum mismatch');
    }
    return BleSecureTransfer(kind: transfer.kind, payload: payload);
  }
}
