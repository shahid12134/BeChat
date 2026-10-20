class BleCandidate {
  const BleCandidate({
    required this.id,
    required this.displayName,
    required this.rssi,
    required this.lastSeen,
    this.isSimulated = false,
  });

  final String id;
  final String displayName;
  final int rssi;
  final DateTime lastSeen;
  final bool isSimulated;

  String get shortId {
    final normalized = id.replaceAll('-', '');
    return normalized.length <= 8
        ? normalized
        : normalized.substring(normalized.length - 8);
  }

  BleCandidate copyWith({
    String? displayName,
    int? rssi,
    DateTime? lastSeen,
    bool? isSimulated,
  }) {
    return BleCandidate(
      id: id,
      displayName: displayName ?? this.displayName,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
      isSimulated: isSimulated ?? this.isSimulated,
    );
  }
}
