import 'package:sqflite/sqflite.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/database/database_helper.dart';

class IdentityRepository {
  Future<Database> get _db => DatabaseHelper.database;

  Future<void> insertIdentity(Identity identity) async {
    final db = await _db;
    await db.insert(
      'identity',
      identity.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Identity?> getIdentity() async {
    final db = await _db;
    final maps = await db.query('identity', limit: 1);
    if (maps.isEmpty) return null;
    return Identity.fromMap(maps.first);
  }

  Future<Identity?> getIdentityByDeviceId(String deviceId) async {
    final db = await _db;
    final maps = await db.query(
      'identity',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Identity.fromMap(maps.first);
  }

  Future<void> updateIdentity(Identity identity) async {
    final db = await _db;
    await db.update(
      'identity',
      identity.toMap()..remove('id'),
      where: 'device_id = ?',
      whereArgs: [identity.deviceId],
    );
  }

  Future<void> deleteIdentity(String deviceId) async {
    final db = await _db;
    await db.delete('identity', where: 'device_id = ?', whereArgs: [deviceId]);
  }
}
