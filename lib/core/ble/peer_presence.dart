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
///
/// The per-peer sets carry the multi-connection truth: one entry per peer
/// with a managed link or a pending approval request, each derived from that
/// peer's own link phase. When any set is non-empty they are authoritative
/// and the single-active-peer fields below are ignored, so two peers can be
/// online at once and one peer's teardown never flips another peer's
/// presence. The single fields remain for the demo/legacy single-link path.
class PeerPresenceContext {
  const PeerPresenceContext({
    required this.availabilityEnabled,
    required this.localUnavailable,
    required this.connected,
    required this.connecting,
    this.activePeerId,
    this.awaitingApprovalPeerId,
    this.securePeerIds = const {},
    this.awaitingApprovalPeerIds = const {},
    this.handshakingPeerIds = const {},
  });

  final bool availabilityEnabled;
  final bool localUnavailable;
  final bool connected;
  final bool connecting;
  final String? activePeerId;
  final String? awaitingApprovalPeerId;

  /// Peers whose own link reached the secure-ready phase — the only phase
  /// that counts as connected.
  final Set<String> securePeerIds;

  /// Peers with a pending incoming connection request awaiting this device's
  /// approval decision.
  final Set<String> awaitingApprovalPeerIds;

  /// Peers with a live link that is still connecting, handshaking or waiting
  /// for confirmation — in progress, never connected.
  final Set<String> handshakingPeerIds;
}

PeerPresence resolvePeerPresence(Peer peer, PeerPresenceContext context) {
  if (peer.isBlocked || peer.status == PeerStatus.blocked) {
    return PeerPresence.blocked;
  }
  if (!context.availabilityEnabled || context.localUnavailable) {
    return PeerPresence.localUnavailable;
  }
  // Multi-connection truth: each peer's presence comes from that peer's own
  // link, so simultaneous links never compete for one "active" slot.
  final hasPerPeerFacts =
      context.securePeerIds.isNotEmpty ||
      context.awaitingApprovalPeerIds.isNotEmpty ||
      context.handshakingPeerIds.isNotEmpty;
  if (hasPerPeerFacts) {
    if (context.securePeerIds.contains(peer.peerId)) {
      return PeerPresence.connected;
    }
    if (context.awaitingApprovalPeerIds.contains(peer.peerId)) {
      return PeerPresence.awaitingApproval;
    }
    if (context.handshakingPeerIds.contains(peer.peerId)) {
      return PeerPresence.handshaking;
    }
    return PeerPresence.offline;
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
