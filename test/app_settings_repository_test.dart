import 'dart:io';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/repositories/app_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await openTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  AppSettingsRepository repository() {
    return AppSettingsRepository(database: () async => db);
  }

  test('a new database returns all default settings', () async {
    final settings = await repository().loadSettings();

    expect(settings.bleEnabled, isFalse);
    expect(settings.allowNewConnections, isTrue);
    expect(settings.backgroundBleEnabled, isFalse);
    expect(settings.messagePreviewsEnabled, isFalse);
  });

  test('ble_enabled defaults to false', () async {
    expect(await repository().getBleEnabled(), isFalse);
  });

  test('allow_new_connections defaults to true', () async {
    expect(await repository().getAllowNewConnections(), isTrue);
  });

  test('background_ble_enabled defaults to false', () async {
    expect(await repository().getBackgroundBleEnabled(), isFalse);
  });

  test('message_previews_enabled defaults to false', () async {
    expect(await repository().getMessagePreviewsEnabled(), isFalse);
  });

  test('updating a setting persists its value', () async {
    await repository().setBleEnabled(true);

    expect(await repository().getBleEnabled(), isTrue);
    final row = (await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [AppConstants.settingBleEnabled],
    )).single;
    expect(row['value'], 'true');
    expect(row['updated_at'], endsWith('Z'));
  });

  test('updating one setting does not change unrelated settings', () async {
    await repository().setAllowNewConnections(false);

    final settings = await repository().loadSettings();
    expect(settings.allowNewConnections, isFalse);
    expect(settings.bleEnabled, AppConstants.defaultBleEnabled);
    expect(
      settings.backgroundBleEnabled,
      AppConstants.defaultBackgroundBleEnabled,
    );
    expect(
      settings.messagePreviewsEnabled,
      AppConstants.defaultMessagePreviewsEnabled,
    );
  });

  test('missing and invalid stored values fall back to defaults', () async {
    await db.insert('app_settings', {
      'key': AppConstants.settingBleEnabled,
      'value': 'not-a-boolean',
      'updated_at': '2026-01-01T00:00:00.000000Z',
    });

    expect(await repository().getBleEnabled(), isFalse);
    expect(await repository().getAllowNewConnections(), isTrue);

    await db.delete('app_settings');
    final settings = await repository().loadSettings();
    expect(settings.bleEnabled, isFalse);
    expect(settings.allowNewConnections, isTrue);
    expect(settings.backgroundBleEnabled, isFalse);
    expect(settings.messagePreviewsEnabled, isFalse);
  });

  test('settings survive closing and reopening the database', () async {
    final directory = await Directory.systemTemp.createTemp('bechat_settings_');
    final path = p.join(directory.path, 'bechat_settings.db');
    Database? fileDb;

    Future<Database> open() {
      return databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: AppConstants.databaseVersion,
          onCreate: (db, version) => DatabaseHelper.createSchema(db),
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 3) {
              await DatabaseHelper.migrateToVersion3(db);
            }
          },
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
          },
        ),
      );
    }

    try {
      fileDb = await open();
      await AppSettingsRepository(
        database: () async => fileDb!,
      ).setAllowNewConnections(false);
      await fileDb.close();

      fileDb = await open();
      final settings = await AppSettingsRepository(
        database: () async => fileDb!,
      ).loadSettings();
      expect(settings.allowNewConnections, isFalse);
      expect(settings.bleEnabled, isFalse);
      expect(settings.backgroundBleEnabled, isFalse);
      expect(settings.messagePreviewsEnabled, isFalse);
    } finally {
      try {
        await fileDb?.close();
      } catch (_) {}
      await directory.delete(recursive: true);
    }
  });
}
