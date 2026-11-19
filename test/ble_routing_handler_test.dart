import 'dart:async';

import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_routing_envelope.dart';
import 'package:bechat/core/ble/ble_routing_handler.dart';
import 'package:bechat/core/utils/timestamp_utils.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/models/relay_queue_entry.dart';
import 'package:bechat/data/repositories/routing_repository.dart';
import 'package:bechat/services/ble/ble_message_store.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

const localId = 'device-local';
const relayId = 'device-relay'; // authenticated immediate relay (incoming peer)
const originId = 'device-origin'; // claimed origin, unverified
const thirdId = 'device-third'; // eligible third-party next hop

const local = Identity(deviceId: localId, displayName: 'Local');
const relayPeer = Peer(
  peerId: relayId,
  displayName: 'Relay',
  deviceName: 'Relay phone',
);

void main() {
  late Database db;
  late RoutingRepository repo;
  late BleMessageStore store;

  var deliverCalls = 0;
  var forwardCalls = 0;

  setUp(() async {
    db = await openTestDatabase();
    repo = RoutingRepository(database: () async => db);
    store = BleMessageStore(database: () async => db);
    deliverCalls = 0;
    forwardCalls = 0;
  });

  tearDown(() async {
    await db.close();
  });

  /// The real incoming pipeline (same handler + store the runtime wires up),
  /// mapping ACK results onto routing results exactly like the runtime does.
  Future<BleRoutingResult> storeDeliver(
    BleMessagePayload payload,
    String relayedFrom,
  ) async {
    deliverCalls++;
    try {
      final incoming = BleIncomingMessageHandler(identity: local, store: store);
      final ack = await incoming.handle(
        payload,
        peer: relayPeer,
        linkedPeerId: relayId,
        relayedFrom: relayedFrom,
      );
      return switch (ack) {
        BleAckResult.stored => BleRoutingResult.delivered,
        BleAckResult.duplicate => BleRoutingResult.duplicate,
        BleAckResult.rejected => BleRoutingResult.rejected,
      };
    } on BleProtocolException {
      return BleRoutingResult.rejected;
    }
  }

  /// A forward that reports a successful downstream send.
  Future<(BleRoutingResult, String?)> okForward(
    BleRoutingEnvelope envelope,
    String incomingPeerId,
  ) async {
    forwardCalls++;
    return (BleRoutingResult.queuedForForward, thirdId);
  }

  BleRoutingHandler handlerWith({
    required Future<(BleRoutingResult, String?)> Function(
      BleRoutingEnvelope envelope,
      String incomingPeerId,
    ) forward,
  }) {
    return BleRoutingHandler(
      routingRepository: repo,
      localDeviceId: localId,
      forward: forward,
    );
  }

  /// Parks a queue row directly, as a failed background forward (or a
  /// previous run) would leave it. Defaults are retry-eligible: live expiry
  /// and an `updated_at` old enough for any backoff window.
  Future<void> seedQueue(
    String envelopeId, {
    RelayQueueState state = RelayQueueState.queued,
    int attempts = 0,
    DateTime? updatedAt,
    DateTime? expiresAt,
  }) async {
    final created = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    await repo.enqueue(
      RelayQueueEntry(
        envelopeId: envelopeId,
        envelope: _envelope(id: envelopeId, destination: thirdId).encode(),
        originDeviceId: originId,
        destinationDeviceId: thirdId,
        incomingPeerDeviceId: relayId,
        expiresAt:
            expiresAt ?? DateTime.now().toUtc().add(const Duration(hours: 1)),
        hopLimit: 5,
        hopCount: 1,
        attempts: attempts,
        state: state,
        createdAt: created,
        updatedAt: updatedAt ?? created,
      ),
    );
  }

  test('local envelope delivery stores the inner message with the relay as '
      'chat context and the claimed origin as sender', () async {
    final routing = handlerWith(forward: okForward);
    final envelope = _envelope();

    final (result, custodyAck) = await routing.processEnvelope(
      envelope,
      incomingPeerId: relayId,
      deliver: storeDeliver,
    );

    expect(result, BleRoutingResult.delivered);
    expect(custodyAck, isTrue);
    expect(deliverCalls, 1);

    final messages = await db.query('messages');
    expect(messages, hasLength(1));
    expect(messages.single['content'], 'Hello');
    expect(messages.single['sender_id'], originId); // claimed, unverified
    expect(messages.single['receiver_id'], localId);

    // The conversation is bound to the authenticated immediate relay, never
    // resolved from the envelope's origin id.
    final chats = await db.query('chats');
    expect(chats.single['peer_id'], relayId);

    // Dedup row recorded with the envelope's own expiry, not a default TTL.
    expect(await repo.hasSeen(envelope.envelopeId), isTrue);
    final seen = await db.query('seen_messages');
    expect(seen.single['expires_at'], TimestampUtils.toUtcIso8601(envelope.expiresAt));
  });

  test('a duplicate envelope is not delivered twice', () async {
    final routing = handlerWith(forward: okForward);
    final envelope = _envelope(id: 'env-dup');

    final (first, _) = await routing.processEnvelope(
      envelope,
      incomingPeerId: relayId,
      deliver: storeDeliver,
    );
    final (second, secondAck) = await routing.processEnvelope(
      envelope,
      incomingPeerId: relayId,
      deliver: storeDeliver,
    );

    expect(first, BleRoutingResult.delivered);
    expect(second, BleRoutingResult.duplicate);
    expect(secondAck, isFalse);
    expect(deliverCalls, 1);
    expect(await db.query('messages'), hasLength(1));
    expect(await repo.hasSeen(envelope.envelopeId), isTrue);
  });

  test('an envelope addressed here but whose inner payload targets another '
      'device is rejected and never stored', () async {
    final routing = handlerWith(forward: okForward);
    final envelope = _envelope(
      id: 'env-wrong-receiver',
      payload: _inner(receiverId: 'device-other'),
    );

    final (result, custodyAck) = await routing.processEnvelope(
      envelope,
      incomingPeerId: relayId,
      deliver: storeDeliver,
    );

    expect(result, BleRoutingResult.rejected);
    expect(custodyAck, isFalse);
    expect(deliverCalls, 1);
    expect(await db.query('messages'), isEmpty);
    expect(await db.query('chats'), isEmpty);
    // A rejected copy must not poison a later valid retry.
    expect(await repo.hasSeen(envelope.envelopeId), isFalse);
  });

  test('duplicate forwarded envelopes are rejected after the first', () async {
    final routing = handlerWith(forward: okForward);
    final envelope = _envelope(id: 'env-fwd', destination: thirdId);

    final (first, firstAck) = await routing.processEnvelope(
      envelope,
      incomingPeerId: relayId,
      deliver: storeDeliver,
    );
    final (second, secondAck) = await routing.processEnvelope(
      envelope,
      incomingPeerId: relayId,
      deliver: storeDeliver,
    );

    expect(first, BleRoutingResult.queuedForForward);
    expect(firstAck, isTrue);
    expect(second, BleRoutingResult.duplicate);
    expect(secondAck, isFalse);
    expect(forwardCalls, 1);

    expect(await repo.hasSeen(envelope.envelopeId), isTrue);
    await pumpUntil(
      () async =>
          (await repo.findByEnvelopeId(envelope.envelopeId))?.state ==
          RelayQueueState.sent,
      reason: 'the single forward was never recorded',
    );
    final row = await repo.findByEnvelopeId(envelope.envelopeId);
    expect(row, isNotNull);
    expect(row!.attempts, 1);
    expect(row.hopCount, 1); // stored with hopCount+1, ready to relay as-is
    expect(row.originDeviceId, originId);
    expect(row.destinationDeviceId, thirdId);
  });

  test('the custody ACK returns without waiting for the downstream ACK',
      () async {
    final gate = Completer<(BleRoutingResult, String?)>();
    final routing = handlerWith(
      forward: (envelope, incomingPeerId) {
        forwardCalls++;
        return gate.future;
      },
    );
    final envelope = _envelope(id: 'env-custody', destination: thirdId);

    // Completes while the downstream send is still parked: custody is the
    // durable persist, not the next hop's ACK.
    final (result, custodyAck) = await routing
        .processEnvelope(
          envelope,
          incomingPeerId: relayId,
          deliver: storeDeliver,
        )
        .timeout(const Duration(seconds: 1));

    expect(result, BleRoutingResult.queuedForForward);
    expect(custodyAck, isTrue);

    final parked = await repo.findByEnvelopeId(envelope.envelopeId);
    expect(parked, isNotNull);
    expect(parked!.state, RelayQueueState.queued);
    expect(parked.attempts, 0);

    gate.complete((BleRoutingResult.queuedForForward, thirdId));
    await pumpUntil(
      () async =>
          (await repo.findByEnvelopeId(envelope.envelopeId))?.state ==
          RelayQueueState.sent,
      reason: 'the downstream success was never recorded',
    );
    final sent = await repo.findByEnvelopeId(envelope.envelopeId);
    expect(sent!.attempts, 1);
    expect(sent.nextHopDeviceId, thirdId);
  });

  test('a downstream failure keeps the envelope parked as failed with its '
      'bytes intact', () async {
    final routing = handlerWith(
      forward: (envelope, incomingPeerId) async {
        forwardCalls++;
        return (BleRoutingResult.rejected, thirdId);
      },
    );
    final envelope = _envelope(id: 'env-fail', destination: thirdId);

    final (result, custodyAck) = await routing.processEnvelope(
      envelope,
      incomingPeerId: relayId,
      deliver: storeDeliver,
    );

    // Custody was already durable, so the upstream result does not flip.
    expect(result, BleRoutingResult.queuedForForward);
    expect(custodyAck, isTrue);

    await pumpUntil(
      () async =>
          (await repo.findByEnvelopeId(envelope.envelopeId))?.state ==
          RelayQueueState.failed,
      reason: 'the failure was never recorded on the queue row',
    );
    final row = await repo.findByEnvelopeId(envelope.envelopeId);
    expect(row, isNotNull);
    expect(row!.attempts, 1);
    expect(row.nextHopDeviceId, thirdId);
    // The parked bytes survive for the future retry loop.
    final stored = BleRoutingEnvelope.decode(row.envelope);
    expect(stored.envelopeId, envelope.envelopeId);
    expect(stored.hopCount, 1);
    expect(stored.destinationDeviceId, thirdId);
  });

  test('a throwing downstream forward is contained and parks the envelope',
      () async {
    final routing = handlerWith(
      forward: (envelope, incomingPeerId) async {
        forwardCalls++;
        throw StateError('downstream blew up');
      },
    );
    final envelope = _envelope(id: 'env-throw', destination: thirdId);

    final (result, _) = await routing.processEnvelope(
      envelope,
      incomingPeerId: relayId,
      deliver: storeDeliver,
    );
    expect(result, BleRoutingResult.queuedForForward);

    // No unhandled future error may escape the fire-and-forget forward;
    // flutter_test fails the test automatically if one does.
    await pumpUntil(
      () async =>
          (await repo.findByEnvelopeId(envelope.envelopeId))?.state ==
          RelayQueueState.failed,
      reason: 'the thrown forward was never recorded',
    );
    expect((await repo.findByEnvelopeId(envelope.envelopeId))!.attempts, 1);
  });

  test('a failed queue insert rolls the seen row back in the same '
      'transaction', () async {
    await db.execute('''
      CREATE TRIGGER fail_queue_insert
      BEFORE INSERT ON relay_queue
      BEGIN
        SELECT RAISE(ABORT, 'queue write blocked');
      END
    ''');
    final routing = handlerWith(forward: okForward);
    final envelope = _envelope(id: 'env-tx', destination: thirdId);

    await expectLater(
      routing.processEnvelope(
        envelope,
        incomingPeerId: relayId,
        deliver: storeDeliver,
      ),
      throwsA(anything),
    );

    // Neither half of the atomic pair survives: no seen row that would drop
    // a redelivered copy as a phantom duplicate, no half-written queue row.
    expect(await repo.hasSeen(envelope.envelopeId), isFalse);
    expect(await repo.findByEnvelopeId(envelope.envelopeId), isNull);
    expect(forwardCalls, 0);
  });

  test('next-hop selection excludes the origin and the incoming peer',
      () {
    expect(
      BleRuntimeController.isForwardCandidate(
        thirdId,
        originId: originId,
        incomingPeerId: relayId,
      ),
      isTrue,
      reason: 'an unrelated secure peer must remain eligible',
    );
    expect(
      BleRuntimeController.isForwardCandidate(
        originId,
        originId: originId,
        incomingPeerId: relayId,
      ),
      isFalse,
      reason: 'never bounce the envelope back to its origin',
    );
    expect(
      BleRuntimeController.isForwardCandidate(
        relayId,
        originId: originId,
        incomingPeerId: relayId,
      ),
      isFalse,
      reason: 'never bounce the envelope back to the peer it came from',
    );
    expect(
      BleRuntimeController.isForwardCandidate(
        null,
        originId: originId,
        incomingPeerId: relayId,
      ),
      isFalse,
      reason: 'an unbound link carries no routable identity',
    );
  });

  test('failed entries retry only after their backoff window has elapsed',
      () async {
    final routing = handlerWith(forward: okForward);
    await seedQueue(
      'env-retry-failed',
      state: RelayQueueState.failed,
      attempts: 1,
      updatedAt: DateTime.now().toUtc(), // failure just recorded: 2s window
    );

    // Inside the 2^1s window: nothing is attempted, nothing changes.
    await routing.retryPending(now: DateTime.now().toUtc());
    expect(forwardCalls, 0);
    final early = await repo.findByEnvelopeId('env-retry-failed');
    expect(early!.state, RelayQueueState.failed);
    expect(early.attempts, 1);

    // Past the window: retried exactly once, recorded sent with attempts+1.
    await routing.retryPending(
      now: DateTime.now().toUtc().add(const Duration(seconds: 5)),
    );
    expect(forwardCalls, 1);
    final retried = await repo.findByEnvelopeId('env-retry-failed');
    expect(retried!.state, RelayQueueState.sent);
    expect(retried.attempts, 2);
    expect(retried.nextHopDeviceId, thirdId);
  });

  test('sent entries are never retried', () async {
    final routing = handlerWith(forward: okForward);
    await seedQueue('env-already-sent', state: RelayQueueState.sent, attempts: 1);

    await routing.retryPending(now: DateTime.now().toUtc());

    expect(forwardCalls, 0);
    final row = await repo.findByEnvelopeId('env-already-sent');
    expect(row!.state, RelayQueueState.sent);
    expect(row.attempts, 1);
  });

  test('expired envelopes are cleaned up and never retried', () async {
    final routing = handlerWith(forward: okForward);
    await seedQueue(
      'env-dead',
      expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    );

    await routing.retryPending(now: DateTime.now().toUtc());

    expect(forwardCalls, 0);
    expect(
      await repo.findByEnvelopeId('env-dead'),
      isNull,
      reason: 'the sweep removes what it refuses to retry',
    );
  });

  test('concurrent retry sweeps never send the same envelope twice', () async {
    final gate = Completer<(BleRoutingResult, String?)>();
    final routing = handlerWith(
      forward: (envelope, incomingPeerId) {
        forwardCalls++;
        return gate.future;
      },
    );
    await seedQueue('env-race');

    final sweeps = Future.wait([
      routing.retryPending(now: DateTime.now().toUtc()),
      routing.retryPending(now: DateTime.now().toUtc()),
    ]);
    await pumpUntil(
      () async => forwardCalls == 1,
      reason: 'the retry sweep never attempted the envelope',
    );
    gate.complete((BleRoutingResult.queuedForForward, thirdId));
    await sweeps;

    // The losing sweep held the same row in its candidate list but could not
    // take the per-envelope guard, so exactly one send ran and one outcome
    // was recorded.
    expect(forwardCalls, 1);
    final row = await repo.findByEnvelopeId('env-race');
    expect(row!.state, RelayQueueState.sent);
    expect(row.attempts, 1);
  });
}

BleMessagePayload _inner({
  String messageId = 'msg-1',
  String senderId = originId,
  String receiverId = localId,
  String content = 'Hello',
}) {
  return BleMessagePayload(
    metadata: BleMessageMetadata(
      messageId: messageId,
      senderId: senderId,
      receiverId: receiverId,
      messageType: MessageType.text.name,
      timestamp: DateTime.utc(2026, 4, 5, 6, 7),
      ttl: 3600,
      contentLength: content.length,
      isEncrypted: false,
    ),
    content: content,
  );
}

BleRoutingEnvelope _envelope({
  String id = 'env-1',
  String destination = localId,
  BleMessagePayload? payload,
  int hopLimit = 5,
}) {
  final created = DateTime.now().toUtc();
  return BleRoutingEnvelope(
    envelopeId: id,
    originDeviceId: originId,
    destinationDeviceId: destination,
    createdAt: created,
    expiresAt: created.add(const Duration(hours: 1)),
    hopLimit: hopLimit,
    hopCount: 0,
    payload: (payload ?? _inner(messageId: 'msg-$id')).encode(),
  );
}

Future<void> pumpUntil(
  Future<bool> Function() condition, {
  required String reason,
}) async {
  for (var i = 0; i < 200; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail(reason);
}
