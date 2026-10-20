import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/features/peers/widgets/peer_list_item.dart';
import 'package:bechat/core/widgets/empty_state.dart';
import 'package:bechat/providers/peer_providers.dart';

class PeerDiscoveryScreen extends ConsumerStatefulWidget {
  const PeerDiscoveryScreen({super.key});

  @override
  ConsumerState<PeerDiscoveryScreen> createState() =>
      _PeerDiscoveryScreenState();
}

class _PeerDiscoveryScreenState extends ConsumerState<PeerDiscoveryScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _scanController;
  Object? _scanError;

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (!AppConstants.demoDataEnabled) return;
    if (ref.read(scanningProvider)) return;

    final scanningState = ref.read(scanningProvider.notifier);
    setState(() => _scanError = null);
    scanningState.state = true;
    ref.read(discoveredPeersProvider.notifier).state = [];
    _scanController.repeat();

    try {
      final discoveryRepo = ref.read(peerDiscoveryRepositoryProvider);
      final peers = await discoveryRepo.discoverPeers();
      if (!mounted) return;
      await ref.read(peerListProvider.notifier).saveDiscoveredPeers(peers);
      if (!mounted) return;
      ref.read(discoveredPeersProvider.notifier).state = peers;
    } catch (e) {
      if (mounted) setState(() => _scanError = e);
    } finally {
      if (mounted) {
        _scanController.stop();
        _scanController.reset();
      }
      scanningState.state = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isScanning = ref.watch(scanningProvider);
    final discoveredPeers = ref.watch(discoveredPeersProvider);
    final allPeersAsync = ref.watch(peerListProvider);
    final demoEnabled = AppConstants.demoDataEnabled;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Peers'),
        actions: [
          if (isScanning)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (demoEnabled)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                'Demo mode: nearby devices and discovery are simulated.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          if (demoEnabled)
            Container(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: isScanning ? null : _startScan,
                  icon: isScanning
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.bluetooth_searching),
                  label: Text(
                    isScanning ? 'Scanning...' : 'Scan for Demo Devices',
                  ),
                ),
              ),
            ),
          Expanded(
            child: _buildContent(
              context,
              isScanning: isScanning,
              discoveredPeers: discoveredPeers,
              allPeersAsync: allPeersAsync,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext context, {
    required bool isScanning,
    required List<Peer> discoveredPeers,
    required AsyncValue<List<Peer>> allPeersAsync,
  }) {
    if (isScanning) {
      return _buildScanningAnimation(context);
    }

    if (_scanError != null) {
      return EmptyState(
        type: EmptyStateType.scanFailed,
        onAction: AppConstants.demoDataEnabled ? _startScan : null,
      );
    }

    if (discoveredPeers.isNotEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: discoveredPeers.length,
        itemBuilder: (context, index) {
          return PeerListItem(peer: discoveredPeers[index]);
        },
      );
    }

    return allPeersAsync.when(
      data: (peers) {
        if (peers.isEmpty) {
          if (!AppConstants.demoDataEnabled) {
            return const EmptyState(type: EmptyStateType.discoveryUnavailable);
          }
          return EmptyState(type: EmptyStateType.noPeers, onAction: _startScan);
        }
        return _buildSavedPeers(context, peers);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error loading peers: $e')),
    );
  }

  Widget _buildScanningAnimation(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _scanController,
            builder: (context, child) {
              return Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary.withValues(
                      alpha: 0.3 + (_scanController.value * 0.7),
                    ),
                    width: 2,
                  ),
                ),
                child: Icon(
                  Icons.bluetooth_searching,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Text(
            'Scanning for simulated devices...',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Demo mode only; no Bluetooth hardware is used.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSavedPeers(BuildContext context, List<Peer> peers) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'SAVED PEERS',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: peers.length,
            itemBuilder: (context, index) {
              return PeerListItem(peer: peers[index]);
            },
          ),
        ),
      ],
    );
  }
}
