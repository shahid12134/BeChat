/// The local device identity row.
///
/// [publicKey] is the public Noise static identity key once the native identity
/// subsystem has provisioned one. [privateKeyReference] is an **opaque**
/// reference to native key material (for example a Keystore alias or envelope
/// name); it never contains a private seed, a decrypted envelope, an encryption
/// key or a filesystem path. The private key itself lives in Android Keystore
/// storage and is never written to SQLite.
class Identity {
  final String? id;
  final String deviceId;
  final String displayName;
  final String? publicKey;
  final String? privateKeyReference;

  /// Lowercase-hex SHA-256 fingerprint of [publicKey], when recorded.
  final String? publicKeyFingerprint;

  /// Identifier of the key algorithm for [publicKey] (see
  /// `AppConstants.noiseKeyAlgorithm`), when recorded.
  final String? keyAlgorithm;

  /// When the cryptographic identity was provisioned. Distinct from
  /// [createdAt], which is when the local device row was first written.
  final DateTime? identityCreatedAt;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Identity({
    this.id,
    required this.deviceId,
    required this.displayName,
    this.publicKey,
    this.privateKeyReference,
    this.publicKeyFingerprint,
    this.keyAlgorithm,
    this.identityCreatedAt,
    this.createdAt,
    this.updatedAt,
  });

  Identity copyWith({
    String? id,
    String? deviceId,
    String? displayName,
    String? publicKey,
    String? privateKeyReference,
    String? publicKeyFingerprint,
    String? keyAlgorithm,
    DateTime? identityCreatedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Identity(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      displayName: displayName ?? this.displayName,
      publicKey: publicKey ?? this.publicKey,
      privateKeyReference: privateKeyReference ?? this.privateKeyReference,
      publicKeyFingerprint: publicKeyFingerprint ?? this.publicKeyFingerprint,
      keyAlgorithm: keyAlgorithm ?? this.keyAlgorithm,
      identityCreatedAt: identityCreatedAt ?? this.identityCreatedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'device_id': deviceId,
      'display_name': displayName,
      'public_key': publicKey,
      'private_key_reference': privateKeyReference,
      'public_key_fingerprint': publicKeyFingerprint,
      'key_algorithm': keyAlgorithm,
      'identity_created_at': identityCreatedAt?.toIso8601String(),
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  factory Identity.fromMap(Map<String, dynamic> map) {
    return Identity(
      id: map['id'] as String?,
      deviceId: map['device_id'] as String,
      displayName: map['display_name'] as String,
      publicKey: map['public_key'] as String?,
      privateKeyReference: map['private_key_reference'] as String?,
      publicKeyFingerprint: map['public_key_fingerprint'] as String?,
      keyAlgorithm: map['key_algorithm'] as String?,
      identityCreatedAt: map['identity_created_at'] != null
          ? DateTime.parse(map['identity_created_at'] as String)
          : null,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'] as String)
          : null,
    );
  }
}
