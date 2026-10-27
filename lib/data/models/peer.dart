enum PeerStatus { online, offline, pairing, blocked }

/// State of the cryptographic key known for a peer.
///
/// Stored as the enum name in `peers.verification_state`. The distinction
/// matters for security:
///
/// * [none] — no cryptographic key is known.
/// * [unverified] — a key is stored but was never verified by an authenticated
///   handshake. A device UUID or display name match does **not** upgrade this.
/// * [verified] — the key was confirmed by a completed authenticated
///   handshake. Only the dedicated verification workflow may set this.
/// * [changed] — a different key arrived for a peer that already had one, or a
///   previously verified key no longer matches. Treat as untrusted.
enum PeerKeyVerificationState { none, unverified, verified, changed }

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
  final String? publicKeyFingerprint;
  final PeerKeyVerificationState keyVerificationState;
  final DateTime? keyVerifiedAt;
  final DateTime? keyChangedAt;
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
    this.publicKeyFingerprint,
    this.keyVerificationState = PeerKeyVerificationState.none,
    this.keyVerifiedAt,
    this.keyChangedAt,
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
    String? publicKeyFingerprint,
    PeerKeyVerificationState? keyVerificationState,
    DateTime? keyVerifiedAt,
    DateTime? keyChangedAt,
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
      publicKeyFingerprint: publicKeyFingerprint ?? this.publicKeyFingerprint,
      keyVerificationState: keyVerificationState ?? this.keyVerificationState,
      keyVerifiedAt: keyVerifiedAt ?? this.keyVerifiedAt,
      keyChangedAt: keyChangedAt ?? this.keyChangedAt,
      isBlocked: isBlocked ?? this.isBlocked,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Whether a cryptographic key is stored for this peer, regardless of trust.
  bool get hasPublicKey => publicKey != null && publicKey!.trim().isNotEmpty;

  /// Whether the stored key was confirmed by an authenticated handshake.
  ///
  /// A key that merely exists is never [PeerKeyVerificationState.verified].
  bool get hasVerifiedKey =>
      hasPublicKey && keyVerificationState == PeerKeyVerificationState.verified;

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
      'public_key_fingerprint': publicKeyFingerprint,
      'verification_state': keyVerificationState.name,
      'key_verified_at': keyVerifiedAt?.toIso8601String(),
      'key_changed_at': keyChangedAt?.toIso8601String(),
      'is_blocked': isBlocked ? 1 : 0,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  factory Peer.fromMap(Map<String, dynamic> map) {
    final publicKey = map['public_key'] as String?;
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
      firstSeen: map['first_seen'] != null
          ? DateTime.parse(map['first_seen'] as String)
          : null,
      lastSeen: map['last_seen'] != null
          ? DateTime.parse(map['last_seen'] as String)
          : null,
      publicKey: publicKey,
      publicKeyFingerprint: map['public_key_fingerprint'] as String?,
      keyVerificationState: resolveKeyVerificationState(
        map['verification_state'],
        publicKey,
      ),
      keyVerifiedAt: map['key_verified_at'] != null
          ? DateTime.parse(map['key_verified_at'] as String)
          : null,
      keyChangedAt: map['key_changed_at'] != null
          ? DateTime.parse(map['key_changed_at'] as String)
          : null,
      isBlocked: (map['is_blocked'] as int?) == 1,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'] as String)
          : null,
    );
  }

  /// Resolves a stored verification state defensively.
  ///
  /// A row with key material is never `none`; a row without key material is
  /// never anything else. Unrecognized or missing values become
  /// [PeerKeyVerificationState.unverified] when a key exists, so unknown data
  /// can never be read back as [PeerKeyVerificationState.verified].
  static PeerKeyVerificationState resolveKeyVerificationState(
    Object? storedValue,
    String? publicKey,
  ) {
    final hasKey = publicKey != null && publicKey.trim().isNotEmpty;
    if (!hasKey) {
      return PeerKeyVerificationState.none;
    }

    PeerKeyVerificationState? parsed;
    for (final state in PeerKeyVerificationState.values) {
      if (state.name == storedValue) {
        parsed = state;
        break;
      }
    }
    if (parsed == null || parsed == PeerKeyVerificationState.none) {
      return PeerKeyVerificationState.unverified;
    }
    return parsed;
  }
}
