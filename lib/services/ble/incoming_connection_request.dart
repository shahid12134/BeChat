class IncomingConnectionRequest {
  const IncomingConnectionRequest({
    required this.requestId,
    required this.peerId,
    required this.displayName,
    required this.deviceName,
    required this.requestedAt,
    required this.expiresAt,
    this.signalStrength,
  });

  final String requestId;
  final String peerId;
  final String displayName;
  final String deviceName;
  final int? signalStrength;
  final DateTime requestedAt;
  final DateTime expiresAt;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  String get shortId {
    if (peerId.length <= 8) return peerId;
    return peerId.substring(peerId.length - 8);
  }
}
