import 'dart:typed_data';

import 'package:bechat/data/models/relay_queue_entry.dart';
import 'package:bechat/data/repositories/routing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

RelayQueueEntry buildEntry({
  String envelopeId = 'env-1',
  String origin = 'device-a',
  String destination = 'device-b',
  int hopLimit = 5,
  int hopCount = 1,
  DateTime? expiresAt,
  DateTime? createdAt,
}) {
  final created = createdAt ?? DateTime.utc(2026, 6, 1, 10);
  return RelayQueueEntry(
    envelopeId: envelopeId,
    envelope: Uint8List.fromList([0x52, 3, 1, 0]),
    originDeviceId: origin,
    destinationDeviceId: destination,
    expiresAt: expiresAt ?? created.add(const Duration(hours: 1)),
    hopLimit: hopLimit,
    hopCount: hopCount,
    createdAt: created,
    updatedAt: created,
  );
}

void main() {
  late Database db;

  setUp(() async {
    db = await openTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  RoutingRepository repository() {
    return RoutingRepository(database: () async => db);
  }

  group('seen_messages deduplication', () {
    test('records a first sighting and reports it as new', () async {
      final first = await repository().recordSeen('env-1');

      expect(first, isTrue);
      expect(await repository().hasSeen('env-1'), isTrue);
    });

    test('a repeated envelope id is not recorded twice', () async {
      final repo = repository();
      await repo.recordSeen('env-1');
      final second = await repo.recordSeen('env-1');
      final third = await repo.recordSeen('env-1');

      expect(second, isFalse);
      expect(third, isFalse);
      final rows = await db.query(
        'seen_messages',
        where: 'envelope_id = ?',
        whereArgs: ['env-1'],
      );
      expect(rows, hasLength(1));
    });

    test('different envelope ids are tracked independently', () async {
      final repo = repository();
      await repo.recordSeen('env-1');
      await repo.recordSeen('env-2');

      expect(await repo.hasSeen('env-1'), isTrue);
      expect(await repo.hasSeen('env-2'), isTrue);
      expect(await repo.hasSeen('env-3'), isFalse);
    });

    test('first sighting survives a repository reopen', () async {
      final repo = repository();
      await repo.recordSeen('env-persist');

      // A second repository instance over the same database sees the ledger,
      // proving the record is durable and not in-memory state.
      final reopened = RoutingRepository(database: () async => db);
      expect(await reopened.hasSeen('env-persist'), isTrue);
    });

    test('expired ledger rows are identifiable and removable', () async {
      final repo = repository();
      await repo.recordSeen('env-old', expiresAt: DateTime.utc(2026, 6, 1));
      await repo.recordSeen(
        'env-current',
        expiresAt: DateTime.utc(2026, 6, 10),
      );

      final removed = await repo.deleteExpiredSeen(DateTime.utc(2026, 6, 5));

      expect(removed, 1);
      expect(await repo.hasSeen('env-old'), isFalse);
      expect(await repo.hasSeen('env-current'), isTrue);
    });
  });

  group('relay_queue storage', () {
    test('insert stores every field and reads it back', () async {
      final entry = buildEntry(
        hopLimit: 9,
        hopCount: 2,
        expiresAt: DateTime.utc(2026, 6, 1, 12),
      );
      final inserted = await repository().enqueue(entry);

      expect(inserted, isTrue);
      final read = await repository().findByEnvelopeId('env-1');
      expect(read, isNotNull);
      expect(read!.envelopeId, entry.envelopeId);
      expect(read.envelope, entry.envelope);
      expect(read.originDeviceId, 'device-a');
      expect(read.destinationDeviceId, 'device-b');
      expect(read.expiresAt, DateTime.utc(2026, 6, 1, 12));
      expect(read.hopLimit, 9);
      expect(read.hopCount, 2);
      expect(read.attempts, 0);
      expect(read.nextHopDeviceId, isNull);
      expect(read.state, RelayQueueState.queued);
      expect(read.createdAt, DateTime.utc(2026, 6, 1, 10));
    });

    test('a repeated insert does not duplicate the queue row', () async {
      final repo = repository();
      await repo.enqueue(buildEntry());
      final again = await repo.enqueue(buildEntry());

      expect(again, isFalse);
      final rows = await db.query('relay_queue');
      expect(rows, hasLength(1));
    });

    test('unknown envelope ids read as null', () async {
      expect(await repository().findByEnvelopeId('missing'), isNull);
    });

    test('updateAttempt records attempts, next hop and state', () async {
      final repo = repository();
      await repo.enqueue(buildEntry());

      final updated = await repo.updateAttempt(
        'env-1',
        attempts: 2,
        nextHopDeviceId: 'device-c',
        state: RelayQueueState.sent,
      );

      expect(updated, isTrue);
      final read = await repo.findByEnvelopeId('env-1');
      expect(read!.attempts, 2);
      expect(read.nextHopDeviceId, 'device-c');
      expect(read.state, RelayQueueState.sent);
      // Immutable routing fields are untouched by the update.
      expect(read.originDeviceId, 'device-a');
      expect(read.destinationDeviceId, 'device-b');
      expect(read.hopCount, 1);
    });

    test('updateAttempt fails for an unknown envelope', () async {
      final updated = await repository().updateAttempt(
        'missing',
        attempts: 1,
        state: RelayQueueState.failed,
      );

      expect(updated, isFalse);
    });

    test('expired queue entries are identifiable and removable', () async {
      final repo = repository();
      await repo.enqueue(
        buildEntry(
          envelopeId: 'env-expired',
          expiresAt: DateTime.utc(2026, 6, 1, 11),
        ),
      );
      await repo.enqueue(
        buildEntry(
          envelopeId: 'env-live',
          expiresAt: DateTime.utc(2026, 6, 2, 11),
        ),
      );

      final now = DateTime.utc(2026, 6, 1, 12);
      final expired = await repo.findExpired(now);

      expect(expired.map((entry) => entry.envelopeId), ['env-expired']);

      final removed = await repo.deleteExpiredQueue(now);
      expect(removed, 1);
      expect(await repo.findByEnvelopeId('env-expired'), isNull);
      expect(await repo.findByEnvelopeId('env-live'), isNotNull);
    });

    test('queue rows persist across repository instances', () async {
      await repository().enqueue(buildEntry(envelopeId: 'env-persist'));

      final reopened = RoutingRepository(database: () async => db);
      final read = await reopened.findByEnvelopeId('env-persist');
      expect(read, isNotNull);
      expect(read!.envelope, Uint8List.fromList([0x52, 3, 1, 0]));
    });
  });
}
