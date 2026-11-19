import 'package:sqflite/sqflite.dart';
import 'package:bechat/core/utils/timestamp_utils.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/models/relay_queue_entry.dart';

/// Durable storage for multi-hop routing: the dedup ledger (`seen_messages`)
/// and the parked-envelope queue (`relay_queue`).
///
/// Storage only. Nothing here forwards, schedules or delivers anything —
/// relay activation is a later phase. Existing outbox delivery is untouched.
class RoutingRepository {
  RoutingRepository({Future<Database> Function()? database})
    : _openDatabase = database ?? (() => DatabaseHelper.database);

  final Future<Database> Function() _openDatabase;

  Future<Database> get _db => _openDatabase();

  /// Records [envelopeId] in the dedup ledger.
  ///
  /// Returns `true` when this is the first sighting (the row was inserted) and
  /// `false` when the id was already recorded — the primary key plus
  /// [ConflictAlgorithm.ignore] guarantee no duplicate rows, so a relay can
  /// treat `false` as "already handled, drop the copy".
  ///
  /// An existing row is left untouched, including its original
  /// [firstSeenAt]: first-seen means first-seen.
  Future<bool> recordSeen(String envelopeId, {DateTime? expiresAt}) async {
    final db = await _db;
    final now = TimestampUtils.nowUtcIso8601();
    final expires = TimestampUtils.toUtcIso8601(
      expiresAt ?? DateTime.now().toUtc().add(const Duration(days: 7)),
    );
    return db.transaction((txn) async {
      final existing = await txn.query(
        'seen_messages',
        columns: ['envelope_id'],
        where: 'envelope_id = ?',
        whereArgs: [envelopeId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        return false;
      }
      await txn.insert('seen_messages', {
        'envelope_id': envelopeId,
        'first_seen_at': now,
        'expires_at': expires,
      });
      return true;
    });
  }

  /// Whether [envelopeId] has been recorded in the dedup ledger.
  Future<bool> hasSeen(String envelopeId) async {
    final db = await _db;
    final rows = await db.query(
      'seen_messages',
      columns: ['envelope_id'],
      where: 'envelope_id = ?',
      whereArgs: [envelopeId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Removes dedup rows whose expiry is at or before [now].
  ///
  /// Cleanup only: an expired row means a redelivered copy may be accepted
  /// again, which is correct because the original envelope is dead anyway.
  /// Returns the number of rows removed.
  Future<int> deleteExpiredSeen(DateTime now) async {
    final db = await _db;
    return db.delete(
      'seen_messages',
      where: 'expires_at <= ?',
      whereArgs: [TimestampUtils.toUtcIso8601(now)],
    );
  }

  /// Parks [entry] in the relay queue.
  ///
  /// Idempotent: a repeated [RelayQueueEntry.envelopeId] is ignored rather
  /// than duplicated or overwritten, so a crash-and-retry cannot corrupt queue
  /// state. Returns whether the row was actually written.
  Future<bool> enqueue(RelayQueueEntry entry) async {
    final db = await _db;
    final map = entry.toMap();
    final envelopeId = map['envelope_id'] as String;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'relay_queue',
        columns: ['envelope_id'],
        where: 'envelope_id = ?',
        whereArgs: [envelopeId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        return false;
      }
      await txn.insert('relay_queue', map);
      return true;
    });
  }

  /// Records [entry.envelopeId] in the dedup ledger AND parks the envelope in
  /// the relay queue inside ONE transaction, so a crash can never leave a seen
  /// row without its queue row — the state the old two-transaction sequence
  /// produced, which stranded the envelope as a "duplicate" forever with
  /// nothing to retry. Both inserts commit or roll back together; the ledger
  /// row's expiry comes from the envelope itself ([RelayQueueEntry.expiresAt]),
  /// not a default TTL.
  ///
  /// Returns `true` when the envelope was newly accepted. When the id was
  /// already seen, `false` is returned: an existing-but-missing queue row is
  /// repaired from [entry] (the legacy crash window) so its bytes are parked
  /// and recoverable by the future retry loop, but the copy is not treated as
  /// new or re-forwarded here.
  Future<bool> recordSeenAndEnqueue(RelayQueueEntry entry) async {
    final db = await _db;
    final map = entry.toMap();
    final now = TimestampUtils.nowUtcIso8601();
    return db.transaction((txn) async {
      final existing = await txn.query(
        'seen_messages',
        columns: ['envelope_id'],
        where: 'envelope_id = ?',
        whereArgs: [map['envelope_id']],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        await txn.insert(
          'relay_queue',
          map,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        return false;
      }
      await txn.insert('seen_messages', {
        'envelope_id': map['envelope_id'],
        'first_seen_at': now,
        'expires_at': map['expires_at'],
      });
      await txn.insert(
        'relay_queue',
        map,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return true;
    });
  }

  /// Reads one queued envelope by id, or `null` when absent.
  Future<RelayQueueEntry?> findByEnvelopeId(String envelopeId) async {
    final db = await _db;
    final rows = await db.query(
      'relay_queue',
      where: 'envelope_id = ?',
      whereArgs: [envelopeId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return RelayQueueEntry.fromMap(rows.first);
  }

  /// Envelopes a retry sweep may consider at [now]: `queued` or `failed`,
  /// and not expired.
  ///
  /// Expiry is filtered here so no caller can even see a dead envelope —
  /// "expired is never retried" holds whatever state the row is in.
  Future<List<RelayQueueEntry>> findPending(DateTime now) async {
    final db = await _db;
    final rows = await db.query(
      'relay_queue',
      where: "state IN ('queued', 'failed') AND expires_at > ?",
      whereArgs: [TimestampUtils.toUtcIso8601(now)],
      orderBy: 'created_at',
    );
    return rows.map(RelayQueueEntry.fromMap).toList();
  }

  /// All queued envelopes whose expiry is at or before [now] — the entries a
  /// future relay loop must stop trying and clean up.
  Future<List<RelayQueueEntry>> findExpired(DateTime now) async {
    final db = await _db;
    final rows = await db.query(
      'relay_queue',
      where: 'expires_at <= ?',
      whereArgs: [TimestampUtils.toUtcIso8601(now)],
      orderBy: 'expires_at',
    );
    return rows.map(RelayQueueEntry.fromMap).toList();
  }

  /// Updates the delivery-attempt bookkeeping for [envelopeId]: attempts,
  /// chosen next hop, state, and the update timestamp.
  ///
  /// Returns whether a row was updated (false for an unknown envelope).
  Future<bool> updateAttempt(
    String envelopeId, {
    required int attempts,
    String? nextHopDeviceId,
    required RelayQueueState state,
  }) async {
    final db = await _db;
    final rows = await db.update(
      'relay_queue',
      {
        'attempts': attempts,
        'next_hop_device_id': nextHopDeviceId,
        'state': state.name,
        'updated_at': TimestampUtils.nowUtcIso8601(),
      },
      where: 'envelope_id = ?',
      whereArgs: [envelopeId],
    );
    return rows > 0;
  }

  /// Removes queued envelopes whose expiry is at or before [now].
  ///
  /// Returns the number of rows removed.
  Future<int> deleteExpiredQueue(DateTime now) async {
    final db = await _db;
    return db.delete(
      'relay_queue',
      where: 'expires_at <= ?',
      whereArgs: [TimestampUtils.toUtcIso8601(now)],
    );
  }
}
