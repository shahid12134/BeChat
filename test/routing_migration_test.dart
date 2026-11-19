import 'dart:io';
import 'dart:typed_data';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

/// v4 -> v5 must be purely additive: new routing tables appear, existing
/// tables and user data stay untouched, and the upgraded schema matches a
/// freshly created v5 database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bechat_v5_migration_');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<Database> openV4({required String path}) {
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, version) => createVersion4Schema(db),
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
  }

  Future<Database> openAtCurrentVersion(String path) {
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: AppConstants.databaseVersion,
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 5) {
            await DatabaseHelper.migrateToVersion5(db);
          }
          if (oldVersion < 6) {
            await DatabaseHelper.migrateToVersion6(db);
          }
        },
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
  }

  Future<Set<String>> tableNames(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    return rows.map((row) => row['name']! as String).toSet();
  }

  Future<Set<String>> indexNames(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    );
    return rows.map((row) => row['name']! as String).toSet();
  }

  test(
    'migration from version 4 to 5 adds routing tables additively',
    () async {
      final path = p.join(directory.path, 'bechat_additive.db');

      // Seed a v4 database with representative user data.
      final v4 = await openV4(path: path);
      await v4.insert('identity', {
        'id': 'id-1',
        'device_id': 'device-local',
        'display_name': 'Local User',
        'created_at': '2026-05-01T08:00:00.000Z',
        'updated_at': '2026-05-01T08:00:00.000Z',
      });
      await v4.insert('peers', {
        'id': 'peer-1',
        'peer_id': 'device-remote',
        'display_name': 'Remote User',
        'device_name': 'remote-phone',
        'created_at': '2026-05-01T08:00:00.000Z',
        'updated_at': '2026-05-01T08:00:00.000Z',
      });
      final v4Tables = await tableNames(v4);
      final v4Indexes = await indexNames(v4);
      await v4.close();

      // Upgrade through the real migration.
      final upgraded = await openAtCurrentVersion(path);
      final upgradedTables = await tableNames(upgraded);
      final upgradedIndexes = await indexNames(upgraded);

      // The two routing tables and their indexes are new...
      expect(upgradedTables.contains('seen_messages'), isTrue);
      expect(upgradedTables.contains('relay_queue'), isTrue);
      expect(upgradedIndexes.contains('idx_seen_messages_expires_at'), isTrue);
      expect(upgradedIndexes.contains('idx_relay_queue_expires_at'), isTrue);
      expect(upgradedIndexes.contains('idx_relay_queue_state'), isTrue);

      // ...and every pre-existing table survives untouched.
      for (final table in v4Tables) {
        expect(upgradedTables.contains(table), isTrue, reason: table);
      }
      for (final index in v4Indexes) {
        expect(upgradedIndexes.contains(index), isTrue, reason: index);
      }

      // User data is preserved.
      final identity = await upgraded.query('identity');
      expect(identity, hasLength(1));
      expect(identity.first['device_id'], 'device-local');
      final peers = await upgraded.query('peers');
      expect(peers, hasLength(1));
      expect(peers.first['peer_id'], 'device-remote');

      await upgraded.close();
    },
  );

  test('upgraded v4 database matches a freshly created schema', () async {
    final upgradedPath = p.join(directory.path, 'bechat_compare_upgraded.db');
    final freshPath = p.join(directory.path, 'bechat_compare_fresh.db');

    final v4 = await openV4(path: upgradedPath);
    await v4.close();
    final upgraded = await openAtCurrentVersion(upgradedPath);

    final fresh = await databaseFactoryFfi.openDatabase(
      freshPath,
      options: OpenDatabaseOptions(
        version: AppConstants.databaseVersion,
        onCreate: (db, version) => DatabaseHelper.createSchema(db),
      ),
    );

    expect(await tableNames(upgraded), await tableNames(fresh));
    expect(await indexNames(upgraded), await indexNames(fresh));

    // Column-level comparison of the new tables, not just names.
    Future<Map<String, String>> columns(Database db, String table) async {
      final rows = await db.rawQuery('PRAGMA table_info($table)');
      return {
        for (final row in rows)
          row['name']! as String:
              '${row['type']}|${row['notnull']}|'
              '${row['dflt_value']}|${row['pk']}',
      };
    }

    for (final table in ['seen_messages', 'relay_queue']) {
      expect(
        await columns(upgraded, table),
        await columns(fresh, table),
        reason: table,
      );
    }

    await upgraded.close();
    await fresh.close();
  });

  test('re-running the v5 migration is a no-op', () async {
    final path = p.join(directory.path, 'bechat_rerun.db');
    final v4 = await openV4(path: path);
    await v4.close();

    final upgraded = await openAtCurrentVersion(path);
    await DatabaseHelper.migrateToVersion5(upgraded);

    // Tables still usable, no duplicates or errors.
    await upgraded.insert('seen_messages', {
      'envelope_id': 'env-1',
      'first_seen_at': '2026-06-01T10:00:00.000Z',
      'expires_at': '2026-06-08T10:00:00.000Z',
    });
    final rows = await upgraded.query('seen_messages');
    expect(rows, hasLength(1));
    await upgraded.close();
  });

  test('migration from version 5 to 6 adds the incoming peer column without '
      'touching existing records', () async {
    final path = p.join(directory.path, 'bechat_v5_to_v6.db');

    // A real v5 database: the frozen v4 fixture plus the real v5 migration.
    final v5 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (db, version) async {
          await createVersion4Schema(db);
          await DatabaseHelper.migrateToVersion5(db);
        },
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    await v5.insert('peers', {
      'id': 'peer-1',
      'peer_id': 'device-remote',
      'display_name': 'Remote User',
      'device_name': 'remote-phone',
      'created_at': '2026-05-01T08:00:00.000Z',
      'updated_at': '2026-05-01T08:00:00.000Z',
    });
    // A parked queue row in the pre-v6 shape: no incoming peer column exists.
    await v5.insert('relay_queue', {
      'envelope_id': 'env-v5',
      'envelope': Uint8List.fromList([0x52, 3, 1, 0]),
      'origin_device_id': 'device-a',
      'destination_device_id': 'device-c',
      'expires_at': '2026-06-01T11:00:00.000Z',
      'hop_limit': 5,
      'hop_count': 1,
      'attempts': 2,
      'next_hop_device_id': 'device-b',
      'state': 'failed',
      'created_at': '2026-06-01T10:00:00.000Z',
      'updated_at': '2026-06-01T10:05:00.000Z',
    });
    await v5.close();

    // Upgrade through the real migration chain.
    final upgraded = await openAtCurrentVersion(path);

    final rows = await upgraded.query('relay_queue');
    expect(rows, hasLength(1), reason: 'the parked envelope must survive');
    final row = rows.single;
    expect(row['envelope_id'], 'env-v5');
    expect(row['envelope'], [0x52, 3, 1, 0]);
    expect(row['state'], 'failed');
    expect(row['attempts'], 2);
    expect(row['next_hop_device_id'], 'device-b');
    expect(
      row['incoming_peer_device_id'],
      isNull,
      reason: 'a pre-v6 row has no authenticated incoming peer',
    );
    // User data in other tables is untouched.
    final peers = await upgraded.query('peers');
    expect(peers.single['peer_id'], 'device-remote');
    // The column now exists, and the schema matches a fresh database
    // (asserted column-by-column by the upgraded-vs-fresh test above).
    final columns = await upgraded.rawQuery('PRAGMA table_info(relay_queue)');
    expect(columns.map((info) => info['name']), contains('incoming_peer_device_id'));

    await upgraded.close();
  });
}
