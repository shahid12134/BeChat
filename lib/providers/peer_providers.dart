import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/data/repositories/peer_discovery_repository.dart';
import 'package:bechat/data/repositories/mock_peer_discovery_repository.dart';
import 'package:bechat/data/repositories/unavailable_peer_discovery_repository.dart';

final peerRepositoryProvider = Provider<PeerRepository>((ref) {
  return PeerRepository();
});

PeerDiscoveryRepository createPeerDiscoveryRepository({
  bool demoEnabled = AppConstants.demoDataEnabled,
}) {
  if (!demoEnabled) return const UnavailablePeerDiscoveryRepository();
  return MockPeerDiscoveryRepository();
}

final peerDiscoveryRepositoryProvider = Provider<PeerDiscoveryRepository>((
  ref,
) {
  final repository = createPeerDiscoveryRepository();
  if (repository is MockPeerDiscoveryRepository) {
    ref.onDispose(repository.dispose);
  }
  return repository;
});

final peerListProvider =
    StateNotifierProvider<PeerListNotifier, AsyncValue<List<Peer>>>((ref) {
      return PeerListNotifier(ref.read(peerRepositoryProvider));
    });

class PeerListNotifier extends StateNotifier<AsyncValue<List<Peer>>> {
  final PeerRepository _repository;

  PeerListNotifier(this._repository) : super(const AsyncValue.loading()) {
    loadPeers();
  }

  Future<void> loadPeers() async {
    state = const AsyncValue.loading();
    try {
      final peers = await _repository.getAllPeers();
      state = AsyncValue.data(peers);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refreshPeers() async {
    try {
      final peers = await _repository.getAllPeers();
      state = AsyncValue.data(peers);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> saveDiscoveredPeers(List<Peer> peers) async {
    for (final peer in peers) {
      await _repository.upsertPeer(peer);
    }
    await refreshPeers();
  }

  Future<void> savePeer(Peer peer) async {
    await _repository.upsertPeer(peer);
    await refreshPeers();
  }

  Future<void> blockPeer(String peerId) async {
    await _repository.blockPeer(peerId);
    await refreshPeers();
  }

  Future<void> unblockPeer(String peerId) async {
    await _repository.unblockPeer(peerId);
    await refreshPeers();
  }
}

final scanningProvider = StateProvider<bool>((ref) => false);

final discoveredPeersProvider = StateProvider<List<Peer>>((ref) => []);
