import 'package:bechat/data/models/peer.dart';

enum PeerPresence {
  blocked,
  localUnavailable,
  connected,
  awaitingApproval,
  handshaking,
  offline,
}

/// Runtime facts needed to derive a saved peer's live presence.
///
/// Persisted [Peer.status] is intentionally not part of the decision except
/// for the blocked flag. Online presence must come from the live runtime.
class PeerPresenceContext {
  const PeerPresenceContext({
    required this.availabilityEnabled,
    required this.localUnavailable,
    required this.connected,
    required this.connecting,
    this.activePeerId,
    this.awaitingApprovalPeerId,
  });

  final bool availabilityEnabled;
  final bool localUnavailable;
  final bool connected;
  final bool connecting;
  final String? activePeerId;
  final String? awaitingApprovalPeerId;
}

PeerPresence resolvePeerPresence(Peer peer, PeerPresenceContext context) {
  if (peer.isBlocked || peer.status == PeerStatus.blocked) {
    return PeerPresence.blocked;
  }
  if (!context.availabilityEnabled || context.localUnavailable) {
    return PeerPresence.localUnavailable;
  }
  if (context.connected && context.activePeerId == peer.peerId) {
    return PeerPresence.connected;
  }
  if (context.awaitingApprovalPeerId == peer.peerId) {
    return PeerPresence.awaitingApproval;
  }
  if (context.connecting && context.activePeerId == peer.peerId) {
    return PeerPresence.handshaking;
  }
  return PeerPresence.offline;
}

bool isPeerPresenceConnected(PeerPresence presence) =>
    presence == PeerPresence.connected;

String peerPresenceLabel(PeerPresence presence) {
  return switch (presence) {
    PeerPresence.blocked => 'Blocked',
    PeerPresence.localUnavailable => 'Nearby messaging off',
    PeerPresence.connected => 'Connected',
    PeerPresence.awaitingApproval => 'Approval needed',
    PeerPresence.handshaking => 'Connecting...',
    PeerPresence.offline => 'Offline',
  };
}
