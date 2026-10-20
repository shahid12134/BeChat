import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/core/widgets/avatar_widget.dart';
import 'package:bechat/core/utils/date_utils.dart';
import 'package:bechat/providers/peer_providers.dart';

class PeerDetailsScreen extends ConsumerStatefulWidget {
  final String peerId;

  const PeerDetailsScreen({super.key, required this.peerId});

  @override
  ConsumerState<PeerDetailsScreen> createState() => _PeerDetailsScreenState();
}

class _PeerDetailsScreenState extends ConsumerState<PeerDetailsScreen> {
  @override
  Widget build(BuildContext context) {
    final peersAsync = ref.watch(peerListProvider);
    final peer = peersAsync.valueOrNull?.where((p) => p.peerId == widget.peerId).firstOrNull;

    if (peer == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Peer Details')),
        body: const Center(child: Text('Peer not found')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(peer.displayName),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'block') {
                await ref.read(peerListProvider.notifier).blockPeer(peer.peerId);
                if (context.mounted) context.pop();
              } else if (value == 'unblock') {
                await ref.read(peerListProvider.notifier).unblockPeer(peer.peerId);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: peer.isBlocked ? 'unblock' : 'block',
                child: ListTile(
                  leading: Icon(
                    peer.isBlocked ? Icons.lock_open : Icons.block,
                    color: peer.isBlocked ? Colors.green : Colors.red,
                  ),
                  title: Text(peer.isBlocked ? 'Unblock' : 'Block'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 24),
            PeerAvatar(
              name: peer.displayName,
              avatarPath: peer.avatarPath,
              radius: 48,
              isOnline: peer.status == PeerStatus.online,
            ),
            const SizedBox(height: 16),
            Text(
              peer.displayName,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              peer.deviceName,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: _statusColor(peer.status).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                peer.status.name.toUpperCase(),
                style: TextStyle(
                  color: _statusColor(peer.status),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 24),
            _buildInfoSection(context, peer),
            const SizedBox(height: 24),
            _buildSecuritySection(context, peer),
            const SizedBox(height: 24),
            _buildActions(context, peer),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoSection(BuildContext context, Peer peer) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DEVICE INFORMATION',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
            ),
            const SizedBox(height: 12),
            _infoRow(context, 'Device ID', peer.peerId),
            _infoRow(context, 'Signal Strength', peer.signalStrength != null ? '${peer.signalStrength} dBm' : 'Unknown'),
            _infoRow(context, 'First Seen', AppDateUtils.formatFullTimestamp(peer.firstSeen)),
            _infoRow(context, 'Last Seen', AppDateUtils.formatFullTimestamp(peer.lastSeen)),
          ],
        ),
      ),
    );
  }

  Widget _buildSecuritySection(BuildContext context, Peer peer) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SECURITY',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
            ),
            const SizedBox(height: 12),
            _infoRow(
              context,
              'Public Key',
              peer.publicKey ?? 'Not exchanged',
              valueColor: peer.publicKey != null ? Colors.green : Colors.orange,
            ),
            _infoRow(
              context,
              'Encryption',
              'Pending Phase 3',
              valueColor: Colors.orange,
            ),
            _infoRow(
              context,
              'Pairing Status',
              peer.isBlocked ? 'Blocked' : 'Available',
              valueColor: peer.isBlocked ? Colors.red : Colors.green,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context, Peer peer) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: peer.isBlocked ? null : () {
                // TODO Phase 3: Implement actual pairing
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Pairing will be available in Phase 3')),
                );
              },
              icon: const Icon(Icons.link),
              label: const Text('Pair / Connect'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                await ref.read(peerListProvider.notifier).blockPeer(peer.peerId);
                if (context.mounted) context.pop();
              },
              icon: const Icon(Icons.block, color: Colors.red),
              label: const Text('Block Peer', style: TextStyle(color: Colors.red)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 14,
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 14,
                color: valueColor,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  Color _statusColor(PeerStatus status) => switch (status) {
    PeerStatus.online => Colors.green,
    PeerStatus.offline => Colors.grey,
    PeerStatus.pairing => Colors.orange,
    PeerStatus.blocked => Colors.red,
  };
}
