import 'package:bechat/data/models/peer.dart';

abstract class PeerDiscoveryRepository {
  Future<List<Peer>> discoverPeers();
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
  Stream<Peer> get peerFound;
}
