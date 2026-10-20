import 'dart:async';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_discovery_repository.dart';

class MockPeerDiscoveryRepository implements PeerDiscoveryRepository {
  final _peerController = StreamController<Peer>.broadcast();
  bool _isDiscovering = false;

  static final List<Peer> _mockPeers = [
    Peer(
      peerId: 'peer-alice-001',
      displayName: 'Alice',
      deviceName: "Alice's Phone",
      status: PeerStatus.online,
      signalStrength: -45,
      firstSeen: DateTime.now().subtract(const Duration(hours: 2)),
      lastSeen: DateTime.now(),
    ),
    Peer(
      peerId: 'peer-rahul-002',
      displayName: 'Rahul',
      deviceName: "Rahul's Phone",
      status: PeerStatus.online,
      signalStrength: -62,
      firstSeen: DateTime.now().subtract(const Duration(hours: 5)),
      lastSeen: DateTime.now().subtract(const Duration(minutes: 5)),
    ),
    Peer(
      peerId: 'peer-device-003',
      displayName: 'BeChat Lab Device',
      deviceName: 'BeChat Device 01',
      status: PeerStatus.offline,
      signalStrength: -78,
      firstSeen: DateTime.now().subtract(const Duration(days: 3)),
      lastSeen: DateTime.now().subtract(const Duration(hours: 1)),
    ),
    Peer(
      peerId: 'peer-cyber-004',
      displayName: 'Cyber Lab',
      deviceName: 'Cyber Lab Device',
      status: PeerStatus.online,
      signalStrength: -55,
      firstSeen: DateTime.now().subtract(const Duration(days: 1)),
      lastSeen: DateTime.now().subtract(const Duration(minutes: 2)),
    ),
    Peer(
      peerId: 'peer-maria-005',
      displayName: 'Maria',
      deviceName: "Maria's Phone",
      status: PeerStatus.offline,
      signalStrength: -88,
      firstSeen: DateTime.now().subtract(const Duration(days: 7)),
      lastSeen: DateTime.now().subtract(const Duration(hours: 3)),
    ),
  ];

  @override
  Stream<Peer> get peerFound => _peerController.stream;

  @override
  Future<List<Peer>> discoverPeers() async {
    if (_isDiscovering) return [];
    await startDiscovery();
    await Future.delayed(const Duration(seconds: 2));
    await stopDiscovery();
    return List.from(_mockPeers);
  }

  @override
  Future<void> startDiscovery() async {
    _isDiscovering = true;
    // Simulate discovery with staggered peer appearances
    for (final peer in _mockPeers) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!_isDiscovering) break;
      _peerController.add(peer);
    }
  }

  @override
  Future<void> stopDiscovery() async {
    _isDiscovering = false;
  }

  void dispose() {
    _peerController.close();
  }
}
