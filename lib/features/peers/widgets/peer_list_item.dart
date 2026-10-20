import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/core/widgets/avatar_widget.dart';

class PeerListItem extends ConsumerWidget {
  final Peer peer;
  final bool showSaved;

  const PeerListItem({super.key, required this.peer, this.showSaved = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOnline = peer.status == PeerStatus.online;

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
          if (peer.signalStrength != null) ...[
            Icon(
              _signalIcon(peer.signalStrength!),
              size: 14,
              color: _signalColor(peer.signalStrength!),
            ),
            const SizedBox(width: 4),
            Text(
              '${peer.signalStrength} dBm',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            peer.deviceName,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      trailing: showSaved
          ? null
          : ElevatedButton(
              onPressed: () {},
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
              ),
              child: const Text('Pair', style: TextStyle(fontSize: 12)),
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
