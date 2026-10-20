enum PeerStatus { online, offline, pairing, blocked }

class Peer {
  final String? id;
  final String peerId;
  final String displayName;
  final String deviceName;
  final String? avatarPath;
  final PeerStatus status;
  final int? signalStrength;
  final DateTime? firstSeen;
  final DateTime? lastSeen;
  final String? publicKey;
  final bool isBlocked;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Peer({
    this.id,
    required this.peerId,
    required this.displayName,
    required this.deviceName,
    this.avatarPath,
    this.status = PeerStatus.offline,
    this.signalStrength,
    this.firstSeen,
    this.lastSeen,
    this.publicKey,
    this.isBlocked = false,
    this.createdAt,
    this.updatedAt,
  });

  Peer copyWith({
    String? id,
    String? peerId,
    String? displayName,
    String? deviceName,
    String? avatarPath,
    PeerStatus? status,
    int? signalStrength,
    DateTime? firstSeen,
    DateTime? lastSeen,
    String? publicKey,
    bool? isBlocked,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Peer(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      deviceName: deviceName ?? this.deviceName,
      avatarPath: avatarPath ?? this.avatarPath,
      status: status ?? this.status,
      signalStrength: signalStrength ?? this.signalStrength,
      firstSeen: firstSeen ?? this.firstSeen,
      lastSeen: lastSeen ?? this.lastSeen,
      publicKey: publicKey ?? this.publicKey,
      isBlocked: isBlocked ?? this.isBlocked,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'peer_id': peerId,
      'display_name': displayName,
      'device_name': deviceName,
      'avatar_path': avatarPath,
      'status': status.name,
      'signal_strength': signalStrength,
      'first_seen': firstSeen?.toIso8601String(),
      'last_seen': lastSeen?.toIso8601String(),
      'public_key': publicKey,
      'is_blocked': isBlocked ? 1 : 0,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  factory Peer.fromMap(Map<String, dynamic> map) {
    return Peer(
      id: map['id'] as String?,
      peerId: map['peer_id'] as String,
      displayName: map['display_name'] as String,
      deviceName: map['device_name'] as String,
      avatarPath: map['avatar_path'] as String?,
      status: PeerStatus.values.firstWhere(
        (e) => e.name == map['status'],
        orElse: () => PeerStatus.offline,
      ),
      signalStrength: map['signal_strength'] as int?,
      firstSeen: map['first_seen'] != null ? DateTime.parse(map['first_seen'] as String) : null,
      lastSeen: map['last_seen'] != null ? DateTime.parse(map['last_seen'] as String) : null,
      publicKey: map['public_key'] as String?,
      isBlocked: (map['is_blocked'] as int?) == 1,
      createdAt: map['created_at'] != null ? DateTime.parse(map['created_at'] as String) : null,
      updatedAt: map['updated_at'] != null ? DateTime.parse(map['updated_at'] as String) : null,
    );
  }
}
