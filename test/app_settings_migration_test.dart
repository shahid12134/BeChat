import 'dart:io';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/repositories/app_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'migration from version 2 to 3 creates settings and preserves user data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bechat_migration_',
      );
      final path = p.join(directory.path, 'bechat_v2.db');
      Database? db;
      final timestamp = DateTime.utc(
        2026,
        6,
        1,
        9,
        30,
        15,
        250,
      ).toIso8601String();

      Future<Database> openVersion2() {
        return databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 2,
            onCreate: (db, version) async {
              await DatabaseHelper.createSchema(db);
              await db.execute('DROP TABLE app_settings');
            },
            onConfigure: (db) async {
              await db.execute('PRAGMA foreign_keys = ON');
            },
          ),
        );
      }

      try {
        db = await openVersion2();
        await db.insert('identity', {
          'id': 'identity-row',
          'device_id': 'device-local',
          'display_name': 'Local User',
          'created_at': timestamp,
          'updated_at': timestamp,
        });
        await db.insert('peers', {
          'id': 'peer-row',
          'peer_id': 'peer-alice',
          'display_name': 'Alice',
          'device_name': 'Alice Phone',
          'status': 'offline',
          'is_blocked': 0,
          'created_at': timestamp,
          'updated_at': timestamp,
        });
        await db.insert('chats', {
          'id': 'chat-row',
          'chat_id': 'chat-alice',
          'peer_id': 'peer-alice',
          'title': 'Alice',
          'unread_count': 0,
          'created_at': timestamp,
          'updated_at': timestamp,
        });
        await db.insert('messages', {
          'id': 'message-row',
          'message_id': 'message-1',
          'chat_id': 'chat-alice',
          'sender_id': 'device-local',
          'receiver_id': 'peer-alice',
          'content': 'Hello',
          'message_type': 'text',
          'timestamp': timestamp,
          'status': 'delivered',
          'transport': 'ble',
          'ttl': 86400,
          'is_encrypted': 0,
          'created_at': timestamp,
          'updated_at': timestamp,
        });
        await db.close();

        int? observedOldVersion;
        db = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: AppConstants.databaseVersion,
            onUpgrade: (db, oldVersion, newVersion) async {
              observedOldVersion = oldVersion;
              await DatabaseHelper.migrateToVersion3(db);
            },
            onConfigure: (db) async {
              await db.execute('PRAGMA foreign_keys = ON');
            },
          ),
        );

        expect(observedOldVersion, 2);
        expect(
          (await db.rawQuery(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name = 'app_settings'",
          )).single['name'],
          'app_settings',
        );
        expect(
          (await db.query('identity')).single['device_id'],
          'device-local',
        );
        expect((await db.query('peers')).single['peer_id'], 'peer-alice');
        expect((await db.query('chats')).single['chat_id'], 'chat-alice');
        expect((await db.query('messages')).single['message_id'], 'message-1');

        final settings = await AppSettingsRepository(
          database: () async => db!,
        ).loadSettings();
        expect(settings.bleEnabled, isFalse);
        expect(settings.allowNewConnections, isTrue);
        expect(settings.backgroundBleEnabled, isFalse);
        expect(settings.messagePreviewsEnabled, isFalse);
        expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        try {
          await db?.close();
        } catch (_) {}
        await directory.delete(recursive: true);
      }
    },
  );
}
