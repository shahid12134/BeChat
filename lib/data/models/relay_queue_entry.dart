import 'dart:typed_data';

import 'package:bechat/core/utils/timestamp_utils.dart';

/// Lifecycle state of a queued relay envelope.
///
/// Storage only — no forwarding runs yet. `queued` is written on insert;
/// `sent` and `failed` exist so a future relay loop can record its outcome
/// without a schema change.
enum RelayQueueState { queued, sent, failed }

/// One envelope parked in the `relay_queue` table.
///
/// Mirrors the v6 schema 1:1: the opaque envelope bytes plus the routing
/// metadata a future relay needs, denormalized so queue scans never have to
/// decode the blob. Timestamps persist in [TimestampUtils] canonical UTC
/// ISO-8601 form, so expiry range scans are correct lexicographic comparisons.
class RelayQueueEntry {
  const RelayQueueEntry({
    required this.envelopeId,
    required this.envelope,
    required this.originDeviceId,
    required this.destinationDeviceId,
    required this.expiresAt,
    required this.hopLimit,
    required this.hopCount,
    this.incomingPeerDeviceId,
    this.attempts = 0,
    this.nextHopDeviceId,
    this.state = RelayQueueState.queued,
    required this.createdAt,
    required this.updatedAt,
  });

  final String envelopeId;

  /// Encoded [BleRoutingEnvelope] bytes, stored verbatim as a BLOB.
  final Uint8List envelope;
  final String originDeviceId;
  final String destinationDeviceId;
  final DateTime expiresAt;
  final int hopLimit;
  final int hopCount;

  /// The authenticated peer this envelope arrived from, persisted so the
  /// retry loop can still exclude it after a restart (v6). Null for rows
  /// written before v6: those are never retried.
  final String? incomingPeerDeviceId;
  final int attempts;
  final String? nextHopDeviceId;
  final RelayQueueState state;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toMap() {
    return {
      'envelope_id': envelopeId,
      'envelope': envelope,
      'origin_device_id': originDeviceId,
      'destination_device_id': destinationDeviceId,
      'expires_at': TimestampUtils.toUtcIso8601(expiresAt),
      'hop_limit': hopLimit,
      'hop_count': hopCount,
      'incoming_peer_device_id': incomingPeerDeviceId,
      'attempts': attempts,
      'next_hop_device_id': nextHopDeviceId,
      'state': state.name,
      'created_at': TimestampUtils.toUtcIso8601(createdAt),
      'updated_at': TimestampUtils.toUtcIso8601(updatedAt),
    };
  }

  static RelayQueueEntry fromMap(Map<String, Object?> map) {
    return RelayQueueEntry(
      envelopeId: map['envelope_id']! as String,
      envelope: Uint8List.fromList(map['envelope']! as List<int>),
      originDeviceId: map['origin_device_id']! as String,
      destinationDeviceId: map['destination_device_id']! as String,
      expiresAt: DateTime.parse(map['expires_at']! as String),
      hopLimit: map['hop_limit']! as int,
      hopCount: map['hop_count']! as int,
      incomingPeerDeviceId: map['incoming_peer_device_id'] as String?,
      attempts: map['attempts']! as int,
      nextHopDeviceId: map['next_hop_device_id'] as String?,
      state: RelayQueueState.values.firstWhere(
        (value) => value.name == map['state'],
      ),
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: DateTime.parse(map['updated_at']! as String),
    );
  }

  RelayQueueEntry copyWith({
    int? attempts,
    String? nextHopDeviceId,
    RelayQueueState? state,
    DateTime? updatedAt,
  }) {
    return RelayQueueEntry(
      envelopeId: envelopeId,
      envelope: envelope,
      originDeviceId: originDeviceId,
      destinationDeviceId: destinationDeviceId,
      expiresAt: expiresAt,
      hopLimit: hopLimit,
      hopCount: hopCount,
      incomingPeerDeviceId: incomingPeerDeviceId,
      attempts: attempts ?? this.attempts,
      nextHopDeviceId: nextHopDeviceId ?? this.nextHopDeviceId,
      state: state ?? this.state,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
