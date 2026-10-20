import 'package:sqflite/sqflite.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/database/database_helper.dart';

class PeerRepository {
  Future<Database> get _db => DatabaseHelper.database;

  Future<void> insertPeer(Peer peer) async {
    final db = await _db;
    await db.insert(
      'peers',
      peer.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
      peer.toMap(),
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
      {'is_blocked': 1, 'status': 'blocked', 'updated_at': DateTime.now().toIso8601String()},
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
  }

  Future<void> unblockPeer(String peerId) async {
    final db = await _db;
    await db.update(
      'peers',
      {'is_blocked': 0, 'status': 'offline', 'updated_at': DateTime.now().toIso8601String()},
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
