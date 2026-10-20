import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
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
        await txn.insert(
          'peers',
          insert.toMap(),
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
        return;
      }

      final current = existing.first;
      final isBlocked =
          (current['is_blocked'] as int?) == 1 ||
          current['status'] == PeerStatus.blocked.name;
      await txn.update(
        'peers',
        {
          'display_name': peer.displayName,
          'device_name': peer.deviceName,
          'avatar_path': peer.avatarPath ?? current['avatar_path'],
          'status': isBlocked ? PeerStatus.blocked.name : peer.status.name,
          'signal_strength': peer.signalStrength,
          'last_seen': (peer.lastSeen ?? now).toIso8601String(),
          'public_key': peer.publicKey ?? current['public_key'],
          'updated_at': now.toIso8601String(),
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

  Future<void> updatePeer(Peer peer) async {
    final db = await _db;
    await db.update(
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
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'peer_id = ?',
      whereArgs: [peer.peerId],
    );
  }

  Future<void> deletePeer(String peerId) async {
    final db = await _db;
    await db.delete('peers', where: 'peer_id = ?', whereArgs: [peerId]);
  }

  Future<void> blockPeer(String peerId) async {
    final db = await _db;
    await db.update(
      'peers',
      {
        'is_blocked': 1,
        'status': 'blocked',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
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
    await db.update(
      'peers',
      {
        'status': status.name,
        'last_seen': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'peer_id = ?',
      whereArgs: [peerId],
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
