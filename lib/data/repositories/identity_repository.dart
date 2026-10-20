import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/database/database_helper.dart';

class IdentityRepository {
  IdentityRepository({Future<Database> Function()? database})
    : _openDatabase = database ?? (() => DatabaseHelper.database);

  final Future<Database> Function() _openDatabase;

  Future<Database> get _db => _openDatabase();

  Future<Identity> ensureIdentity() async {
    final db = await _db;
    return db.transaction<Identity>((txn) async {
      final maps = await txn.query(
        'identity',
        orderBy: 'created_at ASC, device_id ASC',
        limit: 1,
      );

      if (maps.isEmpty) {
        final now = DateTime.now();
        final deviceId = const Uuid().v4();
        final identity = Identity(
          id: deviceId,
          deviceId: deviceId,
          displayName: AppConstants.defaultDeviceName,
          createdAt: now,
          updatedAt: now,
        );
        await txn.insert('identity', identity.toMap());
        return identity;
      }

      final existing = Identity.fromMap(maps.first);
      final now = DateTime.now();

      if (existing.deviceId != AppConstants.legacyPlaceholderDeviceId) {
        if (existing.id == null || existing.id!.isEmpty) {
          await txn.update(
            'identity',
            {'id': existing.deviceId},
            where: 'device_id = ?',
            whereArgs: [existing.deviceId],
          );
          return existing.copyWith(id: existing.deviceId);
        }
        return existing;
      }

      final deviceId = const Uuid().v4();
      final existingId = existing.id;
      final repaired = Identity(
        id: existingId != null && existingId.isNotEmpty ? existingId : deviceId,
        deviceId: deviceId,
        displayName: existing.displayName.trim().isEmpty
            ? AppConstants.defaultDeviceName
            : existing.displayName,
        publicKey: existing.publicKey,
        privateKeyReference: existing.privateKeyReference,
        createdAt: existing.createdAt ?? now,
        updatedAt: now,
      );

      await txn.update(
        'identity',
        repaired.toMap(),
        where: 'device_id = ?',
        whereArgs: [AppConstants.legacyPlaceholderDeviceId],
      );
      await txn.update(
        'messages',
        {'sender_id': deviceId},
        where: 'sender_id = ?',
        whereArgs: [AppConstants.legacyPlaceholderDeviceId],
      );
      await txn.update(
        'messages',
        {'receiver_id': deviceId},
        where: 'receiver_id = ?',
        whereArgs: [AppConstants.legacyPlaceholderDeviceId],
      );

      return repaired;
    });
  }

  Future<void> insertIdentity(Identity identity) async {
    final db = await _db;
    final insert = identity.id == null
        ? identity.copyWith(id: const Uuid().v4())
        : identity;
    await db.insert(
      'identity',
      insert.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<Identity?> getIdentity() async {
    final db = await _db;
    final maps = await db.query(
      'identity',
      orderBy: 'created_at ASC, device_id ASC',
      limit: 1,
    );
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
