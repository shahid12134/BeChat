import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/data/models/app_settings.dart';
import 'package:bechat/providers/app_settings_providers.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/identity_initialization_providers.dart';
import 'package:bechat/providers/message_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/providers/settings_providers.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:bechat/services/crypto/identity_initialization_coordinator.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _nameController = TextEditingController();
  bool _isEditingName = false;
  bool _backgroundBusy = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identityAsync = ref.watch(identityProvider);
    final identityStatus = ref.watch(identityInitializationProvider);
    final dbInfoAsync = ref.watch(databaseInfoProvider);
    final runtime = ref.watch(bleRuntimeProvider);
    final settings = ref.watch(appSettingsProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // Profile section
          _buildProfileSection(context, identityAsync),
          _buildCryptographicIdentitySection(context, identityStatus),
          const Divider(height: 1),

          _buildBackgroundSection(context, runtime, settings),
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

  Widget _buildCryptographicIdentitySection(
    BuildContext context,
    IdentityInitializationStatus status,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final showRetry =
        status.isDegraded &&
        status.state != IdentityInitializationState.unsupportedPlatform;

    return ListTile(
      leading: Icon(
        status.isReady
            ? Icons.verified_user_outlined
            : Icons.gpp_maybe_outlined,
        color: status.isReady
            ? Colors.green
            : status.state == IdentityInitializationState.initializing
            ? colorScheme.onSurfaceVariant
            : colorScheme.error,
      ),
      title: const Text('Cryptographic identity'),
      subtitle: Text(status.message),
      trailing: showRetry
          ? TextButton(
              onPressed: () async {
                try {
                  await ref
                      .read(identityInitializationProvider.notifier)
                      .initialize();
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Identity initialization could not start.',
                        ),
                      ),
                    );
                  }
                }
              },
              child: const Text('Retry'),
            )
          : null,
    );
  }

  Widget _buildBackgroundSection(
    BuildContext context,
    BleRuntimeState runtime,
    AppSettings? settings,
  ) {
    final enabled = settings?.backgroundBleEnabled == true;
    final previewsEnabled = settings?.messagePreviewsEnabled == true;
    final permissionDenied =
        runtime.backgroundStatus == BackgroundBleRuntimeStatus.permissionDenied;
    final needsAttention =
        runtime.backgroundStatus == BackgroundBleRuntimeStatus.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Background',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.notifications_active_outlined),
          title: const Text('Background messaging'),
          subtitle: Text(_backgroundStatusText(runtime)),
          trailing: Switch.adaptive(
            value: enabled,
            onChanged: _backgroundBusy
                ? null
                : (value) => unawaited(_toggleBackground(value)),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.visibility_outlined),
          title: const Text('Message previews'),
          subtitle: const Text(
            'Show message text in notifications. Sender names are always shown.',
          ),
          trailing: Switch.adaptive(
            value: previewsEnabled,
            onChanged: settings == null
                ? null
                : (value) => ref
                      .read(appSettingsProvider.notifier)
                      .setMessagePreviewsEnabled(value),
          ),
        ),
        if (permissionDenied)
          ListTile(
            leading: const Icon(Icons.notifications_off_outlined),
            title: const Text('Notification permission needed'),
            subtitle: const Text(
              'Android requires a visible notification for background mode.',
            ),
            trailing: TextButton(
              onPressed: () => ref
                  .read(bleRuntimeProvider.notifier)
                  .openNotificationSettings(),
              child: const Text('Open settings'),
            ),
          ),
        if (needsAttention)
          ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text('Background mode needs attention'),
            trailing: TextButton(
              onPressed: () => ref
                  .read(bleRuntimeProvider.notifier)
                  .reconcileBackgroundBle(),
              child: const Text('Retry'),
            ),
          ),
        const ListTile(
          leading: Icon(Icons.battery_saver_outlined),
          title: Text('Android battery limits'),
          subtitle: Text(
            'Android may pause background work to save battery. Keep BeChat '
            'open for the most reliable nearby messaging.',
          ),
        ),
      ],
    );
  }

  String _backgroundStatusText(BleRuntimeState runtime) {
    final error = runtime.backgroundError;
    return switch (runtime.backgroundStatus) {
      BackgroundBleRuntimeStatus.disabled =>
        'Off. Nearby messaging pauses when BeChat leaves the foreground.',
      BackgroundBleRuntimeStatus.starting => 'Starting background mode...',
      BackgroundBleRuntimeStatus.active =>
        'On. BeChat can receive nearby messages while minimized.',
      BackgroundBleRuntimeStatus.paused =>
        error ?? 'Paused. Background mode starts when BeChat is online.',
      BackgroundBleRuntimeStatus.permissionDenied =>
        error ?? 'Notification permission is required.',
      BackgroundBleRuntimeStatus.error =>
        error ?? 'Background mode stopped. Open BeChat to restart.',
    };
  }

  Future<void> _toggleBackground(bool enabled) async {
    setState(() => _backgroundBusy = true);
    final runtime = ref.read(bleRuntimeProvider.notifier);
    final result = enabled
        ? await runtime.enableBackgroundBle()
        : await runtime.disableBackgroundBle();
    if (!mounted) return;
    setState(() => _backgroundBusy = false);
    final message = result.message;
    if (message == null || message.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: result.permissionDenied
            ? SnackBarAction(
                label: 'Settings',
                onPressed: runtime.openNotificationSettings,
              )
            : null,
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
