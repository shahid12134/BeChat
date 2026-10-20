import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/message_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/providers/settings_providers.dart';
import 'package:bechat/core/constants/app_constants.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _nameController = TextEditingController();
  bool _isEditingName = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identityAsync = ref.watch(identityProvider);
    final dbInfoAsync = ref.watch(databaseInfoProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // Profile section
          _buildProfileSection(context, identityAsync),
          const Divider(height: 1),

          // Database info
          _buildDatabaseSection(context, dbInfoAsync),
          const Divider(height: 1),

          // App info
          _buildAppInfoSection(context),
          const Divider(height: 1),

          // Debug section
          _buildDebugSection(context),
        ],
      ),
    );
  }

  Widget _buildProfileSection(
    BuildContext context,
    AsyncValue<dynamic> identityAsync,
  ) {
    return identityAsync.when(
      data: (identity) => ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person)),
        title: _isEditingName
            ? TextField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Enter your name',
                  border: InputBorder.none,
                ),
                onSubmitted: (value) async {
                  if (value.trim().isNotEmpty) {
                    await ref
                        .read(identityProvider.notifier)
                        .updateDisplayName(value.trim());
                  }
                  setState(() => _isEditingName = false);
                },
              )
            : Text(identity?.displayName ?? 'Unknown'),
        subtitle: Text(identity?.deviceId ?? 'No device ID'),
        trailing: IconButton(
          icon: Icon(_isEditingName ? Icons.check : Icons.edit),
          onPressed: () {
            if (_isEditingName) {
              final value = _nameController.text.trim();
              if (value.isNotEmpty) {
                ref.read(identityProvider.notifier).updateDisplayName(value);
              }
              setState(() => _isEditingName = false);
            } else {
              _nameController.text = identity?.displayName ?? '';
              setState(() => _isEditingName = true);
            }
          },
        ),
      ),
      loading: () => const ListTile(
        leading: CircleAvatar(child: Icon(Icons.person)),
        title: Text('Loading...'),
      ),
      error: (e, _) => ListTile(
        leading: const CircleAvatar(child: Icon(Icons.error)),
        title: const Text('Error loading profile'),
        subtitle: Text('$e'),
      ),
    );
  }

  Widget _buildDatabaseSection(
    BuildContext context,
    AsyncValue<Map<String, int>> dbInfoAsync,
  ) {
    return ExpansionTile(
      leading: const Icon(Icons.storage),
      title: const Text('Database'),
      subtitle: const Text('Local SQLite database information'),
      children: [
        dbInfoAsync.when(
          data: (info) => Column(
            children: info.entries.map((entry) {
              return ListTile(
                dense: true,
                title: Text(entry.key),
                trailing: Text(
                  '${entry.value} records',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              );
            }).toList(),
          ),
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Error: $e'),
          ),
        ),
      ],
    );
  }

  Widget _buildAppInfoSection(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('App Version'),
          trailing: Text(AppConstants.appVersion),
        ),
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: const Text('Database Version'),
          trailing: Text('${AppConstants.databaseVersion}'),
        ),
        ListTile(
          leading: const Icon(Icons.code),
          title: const Text('Project'),
          trailing: const Text('BeChat Phase 2 BLE'),
        ),
      ],
    );
  }

  Widget _buildDebugSection(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.bug_report_outlined),
      title: const Text('Debug Information'),
      children: [
        const ListTile(
          dense: true,
          title: Text('Build Mode'),
          trailing: Text('Development'),
        ),
        const ListTile(
          dense: true,
          title: Text('Platform'),
          trailing: Text('Android'),
        ),
        ListTile(
          dense: true,
          title: const Text('Clear Database'),
          trailing: const Icon(Icons.delete_forever, color: Colors.red),
          onTap: () async {
            final demoNote = AppConstants.demoDataEnabled
                ? '\n\nDemo mode is enabled, so sample data may be seeded again '
                      'on a later startup.'
                : '';
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Clear Database'),
                content: Text(
                  'This will delete all peers, chats, messages, attachments, '
                  'and routing records. Your local identity will be kept.'
                  '$demoNote',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text(
                      'Clear',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              try {
                await ref.read(appDataRepositoryProvider).clearUserData();
                ref.read(discoveredPeersProvider.notifier).state = [];
                ref.invalidate(messageListProvider);
                ref.invalidate(databaseInfoProvider);
                await ref.read(chatListProvider.notifier).refreshChats();
                await ref.read(peerListProvider.notifier).refreshPeers();

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('User data cleared. Identity retained.'),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to clear data: $e')),
                  );
                }
              }
            }
          },
        ),
      ],
    );
  }
}
