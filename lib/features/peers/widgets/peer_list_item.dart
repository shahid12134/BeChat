import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:bechat/core/ble/peer_presence.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/core/widgets/avatar_widget.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/peer_providers.dart';

class PeerListItem extends ConsumerWidget {
  final Peer peer;

  const PeerListItem({super.key, required this.peer});

  Future<void> _startChat(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(peerListProvider.notifier).savePeer(peer);
      final chat = await ref
          .read(chatRepositoryProvider)
          .getOrCreateChatForPeer(peer);
      await ref.read(chatListProvider.notifier).refreshChats();
      if (context.mounted) {
        context.push('/chat/${chat.chatId}');
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to open conversation: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bleState = ref.watch(bleRuntimeProvider);
    final presence = resolvePeerPresence(peer, bleState.presenceContext);
    final isOnline = isPeerPresenceConnected(presence);
    // This peer's own link carries its signal strength. When no per-link
    // snapshot exists (legacy single-link view), fall back to the active-peer
    // signal — but only for that active peer, so one peer's RSSI never leaks
    // into another peer's row.
    final peerLink = bleState.linkFor(peer.peerId);
    final signalStrength = isOnline
        ? peerLink?.signalStrength ??
              (bleState.activePeerId == peer.peerId
                  ? bleState.activeSignalStrength
                  : null) ??
              peer.signalStrength
        : peer.signalStrength;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: PeerAvatar(
        name: peer.displayName,
        avatarPath: peer.avatarPath,
        radius: 24,
        isOnline: isOnline,
      ),
      title: Text(
        peer.displayName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Row(
        children: [
          if (signalStrength != null) ...[
            Icon(
              _signalIcon(signalStrength),
              size: 14,
              color: _signalColor(signalStrength),
            ),
            const SizedBox(width: 4),
            Text(
              '$signalStrength dBm',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            peerPresenceLabel(presence),
            style: TextStyle(
              fontSize: 12,
              color: isOnline
                  ? Colors.green
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              peer.deviceName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.chat_bubble_outline),
        tooltip: 'Message',
        onPressed: () => _startChat(context, ref),
      ),
      onTap: () => context.push('/peer/${peer.peerId}'),
    );
  }

  IconData _signalIcon(int strength) {
    if (strength >= -50) return Icons.signal_cellular_alt;
    if (strength >= -70) return Icons.signal_cellular_alt_2_bar;
    return Icons.signal_cellular_alt_1_bar;
  }

  Color _signalColor(int strength) {
    if (strength >= -50) return Colors.green;
    if (strength >= -70) return Colors.orange;
    return Colors.red;
  }
}
