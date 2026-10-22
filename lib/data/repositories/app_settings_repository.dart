import 'package:sqflite/sqflite.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/core/utils/timestamp_utils.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/models/app_settings.dart';

class AppSettingsRepository {
  AppSettingsRepository({Future<Database> Function()? database})
    : _openDatabase = database ?? (() => DatabaseHelper.database);

  final Future<Database> Function() _openDatabase;

  Future<Database> get _db => _openDatabase();

  Future<AppSettings> loadSettings() async {
    final db = await _db;
    final rows = await db.query('app_settings', columns: ['key', 'value']);
    final values = <String, String>{};
    for (final row in rows) {
      final key = row['key'];
      final value = row['value'];
      if (key is String && value is String) {
        values[key] = value;
      }
    }

    return AppSettings(
      bleEnabled: _parseBool(
        values[AppConstants.settingBleEnabled],
        AppConstants.defaultBleEnabled,
      ),
      allowNewConnections: _parseBool(
        values[AppConstants.settingAllowNewConnections],
        AppConstants.defaultAllowNewConnections,
      ),
      backgroundBleEnabled: _parseBool(
        values[AppConstants.settingBackgroundBleEnabled],
        AppConstants.defaultBackgroundBleEnabled,
      ),
      messagePreviewsEnabled: _parseBool(
        values[AppConstants.settingMessagePreviewsEnabled],
        AppConstants.defaultMessagePreviewsEnabled,
      ),
    );
  }

  Future<String?> readValue(String key) async {
    final db = await _db;
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final value = rows.first['value'];
    return value is String ? value : null;
  }

  Future<void> writeValue(String key, String value) async {
    if (key.trim().isEmpty) {
      throw ArgumentError.value(key, 'key', 'Setting key must not be empty');
    }
    final db = await _db;
    await db.insert('app_settings', {
      'key': key,
      'value': value,
      'updated_at': TimestampUtils.nowUtcIso8601(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> getBleEnabled() =>
      _readBool(AppConstants.settingBleEnabled, AppConstants.defaultBleEnabled);

  Future<void> setBleEnabled(bool value) =>
      _writeBool(AppConstants.settingBleEnabled, value);

  Future<bool> getAllowNewConnections() => _readBool(
    AppConstants.settingAllowNewConnections,
    AppConstants.defaultAllowNewConnections,
  );

  Future<void> setAllowNewConnections(bool value) =>
      _writeBool(AppConstants.settingAllowNewConnections, value);

  Future<bool> getBackgroundBleEnabled() => _readBool(
    AppConstants.settingBackgroundBleEnabled,
    AppConstants.defaultBackgroundBleEnabled,
  );

  Future<void> setBackgroundBleEnabled(bool value) =>
      _writeBool(AppConstants.settingBackgroundBleEnabled, value);

  Future<bool> getMessagePreviewsEnabled() => _readBool(
    AppConstants.settingMessagePreviewsEnabled,
    AppConstants.defaultMessagePreviewsEnabled,
  );

  Future<void> setMessagePreviewsEnabled(bool value) =>
      _writeBool(AppConstants.settingMessagePreviewsEnabled, value);

  Future<bool> _readBool(String key, bool defaultValue) async {
    final value = await readValue(key);
    return _parseBool(value, defaultValue);
  }

  Future<void> _writeBool(String key, bool value) {
    return writeValue(key, value ? 'true' : 'false');
  }

  bool _parseBool(String? rawValue, bool defaultValue) {
    switch (rawValue?.trim().toLowerCase()) {
      case 'true':
      case '1':
        return true;
      case 'false':
      case '0':
        return false;
      default:
        return defaultValue;
    }
  }
}
