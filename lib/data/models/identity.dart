class Identity {
  final String? id;
  final String deviceId;
  final String displayName;
  final String? publicKey;
  final String? privateKeyReference;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Identity({
    this.id,
    required this.deviceId,
    required this.displayName,
    this.publicKey,
    this.privateKeyReference,
    this.createdAt,
    this.updatedAt,
  });

  Identity copyWith({
    String? id,
    String? deviceId,
    String? displayName,
    String? publicKey,
    String? privateKeyReference,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Identity(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      displayName: displayName ?? this.displayName,
      publicKey: publicKey ?? this.publicKey,
      privateKeyReference: privateKeyReference ?? this.privateKeyReference,
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
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'] as String)
          : null,
    );
  }
}
