import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/core/utils/key_format.dart';
import 'package:bechat/core/utils/timestamp_utils.dart';
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

  /// Persists the public identity metadata reported by the native identity
  /// subsystem.
  ///
  /// This records *non-secret* metadata only, and it never creates, replaces or
  /// rotates an identity:
  ///
  /// * the existing row keeps its `device_id` and `display_name`;
  /// * [publicKeyHex] and [publicKeyFingerprint] must be 32-byte lowercase hex;
  /// * [privateKeyReference] must be an opaque name (see [KeyFormat]); a
  ///   private seed, decrypted envelope, wrapping key or filesystem path is
  ///   rejected instead of stored;
  /// * no key is generated, no native identity storage is touched and no peer
  ///   is marked verified.
  ///
  /// Throws [StateError] when no identity row exists yet: an established
  /// identity is required, because persisting metadata must not be the thing
  /// that brings an identity into existence.
  ///
  /// New timestamps use the canonical UTC form ([TimestampUtils]).
  Future<Identity> savePublicIdentityMetadata({
    required String publicKeyHex,
    required String publicKeyFingerprint,
    String? privateKeyReference,
    String keyAlgorithm = AppConstants.noiseKeyAlgorithm,
    DateTime? identityCreatedAt,
  }) async {
    if (!KeyFormat.isHex32(publicKeyHex)) {
      throw ArgumentError.value(
        publicKeyHex,
        'publicKeyHex',
        'must be a 32-byte public key in lowercase hex',
      );
    }
    if (!KeyFormat.isHex32(publicKeyFingerprint)) {
      throw ArgumentError.value(
        publicKeyFingerprint,
        'publicKeyFingerprint',
        'must be a 32-byte fingerprint in lowercase hex',
      );
    }
    if (keyAlgorithm.trim().isEmpty) {
      throw ArgumentError.value(
        keyAlgorithm,
        'keyAlgorithm',
        'must not be empty',
      );
    }
    if (privateKeyReference != null &&
        !KeyFormat.isOpaqueReference(privateKeyReference)) {
      throw ArgumentError.value(
        privateKeyReference,
        'privateKeyReference',
        'must be an opaque native key reference, not a path or key material',
      );
    }

    final db = await _db;
    return db.transaction<Identity>((txn) async {
      final rows = await txn.query(
        'identity',
        orderBy: 'created_at ASC, device_id ASC',
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError(
          'Cannot persist public identity metadata: no identity row exists.',
        );
      }

      final current = Identity.fromMap(rows.first);
      final now = DateTime.now();
      await txn.update(
        'identity',
        {
          'public_key': publicKeyHex,
          'public_key_fingerprint': publicKeyFingerprint,
          'key_algorithm': keyAlgorithm,
          'identity_created_at': TimestampUtils.toUtcIso8601(
            identityCreatedAt ?? now,
          ),
          if (privateKeyReference != null)
            'private_key_reference': privateKeyReference,
          'updated_at': now.toIso8601String(),
        },
        where: 'device_id = ?',
        whereArgs: [current.deviceId],
      );

      final refreshed = await txn.query(
        'identity',
        where: 'device_id = ?',
        whereArgs: [current.deviceId],
        limit: 1,
      );
      return Identity.fromMap(refreshed.single);
    });
  }
}
