enum RouteStatus { queued, inTransit, delivered, failed, expired }

class MessageRoute {
  final String? id;
  final String messageId;
  final String? nextHop;
  final String targetPeer;
  final int ttl;
  final int attemptCount;
  final RouteStatus status;
  final DateTime? queuedAt;
  final DateTime? updatedAt;

  const MessageRoute({
    this.id,
    required this.messageId,
    this.nextHop,
    required this.targetPeer,
    this.ttl = 86400,
    this.attemptCount = 0,
    this.status = RouteStatus.queued,
    this.queuedAt,
    this.updatedAt,
  });

  MessageRoute copyWith({
    String? id,
    String? messageId,
    String? nextHop,
    String? targetPeer,
    int? ttl,
    int? attemptCount,
    RouteStatus? status,
    DateTime? queuedAt,
    DateTime? updatedAt,
  }) {
    return MessageRoute(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      nextHop: nextHop ?? this.nextHop,
      targetPeer: targetPeer ?? this.targetPeer,
      ttl: ttl ?? this.ttl,
      attemptCount: attemptCount ?? this.attemptCount,
      status: status ?? this.status,
      queuedAt: queuedAt ?? this.queuedAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'message_id': messageId,
      'next_hop': nextHop,
      'target_peer': targetPeer,
      'ttl': ttl,
      'attempt_count': attemptCount,
      'status': status.name,
      'queued_at': queuedAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  factory MessageRoute.fromMap(Map<String, dynamic> map) {
    return MessageRoute(
      id: map['id'] as String?,
      messageId: map['message_id'] as String,
      nextHop: map['next_hop'] as String?,
      targetPeer: map['target_peer'] as String,
      ttl: (map['ttl'] as int?) ?? 86400,
      attemptCount: (map['attempt_count'] as int?) ?? 0,
      status: RouteStatus.values.firstWhere(
        (e) => e.name == map['status'],
        orElse: () => RouteStatus.queued,
      ),
      queuedAt: map['queued_at'] != null
          ? DateTime.parse(map['queued_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'] as String)
          : null,
    );
  }
}
