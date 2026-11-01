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

  group('multi-connection per-peer presence', () {
    const other = Peer(
      peerId: 'peer-2',
      displayName: 'Bob',
      deviceName: 'Bob phone',
    );

    PeerPresenceContext multi({
      Set<String> secure = const {},
      Set<String> awaitingApproval = const {},
      Set<String> handshaking = const {},
    }) {
      return PeerPresenceContext(
        availabilityEnabled: true,
        localUnavailable: false,
        // Legacy single-link fields deliberately point at a different peer so
        // the per-peer sets must be the source of truth.
        connected: true,
        connecting: true,
        activePeerId: 'peer-legacy',
        awaitingApprovalPeerId: 'peer-legacy',
        securePeerIds: secure,
        awaitingApprovalPeerIds: awaitingApproval,
        handshakingPeerIds: handshaking,
      );
    }

    test('two peers can be connected at the same time', () {
      final ctx = multi(secure: {'peer-1', 'peer-2'});
      expect(resolvePeerPresence(peer, ctx), PeerPresence.connected);
      expect(resolvePeerPresence(other, ctx), PeerPresence.connected);
    });

    test('a peer without a link is offline regardless of other links', () {
      final ctx = multi(secure: {'peer-2'});
      expect(resolvePeerPresence(peer, ctx), PeerPresence.offline);
      expect(resolvePeerPresence(other, ctx), PeerPresence.connected);
    });

    test('approval and connection states are per peer', () {
      final ctx = multi(secure: {'peer-2'}, awaitingApproval: {'peer-1'});
      expect(resolvePeerPresence(peer, ctx), PeerPresence.awaitingApproval);
      expect(resolvePeerPresence(other, ctx), PeerPresence.connected);
    });

    test('a handshaking peer is never shown as connected', () {
      final ctx = multi(handshaking: {'peer-1'}, secure: {'peer-2'});
      expect(resolvePeerPresence(peer, ctx), PeerPresence.handshaking);
      expect(resolvePeerPresence(other, ctx), PeerPresence.connected);
    });

    test('connection wins over handshaking for the same peer', () {
      // Defensive: a peer listed in both sets (transient during publication)
      // must read as connected, never as still-connecting.
      final ctx = multi(secure: {'peer-1'}, handshaking: {'peer-1'});
      expect(resolvePeerPresence(peer, ctx), PeerPresence.connected);
    });

    test('per-peer facts do not override blocked or local unavailability', () {
      final ctx = multi(secure: {'peer-1'});
      expect(
        resolvePeerPresence(peer.copyWith(status: PeerStatus.blocked), ctx),
        PeerPresence.blocked,
      );
      expect(
        resolvePeerPresence(
          peer,
          PeerPresenceContext(
            availabilityEnabled: true,
            localUnavailable: true,
            connected: false,
            connecting: false,
            securePeerIds: {'peer-1'},
          ),
        ),
        PeerPresence.localUnavailable,
      );
    });
  });
}
