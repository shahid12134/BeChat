import 'package:flutter/material.dart';

enum EmptyStateType { noChats, noPeers, noMessages, scanFailed }

class EmptyState extends StatelessWidget {
  final EmptyStateType type;
  final VoidCallback? onAction;

  const EmptyState({super.key, required this.type, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_icon, size: 80, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 24),
            Text(_title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_subtitle, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            if (onAction != null && _buttonLabel != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onAction,
                icon: Icon(_buttonIcon),
                label: Text(_buttonLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData get _icon => switch (type) {
    EmptyStateType.noChats => Icons.chat_bubble_outline,
    EmptyStateType.noPeers => Icons.bluetooth_searching,
    EmptyStateType.noMessages => Icons.message_outlined,
    EmptyStateType.scanFailed => Icons.error_outline,
  };

  String get _title => switch (type) {
    EmptyStateType.noChats => 'No conversations yet',
    EmptyStateType.noPeers => 'No peers found',
    EmptyStateType.noMessages => 'No messages yet',
    EmptyStateType.scanFailed => 'Scan failed',
  };

  String get _subtitle => switch (type) {
    EmptyStateType.noChats => 'Start a conversation with a nearby peer to get started.',
    EmptyStateType.noPeers => 'Make sure Bluetooth is enabled and tap scan to discover nearby BeChat devices.',
    EmptyStateType.noMessages => 'Send a message to start the conversation.',
    EmptyStateType.scanFailed => 'Unable to scan for peers. Check your Bluetooth settings and try again.',
  };

  String? get _buttonLabel => switch (type) {
    EmptyStateType.noChats => 'Discover Peers',
    EmptyStateType.noPeers => 'Scan Again',
    EmptyStateType.noMessages => null,
    EmptyStateType.scanFailed => 'Retry Scan',
  };

  IconData? get _buttonIcon => switch (type) {
    EmptyStateType.noChats => Icons.bluetooth_searching,
    EmptyStateType.noPeers => Icons.refresh,
    EmptyStateType.noMessages => null,
    EmptyStateType.scanFailed => Icons.refresh,
  };
}
