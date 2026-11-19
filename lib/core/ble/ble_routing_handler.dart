import 'dart:async';
import 'dart:math' as math;

import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_routing_envelope.dart';
import 'package:bechat/data/models/relay_queue_entry.dart';
import 'package:bechat/data/repositories/routing_repository.dart';

/// Result of processing a routing envelope.
enum BleRoutingResult {
  /// The envelope was delivered locally to this device.
  delivered,

  /// The envelope was queued for forwarding (persisted before custody ACK).
  queuedForForward,

  /// The envelope was a duplicate (already seen).
  duplicate,

  /// The envelope has expired.
  expired,

  /// The envelope's hop limit was exhausted.
  hopLimitExhausted,

  /// The envelope was rejected (malformed, wrong destination, etc.).
  rejected,
}

/// Handles multi-hop routing envelope processing.
class BleRoutingHandler {
  BleRoutingHandler({
    required RoutingRepository routingRepository,
    required String localDeviceId,
    required Future<(BleRoutingResult, String?)> Function(
      BleRoutingEnvelope envelope,
      String incomingPeerId,
    ) forward,
  })  : _routingRepository = routingRepository,
        _localDeviceId = localDeviceId,
        _forward = forward;

  final RoutingRepository _routingRepository;
  final String _localDeviceId;
  final Future<(BleRoutingResult, String?)> Function(
    BleRoutingEnvelope envelope,
    String incomingPeerId,
  ) _forward;

  /// Envelope ids whose downstream send + bookkeeping currently run, shared
  /// by the initial background forward and the retry sweep so the two can
  /// never send or record the same envelope concurrently.
  final Set<String> _inFlight = {};

  /// Processes a routing envelope received from [incomingPeerId].
  ///
  /// Returns (result, custodyAck). custodyAck is true once the envelope is
  /// durably accepted — stored locally or parked in the relay queue — which is
  /// exactly when the upstream transport ACK is written; it never waits on the
  /// downstream forward. `queuedForForward` means "durably held by this
  /// relay", not "delivered to the final destination".
  ///
  /// [deliver] is passed per call, not stored: the runtime caches this one
  /// handler while the authenticated peer context differs per link.
  Future<(BleRoutingResult, bool)> processEnvelope(
    BleRoutingEnvelope envelope, {
    required String incomingPeerId,
    required Future<BleRoutingResult> Function(
      BleMessagePayload payload,
      String relayedFrom,
    ) deliver,
  }) async {
    // 1. Reject expired envelopes
    if (envelope.isExpiredAt(DateTime.now().toUtc())) {
      return (BleRoutingResult.expired, false);
    }

    // 2. Check if destination is this device
    if (envelope.destinationDeviceId == _localDeviceId) {
      return _deliverLocally(envelope, deliver);
    }

    // 3. Check hop limit
    if (envelope.remainingHops <= 0) {
      return (BleRoutingResult.hopLimitExhausted, false);
    }

    // 4. Dedup + durable custody + background forward (see _forwardEnvelope).
    return _forwardEnvelope(envelope, incomingPeerId);
  }

  /// Delivers the envelope's inner payload through the existing
  /// incoming-message pipeline via [deliver].
  ///
  /// Order is deliver-then-record: the message must be durably stored before
  /// the dedup row is written, so a crash in between loses only the seen row
  /// (an idempotent redelivery), never the message. Seen ⇒ message stored.
  /// Rejected deliveries are never recorded, so a rejected copy does not
  /// poison later retries.
  Future<(BleRoutingResult, bool)> _deliverLocally(
    BleRoutingEnvelope envelope,
    Future<BleRoutingResult> Function(
      BleMessagePayload payload,
      String relayedFrom,
    ) deliver,
  ) async {
    if (await _routingRepository.hasSeen(envelope.envelopeId)) {
      return (BleRoutingResult.duplicate, false);
    }
    // The codec already decoded these bytes during validation, so a wire
    // envelope cannot fail here; the re-decode only guards locally built ones.
    final payload = BleMessagePayload.decode(envelope.payload);
    final result = await deliver(payload, envelope.originDeviceId);
    if (result == BleRoutingResult.rejected) {
      return (result, false);
    }
    await _routingRepository.recordSeen(
      envelope.envelopeId,
      expiresAt: envelope.expiresAt,
    );
    return (result, true);
  }

  /// Persists custody of a forwarded envelope, then forwards asynchronously.
  ///
  /// [RoutingRepository.recordSeenAndEnqueue] writes the dedup row and the
  /// queue row in one transaction; the custody result returns as soon as that
  /// commit succeeds, and the downstream send runs in the background so the
  /// upstream sender never waits for the next hop's ACK budget.
  Future<(BleRoutingResult, bool)> _forwardEnvelope(
    BleRoutingEnvelope envelope,
    String incomingPeerId,
  ) async {
    // remainingHops > 0 was checked above, so forward() cannot throw here.
    final forwarded = envelope.forward();
    final entry = RelayQueueEntry(
      envelopeId: forwarded.envelopeId,
      envelope: forwarded.encode(),
      originDeviceId: forwarded.originDeviceId,
      destinationDeviceId: forwarded.destinationDeviceId,
      expiresAt: forwarded.expiresAt,
      hopLimit: forwarded.hopLimit,
      hopCount: forwarded.hopCount,
      incomingPeerDeviceId: incomingPeerId,
      createdAt: forwarded.createdAt,
      updatedAt: DateTime.now().toUtc(),
      state: RelayQueueState.queued,
    );
    final isNew = await _routingRepository.recordSeenAndEnqueue(entry);
    if (!isNew) {
      return (BleRoutingResult.duplicate, false);
    }
    unawaited(_forwardInBackground(forwarded, entry, incomingPeerId));
    return (BleRoutingResult.queuedForForward, true);
  }

  /// Runs the downstream forward and records its outcome on the queue row.
  ///
  /// Never throws — fire-and-forget, and a failed bookkeeping write must not
  /// surface as an unhandled future error.
  Future<void> _forwardInBackground(
    BleRoutingEnvelope forwarded,
    RelayQueueEntry entry,
    String incomingPeerId,
  ) async {
    // Shared guard with the retry sweep: whoever does not get the envelope
    // skips it entirely, and the holder is the one that records the outcome,
    // so the row can never be sent or written twice concurrently.
    if (!_inFlight.add(entry.envelopeId)) return;
    try {
      final BleRoutingResult result;
      final String? nextHop;
      try {
        (result, nextHop) = await _forward(forwarded, incomingPeerId);
      } catch (_) {
        // Downstream send blew up: park the envelope as failed, keep its bytes.
        await _recordAttempt(entry, RelayQueueState.failed, null);
        return;
      }
      await _recordAttempt(
        entry,
        result == BleRoutingResult.queuedForForward
            ? RelayQueueState.sent
            : RelayQueueState.failed,
        nextHop,
      );
    } finally {
      _inFlight.remove(entry.envelopeId);
    }
  }

  /// One retry sweep over parked envelopes (Phase 3D.2B).
  ///
  /// Re-sends the stored envelope bytes AS-IS — never [BleRoutingEnvelope
  /// .forward] again, so hopCount is never incremented twice — over a
  /// secure-ready next hop chosen by [_forward], which excludes the local
  /// device, the origin and the persisted incoming peer. Per entry:
  ///
  /// * expired rows are cleaned up first and never even seen again;
  /// * rows without a persisted incoming peer (pre-v6) are skipped — without
  ///   the authenticated arrival peer the exclusion set cannot be trusted;
  /// * rows still inside their exponential backoff window are skipped;
  /// * no eligible next hop leaves the row untouched (no attempt burned);
  /// * a stored/duplicate ACK marks it `sent`, a rejection/timeout/disconnect
  ///   marks it `failed` with attempts+1 — the bytes stay for the next sweep.
  ///
  /// [now] is injected so tests can drive the clock. Never throws: sweeps run
  /// fire-and-forget from the runtime, and the next trigger just comes later.
  Future<void> retryPending({required DateTime now}) async {
    try {
      await _routingRepository.deleteExpiredQueue(now);
      for (final candidate in await _routingRepository.findPending(now)) {
        if (!_inFlight.add(candidate.envelopeId)) continue;
        try {
          // Fresh read under the guard: the background forward may have just
          // recorded an outcome that the pending query predates, and a
          // `sent` row must never be sent a second time.
          final entry = await _routingRepository.findByEnvelopeId(
            candidate.envelopeId,
          );
          if (entry == null) continue;
          if (entry.state == RelayQueueState.sent) continue;
          if (!entry.expiresAt.isAfter(now)) continue;
          final incomingPeerId = entry.incomingPeerDeviceId;
          // shortcut: pre-v6 rows have no persisted incoming peer, so
          // origin/incoming exclusion cannot be proven after a restart —
          // they are skipped until expiry cleanup removes them. Upgrade
          // path: none needed (they age out); a one-shot backfill from
          // next-hop history would re-enable them earlier.
          if (incomingPeerId == null || incomingPeerId.isEmpty) continue;
          if (now.isBefore(entry.updatedAt.add(retryBackoff(entry.attempts)))) {
            continue;
          }
          final BleRoutingEnvelope stored;
          try {
            stored = BleRoutingEnvelope.decode(entry.envelope);
          } catch (_) {
            // Unreadable bytes: park as failed so the backoff applies
            // instead of hot-looping on a corrupt row.
            await _recordAttempt(entry, RelayQueueState.failed, null);
            continue;
          }
          final BleRoutingResult result;
          final String? nextHop;
          try {
            (result, nextHop) = await _forward(stored, incomingPeerId);
          } catch (_) {
            await _recordAttempt(entry, RelayQueueState.failed, null);
            continue;
          }
          // null next hop means no eligible link existed: the envelope was
          // never attempted, so the row keeps its state and its backoff.
          if (nextHop == null) continue;
          await _recordAttempt(
            entry,
            result == BleRoutingResult.queuedForForward
                ? RelayQueueState.sent
                : RelayQueueState.failed,
            nextHop,
          );
        } finally {
          _inFlight.remove(candidate.envelopeId);
        }
      }
    } catch (_) {
      // Best-effort background work: a failed sweep just waits for the next
      // trigger (init, a new secure link, or the periodic timer).
    }
  }

  /// Exponential backoff before another attempt: 2^[attempts] seconds from
  /// the row's `updated_at` (stamped by every attempt), capped at 60s —
  /// attempts >= 6 all wait the full minute.
  static Duration retryBackoff(int attempts) =>
      Duration(seconds: math.min(60, 1 << math.max(0, math.min(6, attempts))));

  Future<void> _recordAttempt(
    RelayQueueEntry entry,
    RelayQueueState state,
    String? nextHop,
  ) async {
    try {
      await _routingRepository.updateAttempt(
        entry.envelopeId,
        attempts: entry.attempts + 1,
        nextHopDeviceId: nextHop,
        state: state,
      );
    } catch (_) {
      // Bookkeeping only: the row still holds state=queued with its bytes
      // intact, so the future retry loop can pick it up.
    }
  }
}
