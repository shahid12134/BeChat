import 'package:bechat/data/models/peer.dart';
import 'package:bechat/services/ble/incoming_connection_policy.dart';
import 'package:bechat/services/ble/incoming_connection_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 22, 12);

  test('unknown inbound peers require approval by default', () {
    expect(
      decideIncomingConnection(
        locallyInitiated: false,
        existingPeer: null,
        allowNewConnections: true,
        now: now,
      ),
      IncomingConnectionDecision.requestApproval,
    );
  });

  test('saved peers reconnect without another prompt', () {
    const peer = Peer(
      peerId: 'peer-alice',
      displayName: 'Alice',
      deviceName: 'Alice Phone',
    );

    expect(
      decideIncomingConnection(
        locallyInitiated: false,
        existingPeer: peer,
        allowNewConnections: false,
        now: now,
      ),
      IncomingConnectionDecision.approve,
    );
  });

  test('locally initiated connections keep the existing workflow', () {
    expect(
      decideIncomingConnection(
        locallyInitiated: true,
        existingPeer: null,
        allowNewConnections: false,
        now: now,
      ),
      IncomingConnectionDecision.approve,
    );
  });

  test('blocked peers are always rejected', () {
    const peer = Peer(
      peerId: 'peer-blocked',
      displayName: 'Blocked',
      deviceName: 'Blocked Phone',
      status: PeerStatus.blocked,
      isBlocked: true,
    );

    expect(
      decideIncomingConnection(
        locallyInitiated: true,
        existingPeer: peer,
        allowNewConnections: true,
        now: now,
      ),
      IncomingConnectionDecision.rejectBlocked,
    );
  });

  test('disabled new connections reject unknown peers', () {
    expect(
      decideIncomingConnection(
        locallyInitiated: false,
        existingPeer: null,
        allowNewConnections: false,
        now: now,
      ),
      IncomingConnectionDecision.rejectDisabled,
    );
  });

  test('recently declined peers stay rejected until the cooldown expires', () {
    expect(
      decideIncomingConnection(
        locallyInitiated: false,
        existingPeer: null,
        allowNewConnections: true,
        now: now,
        declinedUntil: now.add(const Duration(seconds: 1)),
      ),
      IncomingConnectionDecision.rejectCooldown,
    );
    expect(
      decideIncomingConnection(
        locallyInitiated: false,
        existingPeer: null,
        allowNewConnections: true,
        now: now,
        declinedUntil: now.subtract(const Duration(seconds: 1)),
      ),
      IncomingConnectionDecision.requestApproval,
    );
  });

  test('incoming requests expose a short id and expire', () {
    final current = DateTime.now();
    final request = IncomingConnectionRequest(
      requestId: 'request-1',
      peerId: 'device-1234567890abcdef',
      displayName: 'Alice',
      deviceName: 'Alice Phone',
      requestedAt: current,
      expiresAt: current.add(const Duration(seconds: 30)),
    );

    expect(request.shortId, '90abcdef');
    expect(request.isExpired, isFalse);
    expect(
      IncomingConnectionRequest(
        requestId: 'request-2',
        peerId: 'peer-bob',
        displayName: 'Bob',
        deviceName: 'Bob Phone',
        requestedAt: current,
        expiresAt: current.subtract(const Duration(seconds: 1)),
      ).isExpired,
      isTrue,
    );
  });
}
