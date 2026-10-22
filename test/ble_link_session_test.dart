import 'dart:async';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two sessions complete HELLO and exchange a message with ACK', () async {
    final pair = _SessionPair();
    await pair.start();

    expect(pair.sessionA.linkInfo?.deviceId, 'device-b');
    expect(pair.sessionB.linkInfo?.deviceId, 'device-a');
    expect(pair.sessionA.isReady, isTrue);
    expect(pair.sessionB.isReady, isTrue);

    final result = await pair.sessionA.sendMessage(_message());

    expect(result, BleAckResult.stored);
    expect(pair.receivedOnB, hasLength(1));
    expect(pair.receivedOnB.single.content, 'Hello from A');
  });

  test(
    'duplicate delivery is acknowledged without a second visible insert',
    () async {
      final pair = _SessionPair(duplicateAfterFirst: true);
      await pair.start();

      expect(await pair.sessionA.sendMessage(_message()), BleAckResult.stored);
      expect(
        await pair.sessionA.sendMessage(_message()),
        BleAckResult.duplicate,
      );

      expect(pair.receivedOnB, hasLength(2));
      expect(pair.visibleMessagesOnB, 1);
    },
  );

  test(
    'acknowledgement timeout is reported and the link stays usable',
    () async {
      final pair = _SessionPair(
        ackPolicyA: const BleAckPolicy(
          baseTimeout: Duration(milliseconds: 5),
          perKilobyte: Duration.zero,
          perFrame: Duration.zero,
        ),
        deliveryDelay: const Duration(milliseconds: 80),
      );
      await pair.start();

      await expectLater(
        pair.sessionA.sendMessage(_message()),
        throwsA(isA<BleAckTimeoutException>()),
      );
      expect(pair.sessionA.isReady, isTrue);
    },
  );

  test('rejects a HELLO for a blocked peer and closes the link', () async {
    final pair = _SessionPair(blockedPeer: true);

    await expectLater(pair.start(), throwsA(anything));
    expect(pair.sessionA.isReady, isFalse);
    expect(pair.sessionB.isReady, isFalse);
  });

  test(
    'approval-pending rejection is distinguishable from a final rejection',
    () async {
      final pair = _SessionPair(approvalPending: true);
      await pair.start();

      await expectLater(
        pair.sessionA.sendMessage(_message()),
        throwsA(isA<BleApprovalPendingException>()),
      );
      expect(pair.sessionA.isReady, isTrue);
    },
  );

  test('send after close fails instead of pretending delivery', () async {
    final pair = _SessionPair();
    await pair.start();
    await pair.sessionA.close();
    await pair.sessionB.close();

    await expectLater(
      pair.sessionA.sendMessage(_message()),
      throwsA(isA<BleLinkClosedException>()),
    );
  });
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

class _SessionPair {
  _SessionPair({
    this.duplicateAfterFirst = false,
    this.blockedPeer = false,
    this.approvalPending = false,
    this.deliveryDelay = Duration.zero,
    BleAckPolicy ackPolicyA = const BleAckPolicy(),
  }) {
    final transportA = _FakeTransport(64);
    final transportB = _FakeTransport(48);
    transportA.peer = transportB;
    transportB.peer = transportA;

    sessionA = BleLinkSession(
      transport: transportA,
      identity: _identity('device-a', 'Alice'),
      onHello: (hello) async {
        if (blockedPeer && hello.deviceId == 'device-b') {
          throw const BleLinkException('Peer is blocked');
        }
      },
      onMessage: (payload) async => BleAckResult.stored,
      ackPolicy: ackPolicyA,
      transferIdFactory: () => 1,
    );

    sessionB = BleLinkSession(
      transport: transportB,
      identity: _identity('device-b', 'Bob'),
      onHello: (hello) async {
        if (blockedPeer && hello.deviceId == 'device-a') {
          throw const BleLinkException('Peer is blocked');
        }
      },
      onMessage: (payload) async {
        receivedOnB.add(payload);
        await Future<void>.delayed(deliveryDelay);
        if (approvalPending) {
          throw const BleLinkException(BleProtocol.approvalPendingReason);
        }
        if (duplicateAfterFirst && receivedOnB.length > 1) {
          return BleAckResult.duplicate;
        }
        visibleMessagesOnB++;
        return BleAckResult.stored;
      },
      transferIdFactory: () => 2,
      onClosed: (error) {},
    );
  }

  final bool duplicateAfterFirst;
  final bool blockedPeer;
  final bool approvalPending;
  final Duration deliveryDelay;
  final List<BleMessagePayload> receivedOnB = [];
  int visibleMessagesOnB = 0;
  late final BleLinkSession sessionA;
  late final BleLinkSession sessionB;

  Future<void> start() async {
    await Future.wait([sessionA.start(), sessionB.start()]);
  }
}

Identity _identity(String id, String name) {
  return Identity(deviceId: id, displayName: name);
}

class _FakeTransport implements BleTransport {
  _FakeTransport(this.maximumWriteLength);

  @override
  final int maximumWriteLength;

  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  _FakeTransport? peer;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> write(Uint8List value) async {
    if (_closed || peer == null || peer!._closed) {
      throw const BleLinkException('Transport is closed');
    }
    await Future<void>.delayed(Duration.zero);
    peer!._incoming.add(Uint8List.fromList(value));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}
