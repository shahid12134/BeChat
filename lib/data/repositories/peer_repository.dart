import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:bechat/core/utils/key_format.dart';
import 'package:bechat/core/utils/timestamp_utils.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/database/database_helper.dart';

class PeerRepository {
  PeerRepository({Future<Database> Function()? database})
    : _openDatabase = database ?? (() => DatabaseHelper.database);

  final Future<Database> Function() _openDatabase;

  Future<Database> get _db => _openDatabase();

  Future<void> insertPeer(Peer peer) => upsertPeer(peer);

  Future<void> upsertPeer(Peer peer) async {
    final db = await _db;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'peers',
        columns: [
          'id',
          'created_at',
          'first_seen',
          'is_blocked',
          'status',
          'avatar_path',
          'public_key',
        ],
        where: 'peer_id = ?',
        whereArgs: [peer.peerId],
        limit: 1,
      );
      final now = DateTime.now();

      if (existing.isEmpty) {
        final insert = peer.copyWith(
          id: peer.id ?? const Uuid().v4(),
          createdAt: peer.createdAt ?? now,
          updatedAt: now,
          firstSeen: peer.firstSeen ?? now,
          lastSeen: peer.lastSeen ?? now,
        );
        await txn.insert('peers', {
          ...insert.toMap(),
          // Keep the invariant that a row holding key material is never
          // recorded as having no key. Insertion still never means verified.
          'verification_state': Peer.resolveKeyVerificationState(
            insert.keyVerificationState.name,
            insert.publicKey,
          ).name,
        }, conflictAlgorithm: ConflictAlgorithm.abort);
        return;
      }

      final current = existing.first;
      final isBlocked =
          (current['is_blocked'] as int?) == 1 ||
          current['status'] == PeerStatus.blocked.name;
      // An upsert only ever supplies or preserves a key; it never verifies one.
      final effectivePublicKey =
          peer.publicKey ?? current['public_key'] as String?;
      await txn.update(
        'peers',
        {
          'display_name': peer.displayName,
          'device_name': peer.deviceName,
          'avatar_path': peer.avatarPath ?? current['avatar_path'],
          'status': isBlocked ? PeerStatus.blocked.name : peer.status.name,
          'signal_strength': peer.signalStrength,
          'last_seen': (peer.lastSeen ?? now).toIso8601String(),
          'public_key': effectivePublicKey,
          'updated_at': now.toIso8601String(),
          ..._keyTransition(
            storedKey: current['public_key'] as String?,
            incomingKey: effectivePublicKey,
            now: now,
          ),
        },
        where: 'peer_id = ?',
        whereArgs: [peer.peerId],
      );
    });
  }

  Future<List<Peer>> getAllPeers() async {
    final db = await _db;
    final maps = await db.query('peers', orderBy: 'last_seen DESC');
    return maps.map((m) => Peer.fromMap(m)).toList();
  }

  Future<Peer?> getPeerByPeerId(String peerId) async {
    final db = await _db;
    final maps = await db.query(
      'peers',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Peer.fromMap(maps.first);
  }

  /// Full-row update of the non-key peer fields.
  ///
  /// Key metadata is not taken from the model: it is derived from the stored
  /// key through [_keyTransition], so this method can never promote a peer to
  /// [PeerKeyVerificationState.verified] and can never leave a verification
  /// state attached to a key that changed or disappeared.
  Future<void> updatePeer(Peer peer) async {
    final db = await _db;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'peers',
        columns: ['public_key'],
        where: 'peer_id = ?',
        whereArgs: [peer.peerId],
        limit: 1,
      );
      if (existing.isEmpty) {
        return;
      }

      final now = DateTime.now();
      await txn.update(
        'peers',
        {
          'display_name': peer.displayName,
          'device_name': peer.deviceName,
          'avatar_path': peer.avatarPath,
          'status': peer.status.name,
          'signal_strength': peer.signalStrength,
          'last_seen': peer.lastSeen?.toIso8601String(),
          'public_key': peer.publicKey,
          'is_blocked': peer.isBlocked ? 1 : 0,
          'updated_at': now.toIso8601String(),
          ..._keyTransition(
            storedKey: existing.first['public_key'] as String?,
            incomingKey: peer.publicKey,
            now: now,
          ),
        },
        where: 'peer_id = ?',
        whereArgs: [peer.peerId],
      );
    });
  }

  /// Records a public key observed for [peerId] (discovery or a future
  /// authenticated handshake).
  ///
  /// Security rules:
  ///
  /// * the key is always stored **unverified** — this method cannot mark a peer
  ///   verified;
  /// * when the peer already has a different key the state becomes
  ///   [PeerKeyVerificationState.changed], any verification timestamp is
  ///   cleared and `key_changed_at` is recorded;
  /// * re-recording the same key changes nothing, so an existing verification
  ///   survives a repeated handshake with the same key;
  /// * [publicKeyHex] must be 32 bytes of lowercase hex, and [fingerprintHex]
  ///   (when supplied) must come from the component that validated the key —
  ///   normally the native identity layer. This repository never invents trust
  ///   from a device identifier or display name.
  ///
  /// Returns the resulting verification state, or null when the peer is unknown
  /// (nothing is written).
  Future<PeerKeyVerificationState?> recordCandidatePublicKey(
    String peerId, {
    required String publicKeyHex,
    String? fingerprintHex,
  }) async {
    if (!KeyFormat.isHex32(publicKeyHex)) {
      throw ArgumentError.value(
        publicKeyHex,
        'publicKeyHex',
        'must be a 32-byte public key in lowercase hex',
      );
    }
    if (fingerprintHex != null && !KeyFormat.isHex32(fingerprintHex)) {
      throw ArgumentError.value(
        fingerprintHex,
        'fingerprintHex',
        'must be a 32-byte fingerprint in lowercase hex',
      );
    }

    final db = await _db;
    return db.transaction<PeerKeyVerificationState?>((txn) async {
      final existing = await txn.query(
        'peers',
        columns: ['public_key', 'verification_state'],
        where: 'peer_id = ?',
        whereArgs: [peerId],
        limit: 1,
      );
      if (existing.isEmpty) {
        return null;
      }

      final storedKey = existing.first['public_key'] as String?;
      final now = DateTime.now();
      final update = _keyTransition(
        storedKey: storedKey,
        incomingKey: publicKeyHex,
        now: now,
        fingerprintHex: fingerprintHex,
      );
      if (update.isEmpty) {
        return Peer.resolveKeyVerificationState(
          existing.first['verification_state'],
          storedKey,
        );
      }

      await txn.update(
        'peers',
        {...update, 'updated_at': now.toIso8601String()},
        where: 'peer_id = ?',
        whereArgs: [peerId],
      );
      return Peer.resolveKeyVerificationState(
        update['verification_state'],
        update['public_key'] as String?,
      );
    });
  }

  /// Key-metadata updates for an incoming public key value.
  ///
  /// Returns an empty map when the key is unchanged, so a repeat observation
  /// keeps any existing verification. When the key appears, changes or is
  /// removed, the previous verification is invalidated: `verified` is never
  /// assigned here, and a stale verification timestamp is cleared.
  ///
  /// `key_verified_at`/`key_changed_at` use the canonical UTC form
  /// ([TimestampUtils]); `updated_at` keeps the local form the existing rows
  /// already use.
  Map<String, Object?> _keyTransition({
    required String? storedKey,
    required String? incomingKey,
    required DateTime now,
    String? fingerprintHex,
  }) {
    final stored = storedKey?.trim();
    final hasStored = stored != null && stored.isNotEmpty;
    final incoming = incomingKey?.trim();
    final hasIncoming = incoming != null && incoming.isNotEmpty;

    if (!hasIncoming) {
      if (!hasStored) {
        return const <String, Object?>{};
      }
      return <String, Object?>{
        'public_key': null,
        'public_key_fingerprint': null,
        'verification_state': PeerKeyVerificationState.none.name,
        'key_verified_at': null,
      };
    }

    if (hasStored && stored == incoming) {
      return const <String, Object?>{};
    }

    return <String, Object?>{
      'public_key': incoming,
      'public_key_fingerprint': fingerprintHex,
      'verification_state': hasStored
          ? PeerKeyVerificationState.changed.name
          : PeerKeyVerificationState.unverified.name,
      'key_verified_at': null,
      'key_changed_at': hasStored ? TimestampUtils.toUtcIso8601(now) : null,
    };
  }

  Future<void> deletePeer(String peerId) async {
    final db = await _db;
    await db.delete('peers', where: 'peer_id = ?', whereArgs: [peerId]);
  }

  Future<void> blockPeer(
    String peerId, {
    String? displayName,
    String? deviceName,
    int? signalStrength,
  }) async {
    final db = await _db;
    final now = DateTime.now();
    await db.transaction((txn) async {
      final existing = await txn.query(
        'peers',
        columns: ['id'],
        where: 'peer_id = ?',
        whereArgs: [peerId],
        limit: 1,
      );
      if (existing.isEmpty) {
        final blocked = Peer(
          id: const Uuid().v4(),
          peerId: peerId,
          displayName: _nonEmpty(displayName) ?? 'Blocked peer',
          deviceName: _nonEmpty(deviceName) ?? 'BeChat device',
          status: PeerStatus.blocked,
          signalStrength: signalStrength,
          firstSeen: now,
          lastSeen: now,
          isBlocked: true,
          createdAt: now,
          updatedAt: now,
        );
        await txn.insert('peers', blocked.toMap());
        return;
      }
      await txn.update(
        'peers',
        {
          'is_blocked': 1,
          'status': PeerStatus.blocked.name,
          'updated_at': now.toIso8601String(),
        },
        where: 'peer_id = ?',
        whereArgs: [peerId],
      );
    });
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> unblockPeer(String peerId) async {
    final db = await _db;
    await db.update(
      'peers',
      {
        'is_blocked': 0,
        'status': 'offline',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
  }

  Future<void> updatePeerStatus(String peerId, PeerStatus status) async {
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    if (status == PeerStatus.blocked) {
      await db.update(
        'peers',
        {
          'status': PeerStatus.blocked.name,
          'is_blocked': 1,
          'last_seen': now,
          'updated_at': now,
        },
        where: 'peer_id = ?',
        whereArgs: [peerId],
      );
      return;
    }
    await db.update(
      'peers',
      {'status': status.name, 'last_seen': now, 'updated_at': now},
      where: 'peer_id = ? AND is_blocked = 0 AND status != ?',
      whereArgs: [peerId, PeerStatus.blocked.name],
    );
  }

  Future<void> resetTransientPresence() async {
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'peers',
      {'status': PeerStatus.offline.name, 'updated_at': now},
      where: 'is_blocked = 0 AND status IN (?, ?)',
      whereArgs: [PeerStatus.online.name, PeerStatus.pairing.name],
    );
    await db.update(
      'peers',
      {'status': PeerStatus.blocked.name, 'updated_at': now},
      where: 'is_blocked = 1 AND status != ?',
      whereArgs: [PeerStatus.blocked.name],
    );
  }

  Future<void> markPeerOnline(
    String peerId, {
    int? signalStrength,
    DateTime? lastSeen,
  }) async {
    final db = await _db;
    final now = DateTime.now();
    await db.update(
      'peers',
      {
        'status': PeerStatus.online.name,
        if (signalStrength != null) 'signal_strength': signalStrength,
        'last_seen': (lastSeen ?? now).toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      where: 'peer_id = ? AND is_blocked = 0 AND status != ?',
      whereArgs: [peerId, PeerStatus.blocked.name],
    );
  }

  Future<void> markPeerOffline(String peerId, {DateTime? lastSeen}) async {
    final db = await _db;
    final now = DateTime.now();
    await db.update(
      'peers',
      {
        'status': PeerStatus.offline.name,
        'last_seen': (lastSeen ?? now).toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      where: 'peer_id = ? AND is_blocked = 0 AND status != ?',
      whereArgs: [peerId, PeerStatus.blocked.name],
    );
  }

  Future<void> updateSignalStrength(String peerId, int strength) async {
    final db = await _db;
    await db.update(
      'peers',
      {
        'signal_strength': strength,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
  }
}
