import 'dart:io';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

/// Fixed, non-secret test vectors (32-byte values written as lowercase hex).
const String kNoiseKeyA =
    '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0';
const String kNoiseKeyB =
    '112233445566778899001122334455667788990011223344556677889900aabb';

const String kDeviceId = 'device-uuid-migration-0001';
const String kDisplayName = 'Migration User';
const String kLegacyIdentityKey = 'legacy-identity-key-placeholder';
const String kLegacyPrivateReference = 'legacy-reference';
const String kCreatedAt = '2026-05-01T08:00:00.000Z';
const String kUpdatedAt = '2026-05-02T09:30:00.000Z';
const String kFirstSeen = '2026-05-03T10:00:00.000Z';
const String kLastSeen = '2026-05-04T11:15:00.000Z';

void main() {
  sqfliteFfiInit();

  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bechat_v3_to_v4_');
    path = p.join(directory.path, 'bechat_v3.db');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  /// Builds a populated **version 3** database using the frozen fixture schema.
  Future<void> seedVersion3() async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, version) => createVersion3Schema(db),
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    try {
      await db.insert('identity', {
        'id': kDeviceId,
        'device_id': kDeviceId,
        'display_name': kDisplayName,
        'public_key': kLegacyIdentityKey,
        'private_key_reference': kLegacyPrivateReference,
        'created_at': kCreatedAt,
        'updated_at': kUpdatedAt,
      });

      // Four legacy peer shapes: valid-looking key, placeholder key, empty
      // string and NULL.
      await db.insert('peers', {
        'id': 'peer-row-key',
        'peer_id': 'peer-with-key',
        'display_name': 'With Key',
        'device_name': 'With Key Phone',
        'status': 'online',
        'signal_strength': -44,
        'first_seen': kFirstSeen,
        'last_seen': kLastSeen,
        'public_key': kNoiseKeyA,
        'is_blocked': 0,
        'created_at': kCreatedAt,
        'updated_at': kUpdatedAt,
      });
      await db.insert('peers', {
        'id': 'peer-row-placeholder',
        'peer_id': 'peer-with-placeholder',
        'display_name': 'Placeholder',
        'device_name': 'Placeholder Phone',
        'status': 'offline',
        'signal_strength': -70,
        'first_seen': kFirstSeen,
        'last_seen': kLastSeen,
        'public_key': 'legacy-placeholder-key',
        'is_blocked': 1,
        'created_at': kCreatedAt,
        'updated_at': kUpdatedAt,
      });
      await db.insert('peers', {
        'id': 'peer-row-empty',
        'peer_id': 'peer-with-empty-key',
        'display_name': 'Empty Key',
        'device_name': 'Empty Key Phone',
        'status': 'blocked',
        'signal_strength': null,
        'first_seen': kFirstSeen,
        'last_seen': kLastSeen,
        'public_key': '   ',
        'is_blocked': 1,
        'created_at': kCreatedAt,
        'updated_at': kUpdatedAt,
      });
      await db.insert('peers', {
        'id': 'peer-row-null',
        'peer_id': 'peer-with-null-key',
        'display_name': 'Null Key',
        'device_name': 'Null Key Phone',
        'status': 'pairing',
        'signal_strength': -88,
        'first_seen': kFirstSeen,
        'last_seen': kLastSeen,
        'public_key': null,
        'is_blocked': 0,
        'created_at': kCreatedAt,
        'updated_at': kUpdatedAt,
      });

      await db.insert('chats', {
        'id': 'chat-row',
        'chat_id': 'chat-migration',
        'peer_id': 'peer-with-key',
        'title': 'With Key',
        'last_message': 'Preserved message',
        'last_message_time': kLastSeen,
        'unread_count': 7,
        'created_at': kCreatedAt,
        'updated_at': kUpdatedAt,
      });
      await db.insert('messages', {
        'id': 'message-row',
        'message_id': 'message-migration',
        'chat_id': 'chat-migration',
        'sender_id': kDeviceId,
        'receiver_id': 'peer-with-key',
        'content': 'Preserved content',
        'message_type': 'text',
        'timestamp': kLastSeen,
        'status': 'delivered',
        'transport': 'ble',
        'ttl': 43200,
        'is_encrypted': 0,
        'created_at': kCreatedAt,
        'updated_at': kUpdatedAt,
      });
      await db.insert('attachments', {
        'id': 'attachment-row',
        'attachment_id': 'attachment-migration',
        'message_id': 'message-migration',
        'file_name': 'photo.jpg',
        'file_path': '/tmp/photo.jpg',
        'mime_type': 'image/jpeg',
        'file_size': 2048,
        'transfer_status': 'complete',
        'created_at': kCreatedAt,
      });
      await db.insert('message_routes', {
        'id': 'route-row',
        'message_id': 'message-migration',
        'next_hop': 'peer-with-key',
        'target_peer': 'peer-with-key',
        'ttl': 43200,
        'attempt_count': 2,
        'status': 'delivered',
        'queued_at': kCreatedAt,
        'updated_at': kUpdatedAt,
      });
      await db.insert('app_settings', {
        'key': AppConstants.settingBleEnabled,
        'value': 'true',
        'updated_at': kUpdatedAt,
      });
    } finally {
      await db.close();
    }
  }

  /// Opens the seeded file at the current version, running the real upgrade
  /// step, and reports the old version sqflite observed.
  Future<(Database, int?)> upgradeToVersion4() async {
    int? observedOldVersion;
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: AppConstants.databaseVersion,
        onUpgrade: (db, oldVersion, newVersion) async {
          observedOldVersion = oldVersion;
          await DatabaseHelper.migrateToVersion4(db);
        },
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    return (db, observedOldVersion);
  }

  Future<Map<String, Map<String, Object?>>> peersById(Database db) async {
    final rows = await db.query('peers');
    return {for (final row in rows) row['peer_id'] as String: row};
  }

  test(
    'version 3 database upgrades to 4 preserving every user record',
    () async {
      await seedVersion3();

      final (db, observedOldVersion) = await upgradeToVersion4();
      try {
        expect(observedOldVersion, 3);
        expect(AppConstants.databaseVersion, 4);

        // Identity row: nothing is rewritten and no key material appears.
        final identityRows = await db.query('identity');
        expect(identityRows, hasLength(1));
        final identity = identityRows.single;
        expect(identity['device_id'], kDeviceId);
        expect(identity['id'], kDeviceId);
        expect(identity['display_name'], kDisplayName);
        expect(identity['public_key'], kLegacyIdentityKey);
        expect(identity['private_key_reference'], kLegacyPrivateReference);
        expect(identity['created_at'], kCreatedAt);
        expect(identity['updated_at'], kUpdatedAt);
        // Migration never invents cryptographic metadata.
        expect(identity['public_key_fingerprint'], isNull);
        expect(identity['key_algorithm'], isNull);
        expect(identity['identity_created_at'], isNull);

        // Peers: identifiers, blocking, presence, signal and timestamps intact.
        final peers = await peersById(db);
        expect(peers.keys, hasLength(4));

        final withKey = peers['peer-with-key']!;
        expect(withKey['id'], 'peer-row-key');
        expect(withKey['public_key'], kNoiseKeyA);
        expect(withKey['status'], 'online');
        expect(withKey['signal_strength'], -44);
        expect(withKey['is_blocked'], 0);
        expect(withKey['first_seen'], kFirstSeen);
        expect(withKey['last_seen'], kLastSeen);
        expect(withKey['created_at'], kCreatedAt);
        expect(withKey['updated_at'], kUpdatedAt);

        final placeholder = peers['peer-with-placeholder']!;
        expect(placeholder['public_key'], 'legacy-placeholder-key');
        expect(placeholder['is_blocked'], 1);
        expect(placeholder['status'], 'offline');
        expect(placeholder['last_seen'], kLastSeen);

        final emptyKey = peers['peer-with-empty-key']!;
        expect(emptyKey['public_key'], isNull);
        expect(emptyKey['is_blocked'], 1);
        expect(emptyKey['status'], 'blocked');

        final nullKey = peers['peer-with-null-key']!;
        expect(nullKey['public_key'], isNull);
        expect(nullKey['signal_strength'], -88);
        expect(nullKey['status'], 'pairing');

        // Chats, messages, attachments, routes and settings are untouched.
        final chat = (await db.query('chats')).single;
        expect(chat['chat_id'], 'chat-migration');
        expect(chat['unread_count'], 7);
        expect(chat['last_message'], 'Preserved message');
        expect(chat['last_message_time'], kLastSeen);

        final message = (await db.query('messages')).single;
        expect(message['message_id'], 'message-migration');
        expect(message['content'], 'Preserved content');
        expect(message['transport'], 'ble');
        expect(message['ttl'], 43200);
        expect(message['is_encrypted'], 0);

        final attachment = (await db.query('attachments')).single;
        expect(attachment['attachment_id'], 'attachment-migration');
        expect(attachment['file_size'], 2048);
        expect(attachment['transfer_status'], 'complete');

        final route = (await db.query('message_routes')).single;
        expect(route['next_hop'], 'peer-with-key');
        expect(route['attempt_count'], 2);
        expect(route['status'], 'delivered');

        final settings = (await db.query('app_settings')).single;
        expect(settings['key'], AppConstants.settingBleEnabled);
        expect(settings['value'], 'true');

        expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        await db.close();
      }
    },
  );

  test('every legacy peer stays unverified after the migration', () async {
    await seedVersion3();

    final (db, _) = await upgradeToVersion4();
    try {
      final peers = await peersById(db);

      // A key that exists becomes unverified; it is never trusted for existing.
      expect(peers['peer-with-key']!['verification_state'], 'unverified');
      expect(
        peers['peer-with-placeholder']!['verification_state'],
        'unverified',
      );
      // No usable key means no key.
      expect(peers['peer-with-empty-key']!['verification_state'], 'none');
      expect(peers['peer-with-null-key']!['verification_state'], 'none');

      // No verification or change timestamps are invented, and no fingerprint
      // is derived from an unverified key.
      for (final row in peers.values) {
        expect(row['verification_state'], isNot('verified'));
        expect(row['verification_state'], isNot('changed'));
        expect(row['key_verified_at'], isNull);
        expect(row['key_changed_at'], isNull);
        expect(row['public_key_fingerprint'], isNull);
      }

      // The same conclusion through the model and repository layer.
      final repository = PeerRepository(database: () async => db);
      final withKey = await repository.getPeerByPeerId('peer-with-key');
      expect(
        withKey!.keyVerificationState,
        PeerKeyVerificationState.unverified,
      );
      expect(withKey.hasVerifiedKey, isFalse);
      expect(withKey.hasPublicKey, isTrue);

      final withoutKey = await repository.getPeerByPeerId('peer-with-null-key');
      expect(withoutKey!.keyVerificationState, PeerKeyVerificationState.none);
      expect(withoutKey.hasPublicKey, isFalse);

      // Re-recording the legacy key keeps it unverified: no device id, display
      // name or prior existence can establish trust.
      final state = await repository.recordCandidatePublicKey(
        'peer-with-key',
        publicKeyHex: kNoiseKeyA,
      );
      expect(state, PeerKeyVerificationState.unverified);
    } finally {
      await db.close();
    }
  });

  test(
    'a fresh database and an upgraded database end up with the same schema',
    () async {
      await seedVersion3();

      final (upgraded, _) = await upgradeToVersion4();
      final fresh = await openTestDatabase(singleInstance: false);
      try {
        expect(await _schemaOf(upgraded), await _schemaOf(fresh));
      } finally {
        await upgraded.close();
        await fresh.close();
      }
    },
  );

  test('running the migration again is a no-op', () async {
    await seedVersion3();

    final (db, _) = await upgradeToVersion4();
    try {
      final before = await peersById(db);
      final identityBefore = (await db.query('identity')).single;

      await DatabaseHelper.migrateToVersion4(db);

      expect(await peersById(db), before);
      expect((await db.query('identity')).single, identityBefore);
    } finally {
      await db.close();
    }
  });

  test('a database missing a required table fails loudly', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 3,
        singleInstance: false,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE app_settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    addTearDown(db.close);

    await expectLater(
      DatabaseHelper.migrateToVersion4(db),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('identity'), contains('missing')),
        ),
      ),
    );
  });
}

/// Column metadata for every user table, keyed by table name.
Future<Map<String, List<Map<String, Object?>>>> _schemaOf(Database db) async {
  final tables = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%' "
    'ORDER BY name',
  );
  final schema = <String, List<Map<String, Object?>>>{};
  for (final table in tables) {
    final name = table['name'] as String;
    final info = await db.rawQuery('PRAGMA table_info($name)');
    schema[name] = [
      for (final row in info)
        {
          'name': row['name'],
          'type': row['type'],
          'notnull': row['notnull'],
          'dflt_value': row['dflt_value'],
          'pk': row['pk'],
        },
    ];
  }
  return schema;
}
