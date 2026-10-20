import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/core/widgets/avatar_widget.dart';
import 'package:bechat/core/utils/date_utils.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/peer_providers.dart';

class PeerDetailsScreen extends ConsumerStatefulWidget {
  final String peerId;

  const PeerDetailsScreen({super.key, required this.peerId});

  @override
  ConsumerState<PeerDetailsScreen> createState() => _PeerDetailsScreenState();
}

class _PeerDetailsScreenState extends ConsumerState<PeerDetailsScreen> {
  Future<void> _openChat(Peer peer) async {
    try {
      await ref.read(peerListProvider.notifier).savePeer(peer);
      final chat = await ref
          .read(chatRepositoryProvider)
          .getOrCreateChatForPeer(peer);
      await ref.read(chatListProvider.notifier).refreshChats();
      if (mounted) {
        context.push('/chat/${chat.chatId}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to open conversation: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final peersAsync = ref.watch(peerListProvider);

    return peersAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Peer Details')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Peer Details')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Error loading peer: $e'),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () =>
                    ref.read(peerListProvider.notifier).refreshPeers(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
      data: (peers) {
        final peer = peers.where((p) => p.peerId == widget.peerId).firstOrNull;
        if (peer == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Peer Details')),
            body: const Center(child: Text('Peer not found')),
          );
        }
        return _buildDetails(context, peer);
      },
    );
  }

  Widget _buildDetails(BuildContext context, Peer peer) {
    return Scaffold(
      appBar: AppBar(
        title: Text(peer.displayName),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'block') {
                await ref
                    .read(peerListProvider.notifier)
                    .blockPeer(peer.peerId);
                if (context.mounted) context.pop();
              } else if (value == 'unblock') {
                await ref
                    .read(peerListProvider.notifier)
                    .unblockPeer(peer.peerId);
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
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
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
            _infoRow(
              context,
              'Signal Strength',
              peer.signalStrength != null
                  ? '${peer.signalStrength} dBm'
                  : 'Unknown',
            ),
            _infoRow(
              context,
              'First Seen',
              AppDateUtils.formatFullTimestamp(peer.firstSeen),
            ),
            _infoRow(
              context,
              'Last Seen',
              AppDateUtils.formatFullTimestamp(peer.lastSeen),
            ),
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
              'Blocked',
              peer.isBlocked ? 'Yes' : 'No',
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
              onPressed: peer.isBlocked ? null : () => _openChat(peer),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Message'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.link),
              label: const Text('Pairing available in Phase 3'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                await ref
                    .read(peerListProvider.notifier)
                    .blockPeer(peer.peerId);
                if (context.mounted) context.pop();
              },
              icon: const Icon(Icons.block, color: Colors.red),
              label: const Text(
                'Block Peer',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(
    BuildContext context,
    String label,
    String value, {
    Color? valueColor,
  }) {
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
