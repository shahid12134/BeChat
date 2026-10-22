import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:bechat/core/ble/peer_presence.dart';
import 'package:bechat/data/models/chat.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/core/widgets/avatar_widget.dart';
import 'package:bechat/core/widgets/status_indicator.dart';
import 'package:bechat/core/utils/date_utils.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/peer_providers.dart';

class ChatListItem extends ConsumerWidget {
  final Chat chat;

  const ChatListItem({super.key, required this.chat});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peersAsync = ref.watch(peerListProvider);
    final bleState = ref.watch(bleRuntimeProvider);
    final peer = peersAsync.valueOrNull
        ?.where((p) => p.peerId == chat.peerId)
        .firstOrNull;
    final peerName = peer?.displayName ?? chat.title ?? 'Unknown';
    final presence = resolvePeerPresence(
      peer ?? Peer(peerId: chat.peerId, displayName: peerName, deviceName: ''),
      bleState.presenceContext,
    );
    final isOnline = isPeerPresenceConnected(presence);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: PeerAvatar(
        name: peerName,
        avatarPath: peer?.avatarPath,
        radius: 26,
        isOnline: isOnline,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              peerName,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (chat.lastMessageTime != null)
            Text(
              AppDateUtils.formatChatTimestamp(chat.lastMessageTime),
              style: TextStyle(
                fontSize: 12,
                color: chat.unreadCount > 0
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      subtitle: Row(
        children: [
          const StatusIndicator(status: TransportStatus.local, compact: true),
          const SizedBox(width: 4),
          if (presence != PeerPresence.offline)
            Text(
              '${peerPresenceLabel(presence)} · ',
              style: TextStyle(
                fontSize: 12,
                color: isOnline
                    ? Colors.green
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          Expanded(
            child: Text(
              chat.lastMessage ?? 'No messages yet',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (chat.unreadCount > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${chat.unreadCount}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
      onTap: () {
        context.push('/chat/${chat.chatId}');
      },
    );
  }
}
