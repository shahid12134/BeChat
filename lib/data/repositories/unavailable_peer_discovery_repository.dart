import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_discovery_repository.dart';

class UnavailablePeerDiscoveryRepository implements PeerDiscoveryRepository {
  const UnavailablePeerDiscoveryRepository();

  @override
  Stream<Peer> get peerFound => const Stream.empty();

  @override
  Future<List<Peer>> discoverPeers() async => const [];

  @override
  Future<void> startDiscovery() async {}

  @override
  Future<void> stopDiscovery() async {}
}
