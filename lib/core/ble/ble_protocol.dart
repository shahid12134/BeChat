import 'dart:convert';
import 'dart:typed_data';

import 'package:bechat/data/models/message.dart';

class BleProtocol {
  BleProtocol._();

  static const int version = 1;
  static const int magic = 0x42;
  static const int frameHeaderLength = 10;
  static const int maxFramePayloadLength = 8192;
  static const int maxTransferLength = 8192;
  static const int maxMessageContentBytes = 4096;
  static const int maxMetadataBytes = 2048;
  static const int maxHelloBytes = 1024;
  static const int maxAckBytes = 1024;
  static const int maxErrorBytes = 1024;

  static const String serviceUuid = '6f1b8e30-6c4a-4f4f-9f4c-424543484100';
  static const String rxCharacteristicUuid =
      '6f1b8e30-6c4a-4f4f-9f4c-424543484101';
  static const String txCharacteristicUuid =
      '6f1b8e30-6c4a-4f4f-9f4c-424543484102';

  static const String approvalPendingReason = 'connection_approval_pending';

  static const String capabilityText = 'text';
  static const String capabilityAck = 'ack';
  static const String capabilityBleForeground = 'ble-foreground';

  /// Secure-capability hint advertised in the plaintext HELLO by peers that
  /// speak the Noise-based secure protocol (protocol v2 frames).
  ///
  /// The HELLO itself is **unauthenticated**: this identifier only says the
  /// peer is able to start a Noise handshake, never who the peer is. Old
  /// decoders tolerate unknown capability strings, so adding it keeps the
  /// transition backward compatible; a HELLO without it means the peer cannot
  /// do secure messaging and must be told to update.
  static const String capabilitySecureNoise = 'noise-v1';

  static const List<String> capabilities = [
    capabilityText,
    capabilityAck,
    capabilityBleForeground,
  ];

  static const int maxMetadataLengthField = 0xffff;
}

class BleProtocolException implements Exception {
  const BleProtocolException(this.message);

  final String message;

  @override
  String toString() => 'BleProtocolException: $message';
}

enum BleFrameType {
  start(1),
  data(2),
  end(3),
  abort(4);

  const BleFrameType(this.value);

  final int value;

  static BleFrameType fromValue(int value) {
    for (final type in values) {
      if (type.value == value) return type;
    }
    throw BleProtocolException('Unknown frame type $value');
  }
}

enum BleTransferKind {
  hello(1),
  message(2),
  acknowledgement(3),
  error(4);

  const BleTransferKind(this.value);

  final int value;

  static BleTransferKind fromValue(int value) {
    for (final kind in values) {
      if (kind.value == value) return kind;
    }
    throw BleProtocolException('Unknown transfer kind $value');
  }
}

class BleFrame {
  const BleFrame({
    required this.type,
    required this.transferId,
    required this.sequence,
    required this.payload,
    this.version = BleProtocol.version,
    this.flags = 0,
  });

  final int version;
  final BleFrameType type;
  final int flags;
  final int transferId;
  final int sequence;
  final Uint8List payload;

  Uint8List encode() {
    if (version != BleProtocol.version) {
      throw const BleProtocolException('Unsupported protocol version');
    }
    if (flags != 0) {
      throw const BleProtocolException('Unsupported frame flags');
    }
    if (transferId < 0 || transferId > 0xffff) {
      throw const BleProtocolException('Invalid transfer id');
    }
    if (sequence < 0 || sequence > 0xffff) {
      throw const BleProtocolException('Invalid sequence number');
    }
    if (payload.length > BleProtocol.maxFramePayloadLength) {
      throw const BleProtocolException('Frame payload is too large');
    }

    final bytes = Uint8List(BleProtocol.frameHeaderLength + payload.length);
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, BleProtocol.magic);
    data.setUint8(1, version);
    data.setUint8(2, type.value);
    data.setUint8(3, flags);
    data.setUint16(4, transferId, Endian.big);
    data.setUint16(6, sequence, Endian.big);
    data.setUint16(8, payload.length, Endian.big);
    bytes.setRange(BleProtocol.frameHeaderLength, bytes.length, payload);
    return bytes;
  }

  static BleFrame decode(Uint8List bytes) {
    if (bytes.length < BleProtocol.frameHeaderLength) {
      throw const BleProtocolException('Truncated frame header');
    }

    final data = ByteData.sublistView(bytes);
    if (data.getUint8(0) != BleProtocol.magic) {
      throw const BleProtocolException('Invalid frame magic');
    }

    final version = data.getUint8(1);
    if (version != BleProtocol.version) {
      throw BleProtocolException('Unsupported protocol version $version');
    }

    final flags = data.getUint8(3);
    if (flags != 0) {
      throw const BleProtocolException('Unsupported frame flags');
    }

    final payloadLength = data.getUint16(8, Endian.big);
    if (payloadLength > BleProtocol.maxFramePayloadLength) {
      throw const BleProtocolException('Frame payload is too large');
    }
    if (bytes.length != BleProtocol.frameHeaderLength + payloadLength) {
      throw const BleProtocolException('Frame length does not match header');
    }

    return BleFrame(
      version: version,
      type: BleFrameType.fromValue(data.getUint8(2)),
      flags: flags,
      transferId: data.getUint16(4, Endian.big),
      sequence: data.getUint16(6, Endian.big),
      payload: Uint8List.fromList(bytes.sublist(BleProtocol.frameHeaderLength)),
    );
  }
}

class BleStartPayload {
  const BleStartPayload({
    required this.kind,
    required this.totalLength,
    required this.checksum,
  });

  final BleTransferKind kind;
  final int totalLength;
  final int checksum;

  static const int encodedLength = 7;

  Uint8List encode() {
    if (totalLength < 0 || totalLength > BleProtocol.maxTransferLength) {
      throw const BleProtocolException('Invalid transfer length');
    }
    final bytes = Uint8List(encodedLength);
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, kind.value);
    data.setUint16(1, totalLength, Endian.big);
    data.setUint32(3, checksum, Endian.big);
    return bytes;
  }

  static BleStartPayload decode(Uint8List bytes) {
    if (bytes.length != encodedLength) {
      throw const BleProtocolException('Invalid start frame payload');
    }
    final data = ByteData.sublistView(bytes);
    final totalLength = data.getUint16(1, Endian.big);
    if (totalLength > BleProtocol.maxTransferLength) {
      throw const BleProtocolException('Transfer is too large');
    }
    return BleStartPayload(
      kind: BleTransferKind.fromValue(data.getUint8(0)),
      totalLength: totalLength,
      checksum: data.getUint32(3, Endian.big),
    );
  }
}

class BleTransfer {
  const BleTransfer({required this.kind, required this.payload});

  final BleTransferKind kind;
  final Uint8List payload;
}

class BleTransferCodec {
  BleTransferCodec._();

  static int checksum(List<int> bytes) {
    var value = 0x811c9dc5;
    for (final byte in bytes) {
      value ^= byte & 0xff;
      value = (value * 0x01000193) & 0xffffffff;
    }
    return value;
  }

  static List<Uint8List> fragment({
    required BleTransferKind kind,
    required Uint8List payload,
    required int maxWriteLength,
    required int transferId,
  }) {
    if (payload.length > BleProtocol.maxTransferLength) {
      throw const BleProtocolException('Transfer is too large');
    }
    final maxFramePayload = maxWriteLength - BleProtocol.frameHeaderLength;
    if (maxFramePayload < 1 ||
        maxWriteLength <
            BleProtocol.frameHeaderLength + BleStartPayload.encodedLength) {
      throw const BleProtocolException(
        'Negotiated BLE write length is too small for the protocol header',
      );
    }

    final frames = <Uint8List>[];
    final start = BleStartPayload(
      kind: kind,
      totalLength: payload.length,
      checksum: checksum(payload),
    );
    frames.add(
      BleFrame(
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
        BleFrame(
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
      throw const BleProtocolException('Transfer requires too many frames');
    }
    frames.add(
      BleFrame(
        type: BleFrameType.end,
        transferId: transferId,
        sequence: sequence,
        payload: Uint8List(0),
      ).encode(),
    );
    return frames;
  }
}

class _IncomingTransfer {
  _IncomingTransfer({
    required this.kind,
    required this.expectedLength,
    required this.expectedChecksum,
  });

  final BleTransferKind kind;
  final int expectedLength;
  final int expectedChecksum;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int nextSequence = 1;

  int get length => _builder.length;
}

class BleTransferAssembler {
  final Map<int, _IncomingTransfer> _transfers = {};

  BleTransfer? add(BleFrame frame) {
    switch (frame.type) {
      case BleFrameType.start:
        return _start(frame);
      case BleFrameType.data:
        return _data(frame);
      case BleFrameType.end:
        return _end(frame);
      case BleFrameType.abort:
        _transfers.remove(frame.transferId);
        throw const BleProtocolException('Transfer aborted by peer');
    }
  }

  BleTransfer? _start(BleFrame frame) {
    if (frame.sequence != 0) {
      throw const BleProtocolException('Start frame must use sequence zero');
    }
    if (!_transfers.containsKey(frame.transferId) && _transfers.length >= 2) {
      throw const BleProtocolException('Too many concurrent transfers');
    }
    if (_transfers.containsKey(frame.transferId)) {
      throw const BleProtocolException('Duplicate start frame');
    }
    final start = BleStartPayload.decode(frame.payload);
    if (start.totalLength > BleProtocol.maxTransferLength) {
      throw const BleProtocolException('Transfer is too large');
    }
    _transfers[frame.transferId] = _IncomingTransfer(
      kind: start.kind,
      expectedLength: start.totalLength,
      expectedChecksum: start.checksum,
    );
    return null;
  }

  BleTransfer? _data(BleFrame frame) {
    final transfer = _transfers[frame.transferId];
    if (transfer == null) {
      throw const BleProtocolException('Data frame without start frame');
    }
    if (frame.sequence != transfer.nextSequence) {
      _transfers.remove(frame.transferId);
      throw const BleProtocolException('Unexpected data sequence');
    }
    if (frame.payload.isEmpty) {
      _transfers.remove(frame.transferId);
      throw const BleProtocolException('Empty data frame');
    }
    if (transfer.length + frame.payload.length > transfer.expectedLength) {
      _transfers.remove(frame.transferId);
      throw const BleProtocolException('Transfer exceeds declared length');
    }
    transfer._builder.add(frame.payload);
    transfer.nextSequence++;
    return null;
  }

  BleTransfer? _end(BleFrame frame) {
    final transfer = _transfers.remove(frame.transferId);
    if (transfer == null) {
      throw const BleProtocolException('End frame without start frame');
    }
    if (frame.sequence != transfer.nextSequence) {
      throw const BleProtocolException('Unexpected end sequence');
    }
    if (frame.payload.isNotEmpty) {
      throw const BleProtocolException('End frame must be empty');
    }
    final payload = transfer._builder.takeBytes();
    if (payload.length != transfer.expectedLength) {
      throw const BleProtocolException('Truncated transfer');
    }
    if (BleTransferCodec.checksum(payload) != transfer.expectedChecksum) {
      throw const BleProtocolException('Transfer checksum mismatch');
    }
    return BleTransfer(kind: transfer.kind, payload: payload);
  }
}

class BleHello {
  const BleHello({
    required this.deviceId,
    required this.displayName,
    this.protocolVersion = BleProtocol.version,
    this.maxMessageSize = BleProtocol.maxMessageContentBytes,
    this.capabilities = BleProtocol.capabilities,
  });

  final int protocolVersion;
  final String deviceId;
  final String displayName;
  final int maxMessageSize;
  final List<String> capabilities;

  Uint8List encode() {
    _validateFields(localDeviceId: null);
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'protocolVersion': protocolVersion,
          'deviceId': deviceId,
          'displayName': displayName,
          'maxMessageSize': maxMessageSize,
          'capabilities': capabilities,
        }),
      ),
    );
    if (bytes.length > BleProtocol.maxHelloBytes) {
      throw const BleProtocolException('HELLO payload is too large');
    }
    return bytes;
  }

  void validate({required String localDeviceId}) {
    _validateFields(localDeviceId: localDeviceId);
  }

  void _validateFields({required String? localDeviceId}) {
    if (protocolVersion != BleProtocol.version) {
      throw const BleProtocolException('Unsupported HELLO protocol version');
    }
    if (deviceId.trim().isEmpty || deviceId.length > 128) {
      throw const BleProtocolException('Invalid HELLO device id');
    }
    if (localDeviceId != null && deviceId == localDeviceId) {
      throw const BleProtocolException('HELLO device id matches local device');
    }
    final name = displayName.trim();
    if (name.isEmpty || name.length > 64) {
      throw const BleProtocolException('Invalid HELLO display name');
    }
    if (maxMessageSize < BleProtocol.maxMessageContentBytes) {
      throw const BleProtocolException('HELLO message size limit is too small');
    }
    final capabilitySet = capabilities.toSet();
    if (!capabilitySet.contains(BleProtocol.capabilityText) ||
        !capabilitySet.contains(BleProtocol.capabilityAck)) {
      throw const BleProtocolException(
        'HELLO does not advertise required capabilities',
      );
    }
    if (capabilities.length > 16 ||
        capabilities.any((value) => value.length > 32)) {
      throw const BleProtocolException('Invalid HELLO capabilities');
    }
  }

  static BleHello decode(Uint8List bytes) {
    if (bytes.length > BleProtocol.maxHelloBytes) {
      throw const BleProtocolException('HELLO payload is too large');
    }
    final decoded = _decodeJsonObject(bytes, 'HELLO');
    final protocolVersion = decoded['protocolVersion'];
    final deviceId = decoded['deviceId'];
    final displayName = decoded['displayName'];
    final maxMessageSize = decoded['maxMessageSize'];
    final rawCapabilities = decoded['capabilities'];
    if (protocolVersion is! int ||
        deviceId is! String ||
        displayName is! String ||
        maxMessageSize is! int ||
        rawCapabilities is! List ||
        rawCapabilities.any((value) => value is! String)) {
      throw const BleProtocolException('Invalid HELLO fields');
    }
    final hello = BleHello(
      protocolVersion: protocolVersion,
      deviceId: deviceId,
      displayName: displayName,
      maxMessageSize: maxMessageSize,
      capabilities: rawCapabilities.cast<String>(),
    );
    hello._validateFields(localDeviceId: null);
    return hello;
  }
}

class BleMessageMetadata {
  const BleMessageMetadata({
    required this.messageId,
    required this.senderId,
    required this.receiverId,
    required this.messageType,
    required this.timestamp,
    required this.ttl,
    required this.contentLength,
    required this.isEncrypted,
    this.protocolVersion = BleProtocol.version,
  });

  final String messageId;
  final String senderId;
  final String receiverId;
  final String messageType;
  final DateTime timestamp;
  final int ttl;
  final int contentLength;
  final bool isEncrypted;
  final int protocolVersion;

  Map<String, dynamic> toJson() => {
    'protocolVersion': protocolVersion,
    'messageId': messageId,
    'senderId': senderId,
    'receiverId': receiverId,
    'messageType': messageType,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'ttl': ttl,
    'contentLength': contentLength,
    'isEncrypted': isEncrypted,
  };

  static BleMessageMetadata fromJson(Map<String, dynamic> json) {
    final protocolVersion = json['protocolVersion'];
    final messageId = json['messageId'];
    final senderId = json['senderId'];
    final receiverId = json['receiverId'];
    final messageType = json['messageType'];
    final rawTimestamp = json['timestamp'];
    final ttl = json['ttl'];
    final contentLength = json['contentLength'];
    final isEncrypted = json['isEncrypted'];
    if (protocolVersion is! int ||
        messageId is! String ||
        senderId is! String ||
        receiverId is! String ||
        messageType is! String ||
        rawTimestamp is! String ||
        ttl is! int ||
        contentLength is! int ||
        isEncrypted is! bool) {
      throw const BleProtocolException('Invalid message metadata fields');
    }
    if (protocolVersion != BleProtocol.version) {
      throw const BleProtocolException('Unsupported message protocol version');
    }
    if (messageId.trim().isEmpty ||
        messageId.length > 128 ||
        senderId.trim().isEmpty ||
        senderId.length > 128 ||
        receiverId.trim().isEmpty ||
        receiverId.length > 128) {
      throw const BleProtocolException('Invalid message identifiers');
    }
    if (messageType != MessageType.text.name) {
      throw const BleProtocolException('Unsupported message type');
    }
    if (isEncrypted) {
      throw const BleProtocolException(
        'Encrypted messages are not supported in Phase 2',
      );
    }
    if (ttl < 0 || ttl > 604800) {
      throw const BleProtocolException('Invalid message TTL');
    }
    if (contentLength < 0 ||
        contentLength > BleProtocol.maxMessageContentBytes) {
      throw const BleProtocolException('Invalid message content length');
    }
    final timestamp = DateTime.tryParse(rawTimestamp);
    if (timestamp == null) {
      throw const BleProtocolException('Invalid message timestamp');
    }
    return BleMessageMetadata(
      protocolVersion: protocolVersion,
      messageId: messageId,
      senderId: senderId,
      receiverId: receiverId,
      messageType: messageType,
      timestamp: timestamp,
      ttl: ttl,
      contentLength: contentLength,
      isEncrypted: isEncrypted,
    );
  }
}

class BleMessagePayload {
  const BleMessagePayload({required this.metadata, required this.content});

  final BleMessageMetadata metadata;
  final String content;

  Uint8List encode() {
    final contentBytes = Uint8List.fromList(utf8.encode(content));
    if (contentBytes.length > BleProtocol.maxMessageContentBytes) {
      throw const BleProtocolException('Message content is too large');
    }
    final metadataWithLength = BleMessageMetadata(
      messageId: metadata.messageId,
      senderId: metadata.senderId,
      receiverId: metadata.receiverId,
      messageType: metadata.messageType,
      timestamp: metadata.timestamp,
      ttl: metadata.ttl,
      contentLength: contentBytes.length,
      isEncrypted: metadata.isEncrypted,
      protocolVersion: metadata.protocolVersion,
    );
    final metadataBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(metadataWithLength.toJson())),
    );
    if (metadataBytes.length > BleProtocol.maxMetadataBytes) {
      throw const BleProtocolException('Message metadata is too large');
    }
    final bytes = Uint8List(2 + metadataBytes.length + contentBytes.length);
    final data = ByteData.sublistView(bytes);
    data.setUint16(0, metadataBytes.length, Endian.big);
    bytes.setRange(2, 2 + metadataBytes.length, metadataBytes);
    bytes.setRange(2 + metadataBytes.length, bytes.length, contentBytes);
    return bytes;
  }

  static BleMessagePayload decode(Uint8List bytes) {
    if (bytes.length < 2) {
      throw const BleProtocolException('Truncated message transfer');
    }
    final data = ByteData.sublistView(bytes);
    final metadataLength = data.getUint16(0, Endian.big);
    if (metadataLength == 0 || metadataLength > BleProtocol.maxMetadataBytes) {
      throw const BleProtocolException('Invalid metadata length');
    }
    if (bytes.length < 2 + metadataLength) {
      throw const BleProtocolException('Truncated message metadata');
    }
    final metadataBytes = bytes.sublist(2, 2 + metadataLength);
    final contentBytes = bytes.sublist(2 + metadataLength);
    final decoded = _decodeJsonObject(metadataBytes, 'message metadata');
    final metadata = BleMessageMetadata.fromJson(decoded);
    if (contentBytes.length != metadata.contentLength) {
      throw const BleProtocolException(
        'Message content length does not match metadata',
      );
    }
    if (contentBytes.length > BleProtocol.maxMessageContentBytes) {
      throw const BleProtocolException('Message content is too large');
    }
    final String content;
    try {
      content = utf8.decode(contentBytes, allowMalformed: false);
    } on FormatException {
      throw const BleProtocolException('Message content is not valid UTF-8');
    }
    return BleMessagePayload(metadata: metadata, content: content);
  }
}

enum BleAckResult {
  stored,
  duplicate,
  rejected;

  static BleAckResult fromName(String value) {
    for (final result in values) {
      if (result.name == value) return result;
    }
    throw BleProtocolException('Unknown acknowledgement result $value');
  }
}

class BleAck {
  const BleAck({required this.messageId, required this.result, this.reason});

  final String messageId;
  final BleAckResult result;
  final String? reason;

  Uint8List encode() {
    if (messageId.trim().isEmpty || messageId.length > 128) {
      throw const BleProtocolException('Invalid acknowledgement message id');
    }
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'messageId': messageId,
          'result': result.name,
          if (reason != null) 'reason': reason,
        }),
      ),
    );
    if (bytes.length > BleProtocol.maxAckBytes) {
      throw const BleProtocolException('Acknowledgement is too large');
    }
    return bytes;
  }

  static BleAck decode(Uint8List bytes) {
    if (bytes.length > BleProtocol.maxAckBytes) {
      throw const BleProtocolException('Acknowledgement is too large');
    }
    final decoded = _decodeJsonObject(bytes, 'acknowledgement');
    final messageId = decoded['messageId'];
    final result = decoded['result'];
    final reason = decoded['reason'];
    if (messageId is! String ||
        result is! String ||
        (reason != null && reason is! String)) {
      throw const BleProtocolException('Invalid acknowledgement fields');
    }
    if (messageId.trim().isEmpty || messageId.length > 128) {
      throw const BleProtocolException('Invalid acknowledgement message id');
    }
    if (reason != null && reason.length > 256) {
      throw const BleProtocolException('Invalid acknowledgement reason');
    }
    return BleAck(
      messageId: messageId,
      result: BleAckResult.fromName(result),
      reason: reason as String?,
    );
  }
}

class BleErrorPayload {
  const BleErrorPayload({required this.code, required this.message});

  final String code;
  final String message;

  Uint8List encode() {
    if (code.trim().isEmpty || code.length > 64) {
      throw const BleProtocolException('Invalid error code');
    }
    if (message.length > 256) {
      throw const BleProtocolException('Invalid error message');
    }
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode({'code': code, 'message': message})),
    );
    if (bytes.length > BleProtocol.maxErrorBytes) {
      throw const BleProtocolException('Error payload is too large');
    }
    return bytes;
  }

  static BleErrorPayload decode(Uint8List bytes) {
    if (bytes.length > BleProtocol.maxErrorBytes) {
      throw const BleProtocolException('Error payload is too large');
    }
    final decoded = _decodeJsonObject(bytes, 'error');
    final code = decoded['code'];
    final message = decoded['message'];
    if (code is! String || message is! String) {
      throw const BleProtocolException('Invalid error fields');
    }
    if (code.trim().isEmpty || code.length > 64 || message.length > 256) {
      throw const BleProtocolException('Invalid error payload');
    }
    return BleErrorPayload(code: code, message: message);
  }
}

Map<String, dynamic> _decodeJsonObject(Uint8List bytes, String label) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  } on FormatException {
    throw BleProtocolException('$label is not valid UTF-8 JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw BleProtocolException('$label must be a JSON object');
  }
  return decoded;
}
