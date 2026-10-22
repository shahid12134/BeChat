import 'package:bechat/core/ble/peer_presence.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const peer = Peer(
    peerId: 'peer-1',
    displayName: 'Alice',
    deviceName: 'Alice phone',
  );

  PeerPresenceContext context({
    bool availabilityEnabled = true,
    bool localUnavailable = false,
    bool connected = false,
    bool connecting = false,
    String? activePeerId,
    String? awaitingApprovalPeerId,
  }) {
    return PeerPresenceContext(
      availabilityEnabled: availabilityEnabled,
      localUnavailable: localUnavailable,
      connected: connected,
      connecting: connecting,
      activePeerId: activePeerId,
      awaitingApprovalPeerId: awaitingApprovalPeerId,
    );
  }

  test('blocked wins over every runtime state', () {
    final blocked = peer.copyWith(status: PeerStatus.blocked);
    expect(
      resolvePeerPresence(
        blocked,
        context(
          localUnavailable: true,
          connected: true,
          activePeerId: peer.peerId,
        ),
      ),
      PeerPresence.blocked,
    );
    expect(
      resolvePeerPresence(
        peer.copyWith(isBlocked: true),
        context(connected: true, activePeerId: peer.peerId),
      ),
      PeerPresence.blocked,
    );
  });

  test('local unavailability wins over a stale connected state', () {
    expect(
      resolvePeerPresence(
        peer,
        context(
          localUnavailable: true,
          connected: true,
          activePeerId: peer.peerId,
        ),
      ),
      PeerPresence.localUnavailable,
    );
    expect(
      resolvePeerPresence(
        peer,
        context(
          availabilityEnabled: false,
          connected: true,
          activePeerId: peer.peerId,
        ),
      ),
      PeerPresence.localUnavailable,
    );
  });

  test('connected requires the matching active peer', () {
    expect(
      resolvePeerPresence(
        peer,
        context(connected: true, activePeerId: 'peer-other'),
      ),
      PeerPresence.offline,
    );
    expect(
      resolvePeerPresence(
        peer,
        context(connected: true, activePeerId: peer.peerId),
      ),
      PeerPresence.connected,
    );
  });

  test('approval and handshake states are peer specific', () {
    expect(
      resolvePeerPresence(
        peer,
        context(
          connecting: true,
          activePeerId: peer.peerId,
          awaitingApprovalPeerId: peer.peerId,
        ),
      ),
      PeerPresence.awaitingApproval,
    );
    expect(
      resolvePeerPresence(
        peer,
        context(connecting: true, activePeerId: peer.peerId),
      ),
      PeerPresence.handshaking,
    );
  });

  test('persisted online status is not live presence', () {
    expect(
      resolvePeerPresence(peer.copyWith(status: PeerStatus.online), context()),
      PeerPresence.offline,
    );
  });
}
