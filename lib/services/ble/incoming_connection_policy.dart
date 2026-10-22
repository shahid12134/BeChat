import 'package:bechat/data/models/peer.dart';

enum IncomingConnectionDecision {
  approve,
  requestApproval,
  rejectBlocked,
  rejectDisabled,
  rejectCooldown,
}

IncomingConnectionDecision decideIncomingConnection({
  required bool locallyInitiated,
  required Peer? existingPeer,
  required bool allowNewConnections,
  required DateTime now,
  DateTime? declinedUntil,
}) {
  if (existingPeer?.isBlocked == true ||
      existingPeer?.status == PeerStatus.blocked) {
    return IncomingConnectionDecision.rejectBlocked;
  }
  if (locallyInitiated || existingPeer != null) {
    return IncomingConnectionDecision.approve;
  }
  if (declinedUntil != null && declinedUntil.isAfter(now)) {
    return IncomingConnectionDecision.rejectCooldown;
  }
  if (!allowNewConnections) {
    return IncomingConnectionDecision.rejectDisabled;
  }
  return IncomingConnectionDecision.requestApproval;
}
