import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';

enum BleSessionState { idle, handshaking, ready, closed }

class BleLinkClosedException implements Exception {
  const BleLinkClosedException([this.message = 'BLE link closed']);

  final String message;

  @override
  String toString() => 'BleLinkClosedException: $message';
}

class BleAckTimeoutException implements Exception {
  const BleAckTimeoutException(this.messageId, this.timeout);

  final String messageId;
  final Duration timeout;

  @override
  String toString() =>
      'BleAckTimeoutException: no acknowledgement for $messageId within '
      '${timeout.inMilliseconds} ms';
}

class BleHelloRejectedException implements Exception {
  const BleHelloRejectedException(this.message);

  final String message;

  @override
  String toString() => 'BleHelloRejectedException: $message';
}

class BleAckPolicy {
  const BleAckPolicy({
    this.baseTimeout = const Duration(seconds: 10),
    this.perKilobyte = const Duration(seconds: 1),
    this.perFrame = const Duration(milliseconds: 20),
  });

  final Duration baseTimeout;
  final Duration perKilobyte;
  final Duration perFrame;

  Duration timeoutFor({required int bytes, required int frameCount}) {
    final kilobytes = (bytes / 1024).ceil();
    return baseTimeout + perKilobyte * kilobytes + perFrame * frameCount;
  }
}

class BleLinkSession {
  BleLinkSession({
    required this.transport,
    required this.identity,
    required this.onHello,
    required this.onMessage,
    this.onClosed,
    this.ackPolicy = const BleAckPolicy(),
    this.handshakeTimeout = const Duration(seconds: 15),
    int Function()? transferIdFactory,
  }) : _transferIdFactory =
           transferIdFactory ?? (() => 1 + Random.secure().nextInt(0xffff));

  final BleTransport transport;
  final Identity identity;
  final Future<void> Function(BleHello hello) onHello;
  final Future<BleAckResult> Function(BleMessagePayload message) onMessage;
  final void Function(Object? error)? onClosed;
  final BleAckPolicy ackPolicy;
  final Duration handshakeTimeout;
  final int Function() _transferIdFactory;

  final BleTransferAssembler _assembler = BleTransferAssembler();
  final Map<String, Completer<BleAckResult>> _pendingAcks = {};
  final Completer<BleHello> _helloCompleter = Completer<BleHello>();

  StreamSubscription<Uint8List>? _subscription;
  Future<void> _txTail = Future<void>.value();
  Future<void> _rxTail = Future<void>.value();
  BleSessionState _state = BleSessionState.idle;
  BleHello? _hello;
  Object? _closeError;
  bool _closed = false;

  BleSessionState get state => _state;
  BleHello? get linkInfo => _hello;
  bool get isReady => _state == BleSessionState.ready;

  Future<BleHello> start() async {
    if (_state != BleSessionState.idle) {
      throw const BleLinkException('BLE session has already been started');
    }
    _state = BleSessionState.handshaking;
    _subscription = transport.incoming.listen(
      _queueIncoming,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(close(error));
      },
      onDone: () {
        unawaited(close(const BleLinkClosedException()));
      },
    );

    try {
      final hello = BleHello(
        deviceId: identity.deviceId,
        displayName: identity.displayName,
      );
      await _enqueue(() async {
        await _writeTransfer(BleTransferKind.hello, hello.encode());
      });
      final remote = await _helloCompleter.future.timeout(handshakeTimeout);
      _hello = remote;
      _state = BleSessionState.ready;
      return remote;
    } catch (error) {
      await close(error);
      rethrow;
    }
  }

  Future<BleAckResult> sendMessage(
    Message message, {
    Future<void> Function()? onTransmitted,
  }) async {
    if (!isReady) {
      throw const BleLinkClosedException('BLE link is not ready');
    }
    final remote = _hello;
    if (remote == null || message.receiverId != remote.deviceId) {
      throw const BleLinkException('Message receiver does not match the link');
    }
    if (message.isEncrypted) {
      throw const BleLinkException(
        'Encrypted messages are not supported in Phase 2',
      );
    }
    if (_pendingAcks.containsKey(message.messageId)) {
      throw BleLinkException(
        'Message ${message.messageId} is already awaiting acknowledgement',
      );
    }

    final contentBytes = _utf8Length(message.content);
    if (contentBytes > BleProtocol.maxMessageContentBytes) {
      throw const BleLinkException('Message content is too large');
    }
    final payload = BleMessagePayload(
      metadata: BleMessageMetadata(
        messageId: message.messageId,
        senderId: message.senderId,
        receiverId: message.receiverId,
        messageType: message.messageType.name,
        timestamp: message.timestamp,
        ttl: message.ttl,
        contentLength: contentBytes,
        isEncrypted: message.isEncrypted,
      ),
      content: message.content,
    ).encode();

    final frames = BleTransferCodec.fragment(
      kind: BleTransferKind.message,
      payload: payload,
      maxWriteLength: transport.maximumWriteLength,
      transferId: _nextTransferId(),
    );
    final timeout = ackPolicy.timeoutFor(
      bytes: payload.length,
      frameCount: frames.length,
    );
    final completer = Completer<BleAckResult>();
    _pendingAcks[message.messageId] = completer;

    try {
      await _enqueue(() async {
        for (final frame in frames) {
          await transport.write(frame);
        }
      });
      await onTransmitted?.call();
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw BleAckTimeoutException(message.messageId, timeout);
    } finally {
      _pendingAcks.remove(message.messageId);
    }
  }

  Future<void> close([Object? error]) async {
    if (_closed) return;
    _closed = true;
    _state = BleSessionState.closed;
    _closeError = error;
    await _subscription?.cancel();
    _subscription = null;
    if (!_helloCompleter.isCompleted) {
      _helloCompleter.completeError(error ?? const BleLinkClosedException());
    }
    for (final completer in _pendingAcks.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          error is BleLinkClosedException
              ? error
              : BleLinkClosedException(error?.toString() ?? 'BLE link closed'),
        );
      }
    }
    _pendingAcks.clear();
    try {
      await transport.close();
    } catch (_) {
      // The native connection may already be gone.
    }
    onClosed?.call(_closeError);
  }

  void _queueIncoming(Uint8List bytes) {
    _rxTail = _rxTail.then((_) async {
      if (_closed) return;
      try {
        final frame = BleFrame.decode(bytes);
        final transfer = _assembler.add(frame);
        if (transfer != null) {
          await _handleTransfer(transfer);
        }
      } catch (error) {
        await close(error);
      }
    });
  }

  Future<void> _handleTransfer(BleTransfer transfer) async {
    switch (transfer.kind) {
      case BleTransferKind.hello:
        await _handleHello(transfer.payload);
      case BleTransferKind.message:
        await _handleMessage(transfer.payload);
      case BleTransferKind.acknowledgement:
        await _handleAcknowledgement(transfer.payload);
      case BleTransferKind.error:
        final error = BleErrorPayload.decode(transfer.payload);
        await close(BleLinkException('${error.code}: ${error.message}'));
    }
  }

  Future<void> _handleHello(Uint8List bytes) async {
    if (_hello != null) {
      throw const BleProtocolException('Duplicate HELLO');
    }
    final hello = BleHello.decode(bytes);
    hello.validate(localDeviceId: identity.deviceId);
    try {
      await onHello(hello);
    } catch (error) {
      await _sendError('hello_rejected', error.toString());
      throw BleHelloRejectedException(error.toString());
    }
    if (!_helloCompleter.isCompleted) {
      _helloCompleter.complete(hello);
    }
  }

  Future<void> _handleMessage(Uint8List bytes) async {
    if (!isReady) {
      throw const BleProtocolException(
        'Message received before HELLO completed',
      );
    }
    BleMessagePayload message;
    try {
      message = BleMessagePayload.decode(bytes);
    } on BleProtocolException {
      rethrow;
    }

    BleAckResult result;
    String? reason;
    try {
      result = await onMessage(message);
    } catch (error) {
      result = BleAckResult.rejected;
      reason = error.toString();
    }
    final ack = BleAck(
      messageId: message.metadata.messageId,
      result: result,
      reason: reason,
    );
    await _enqueue(() async {
      await _writeTransfer(BleTransferKind.acknowledgement, ack.encode());
    });
  }

  Future<void> _handleAcknowledgement(Uint8List bytes) async {
    final ack = BleAck.decode(bytes);
    final completer = _pendingAcks.remove(ack.messageId);
    if (completer == null || completer.isCompleted) return;
    completer.complete(ack.result);
  }

  Future<void> _sendError(String code, String message) async {
    try {
      final payload = BleErrorPayload(code: code, message: message).encode();
      await _enqueue(() async {
        await _writeTransfer(BleTransferKind.error, payload);
      });
    } catch (_) {
      // The link is already unusable; closing is the only remaining action.
    }
  }

  Future<void> _writeTransfer(BleTransferKind kind, Uint8List payload) async {
    final frames = BleTransferCodec.fragment(
      kind: kind,
      payload: payload,
      maxWriteLength: transport.maximumWriteLength,
      transferId: _nextTransferId(),
    );
    for (final frame in frames) {
      await transport.write(frame);
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _txTail.then((_) => action());
    _txTail = next.catchError((Object _) {});
    return next;
  }

  int _nextTransferId() {
    final value = _transferIdFactory();
    if (value < 0 || value > 0xffff) {
      throw const BleLinkException('Invalid transfer id');
    }
    return value;
  }

  int _utf8Length(String value) {
    var length = 0;
    for (final rune in value.runes) {
      if (rune <= 0x7f) {
        length += 1;
      } else if (rune <= 0x7ff) {
        length += 2;
      } else if (rune <= 0xffff) {
        length += 3;
      } else {
        length += 4;
      }
    }
    return length;
  }
}
