import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:bechat/core/ble/ble_link_phase.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/core/utils/error_formatter.dart';
import 'package:bechat/core/widgets/ble_availability_button.dart';
import 'package:bechat/core/widgets/empty_state.dart';
import 'package:bechat/data/models/app_settings.dart';
import 'package:bechat/data/models/ble_candidate.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/features/peers/widgets/peer_list_item.dart';
import 'package:bechat/providers/app_settings_providers.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/services/ble/ble_runtime.dart';

class PeerDiscoveryScreen extends ConsumerStatefulWidget {
  const PeerDiscoveryScreen({super.key});

  @override
  ConsumerState<PeerDiscoveryScreen> createState() =>
      _PeerDiscoveryScreenState();
}

class _PeerDiscoveryScreenState extends ConsumerState<PeerDiscoveryScreen> {
  Object? _scanError;
  String? _connectingId;
  bool _savingConnectionSetting = false;

  Future<void> _startScan() async {
    setState(() => _scanError = null);
    if (!AppConstants.demoDataEnabled) {
      final settings = ref.read(appSettingsProvider).valueOrNull;
      if (settings == null) {
        _showError('Could not load the BeChat availability setting.');
        return;
      }
      if (!settings.bleEnabled) {
        final enable = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Turn on BeChat?'),
            content: const Text(
              'Scanning and advertising are off while BeChat is offline. '
              'Turn on BeChat to look for nearby devices? This does not change '
              'the system Bluetooth switch.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Turn On'),
              ),
            ],
          ),
        );
        if (enable != true || !mounted) return;
        await _setAvailability(true);
        if (!mounted) return;
      }
      final currentSettings = ref.read(appSettingsProvider).valueOrNull;
      if (currentSettings == null || !currentSettings.bleEnabled) return;

      await ref.read(bleRuntimeProvider.notifier).startScan();
      if (!mounted) return;
      final bleState = ref.read(bleRuntimeProvider);
      if (bleState.status != BleRuntimeStatus.scanning &&
          bleState.status != BleRuntimeStatus.ready &&
          bleState.status != BleRuntimeStatus.connected) {
        _showError(bleState.error ?? 'Unable to start scanning.');
      }
      return;
    }
    if (ref.read(scanningProvider)) return;

    final scanningState = ref.read(scanningProvider.notifier);
    scanningState.state = true;
    ref.read(discoveredPeersProvider.notifier).state = [];

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
      scanningState.state = false;
    }
  }

  Future<void> _setAvailability(bool enabled) async {
    try {
      await ref.read(appSettingsProvider.notifier).setBleEnabled(enabled);
      await ref
          .read(bleRuntimeProvider.notifier)
          .setAvailabilityEnabled(enabled);
    } catch (error) {
      _showError('Could not update BeChat availability: '
          '${describeErrorForUser(error)}');
    }
  }

  Future<void> _stopScan() async {
    await ref.read(bleRuntimeProvider.notifier).stopScan();
  }

  Future<void> _connect(BleCandidate candidate) async {
    if (_connectingId != null) return;
    setState(() => _connectingId = candidate.id);
    try {
      final peerId = await ref
          .read(bleRuntimeProvider.notifier)
          .connectToCandidate(candidate.id);
      if (peerId == null) {
        if (mounted) {
          final error = ref.read(bleRuntimeProvider).error;
          _showError(error ?? 'Unable to connect to that device.');
        }
        return;
      }
      final peer = await ref
          .read(peerRepositoryProvider)
          .getPeerByPeerId(peerId);
      if (peer == null) {
        _showError('The peer handshake completed, but the peer was not saved.');
        return;
      }
      final chat = await ref
          .read(chatRepositoryProvider)
          .getOrCreateChatForPeer(peer);
      await ref.read(chatListProvider.notifier).refreshChats();
      if (mounted) context.push('/chat/${chat.chatId}');
    } catch (error) {
      _showError('Unable to open the conversation: '
          '${describeErrorForUser(error)}');
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  Future<void> _openChatWithPeer(String peerId) async {
    final peer = await ref.read(peerRepositoryProvider).getPeerByPeerId(peerId);
    if (peer == null) {
      _showError('That peer is not saved yet.');
      return;
    }
    final chat = await ref
        .read(chatRepositoryProvider)
        .getOrCreateChatForPeer(peer);
    await ref.read(chatListProvider.notifier).refreshChats();
    if (mounted) context.push('/chat/${chat.chatId}');
  }

  Future<void> _disconnectPeer(String peerId) async {
    await ref.read(bleRuntimeProvider.notifier).disconnectPeer(peerId);
  }

  Future<void> _setAllowNewConnections(bool value) async {
    if (_savingConnectionSetting) return;
    setState(() => _savingConnectionSetting = true);
    try {
      await ref
          .read(appSettingsProvider.notifier)
          .setAllowNewConnections(value);
      if (!value) {
        await ref
            .read(bleRuntimeProvider.notifier)
            .declinePendingIncomingRequest();
      }
    } catch (error) {
      _showError('Could not save the connection setting: '
          '${describeErrorForUser(error)}');
    } finally {
      if (mounted) setState(() => _savingConnectionSetting = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final demoEnabled = AppConstants.demoDataEnabled;
    final bleState = ref.watch(bleRuntimeProvider);
    final isDemoScanning = ref.watch(scanningProvider);
    final isScanning = demoEnabled
        ? isDemoScanning
        : bleState.status == BleRuntimeStatus.scanning;
    final discoveredPeers = ref.watch(discoveredPeersProvider);
    final allPeersAsync = ref.watch(peerListProvider);
    final appSettingsAsync = ref.watch(appSettingsProvider);
    final settings = appSettingsAsync.valueOrNull;
    final beChatEnabled = settings?.bleEnabled ?? false;
    final operationInProgress =
        bleState.status == BleRuntimeStatus.starting ||
        bleState.status == BleRuntimeStatus.connecting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Peers'),
        actions: const [BleAvailabilityButton()],
      ),
      body: demoEnabled
          ? Column(
              children: [
                Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Text(
                    'Demo mode: nearby devices and discovery are simulated. '
                    'No Bluetooth hardware is used.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
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
                  child: _buildDemoContent(
                    context,
                    isScanning: isScanning,
                    discoveredPeers: discoveredPeers,
                    allPeersAsync: allPeersAsync,
                  ),
                ),
              ],
            )
          : SingleChildScrollView(
              child: Column(
                children: [
                  _buildAvailabilityCard(
                    context,
                    appSettingsAsync,
                    beChatEnabled,
                  ),
                  _buildConnectionSettings(context, appSettingsAsync),
                  _buildScanControl(
                    context,
                    enabled: beChatEnabled,
                    isScanning: isScanning,
                    isStarting: bleState.status == BleRuntimeStatus.starting,
                    operationInProgress: operationInProgress,
                  ),
                  _buildBleBanner(context, bleState),
                  _buildRealContent(context, bleState, allPeersAsync),
                ],
              ),
            ),
    );
  }

  Widget _buildAvailabilityCard(
    BuildContext context,
    AsyncValue<AppSettings> settingsAsync,
    bool enabled,
  ) {
    final theme = Theme.of(context);
    if (settingsAsync.hasError) {
      return Card(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: ListTile(
          leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
          title: const Text('Availability setting unavailable'),
          subtitle: const Text(
            'Could not load the BeChat availability setting. Restart the app '
            'and try again.',
          ),
        ),
      );
    }
    if (settingsAsync.isLoading || enabled) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.power_settings_new),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'BeChat is offline',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Nearby discovery and incoming connections are off. '
                    'Saved chats and peers are still available.',
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _setAvailability(true),
              child: const Text('Turn On'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanControl(
    BuildContext context, {
    required bool enabled,
    required bool isScanning,
    required bool isStarting,
    required bool operationInProgress,
  }) {
    // Scanning stays available while links are active: the multi-connection
    // runtime keeps discovery running alongside live connections so another
    // peer can be found and connected without dropping existing links.
    final canScan = !isScanning && !operationInProgress;
    final showProgress = isScanning || isStarting;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Nearby Scan',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: isScanning
                      ? _stopScan
                      : canScan
                      ? _startScan
                      : null,
                  icon: Icon(isScanning ? Icons.stop : Icons.refresh),
                  label: Text(isScanning ? 'Stop Scanning' : 'Scan'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (showProgress) ...[
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 8),
            ],
            Text(
              isScanning
                  ? 'Scanning for nearby BeChat devices. Results refresh as '
                        'advertisements arrive.'
                  : isStarting
                  ? 'Starting BeChat before the scan begins.'
                  : enabled
                  ? 'Scans stop automatically after '
                        '${AppConstants.scanTimeout.inSeconds} seconds. '
                        'Recently seen devices remain for '
                        '${AppConstants.candidateExpiration.inSeconds} seconds. '
                        'Scanning works while connected to other peers.'
                  : 'Turn on BeChat to scan. Scanning never enables BeChat by '
                        'itself.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionSettings(
    BuildContext context,
    AsyncValue<AppSettings> settingsAsync,
  ) {
    final settings = settingsAsync.valueOrNull;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: SwitchListTile(
        secondary: const Icon(Icons.person_add_alt_1),
        title: const Text('Allow New Connections'),
        subtitle: Text(
          settingsAsync.hasError
              ? 'Could not load this setting. Restart BeChat and try again.'
              : 'Allow unknown nearby devices to request a connection while '
                    'BeChat is on.',
        ),
        value:
            settings?.allowNewConnections ??
            AppConstants.defaultAllowNewConnections,
        onChanged: settings == null || _savingConnectionSetting
            ? null
            : _setAllowNewConnections,
      ),
    );
  }

  Widget _buildBleBanner(BuildContext context, BleRuntimeState bleState) {
    final theme = Theme.of(context);
    if (bleState.links.isNotEmpty) {
      final secureCount = bleState.links.where((l) => l.isSecureReady).length;
      return Container(
        width: double.infinity,
        color: theme.colorScheme.primaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  secureCount > 0
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_searching,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    secureCount > 0
                        ? '$secureCount secure connection'
                              '${secureCount == 1 ? '' : 's'}'
                        : '${bleState.links.length} device'
                              '${bleState.links.length == 1 ? '' : 's'} '
                              'connecting',
                    style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final link in bleState.links) ...[
              _LinkRow(
                link: link,
                onMessage: link.isSecureReady && link.peerId != null
                    ? () => _openChatWithPeer(link.peerId!)
                    : null,
                onDisconnect: link.peerId != null
                    ? () => _disconnectPeer(link.peerId!)
                    : null,
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Secure means the Noise handshake finished and the peer '
              'identity was confirmed. Only secure links carry messages.',
              style: TextStyle(
                color: theme.colorScheme.onPrimaryContainer,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }
    if (bleState.status == BleRuntimeStatus.unauthorized) {
      return _statusCard(
        icon: Icons.lock_outline,
        title: 'Bluetooth permission required',
        message:
            bleState.error ??
            'Grant Nearby Devices permission to use BLE messaging.',
        actionLabel: 'Open Settings',
        onAction: () => ref.read(bleRuntimeProvider.notifier).openAppSettings(),
        secondaryLabel: 'Retry',
        onSecondary: () => ref.read(bleRuntimeProvider.notifier).retry(),
      );
    }
    if (bleState.status == BleRuntimeStatus.bluetoothOff) {
      return _statusCard(
        icon: Icons.bluetooth_disabled,
        title: 'Bluetooth is off',
        message:
            'Turn on Bluetooth on this phone, then tap Retry. BeChat does not '
            'run BLE in the background.',
        actionLabel: 'Retry',
        onAction: () => ref.read(bleRuntimeProvider.notifier).retry(),
      );
    }
    if (bleState.status == BleRuntimeStatus.unsupported) {
      return _statusCard(
        icon: Icons.phonelink_erase,
        title: 'BLE is unavailable',
        message:
            'This device or platform does not support the central and '
            'peripheral BLE roles required by BeChat.',
      );
    }
    if (bleState.status == BleRuntimeStatus.error) {
      return _statusCard(
        icon: Icons.error_outline,
        title: 'Bluetooth error',
        message: bleState.error ?? 'The BLE operation failed.',
        actionLabel: 'Retry',
        onAction: () => ref.read(bleRuntimeProvider.notifier).retry(),
      );
    }
    if (bleState.status == BleRuntimeStatus.starting) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    return const SizedBox.shrink();
  }

  Widget _statusCard({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    String? secondaryLabel,
    VoidCallback? onSecondary,
  }) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(message),
            if ((actionLabel != null && onAction != null) ||
                (secondaryLabel != null && onSecondary != null)) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  if (actionLabel != null && onAction != null)
                    FilledButton(onPressed: onAction, child: Text(actionLabel)),
                  if (secondaryLabel != null && onSecondary != null)
                    OutlinedButton(
                      onPressed: onSecondary,
                      child: Text(secondaryLabel),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRealContent(
    BuildContext context,
    BleRuntimeState bleState,
    AsyncValue<List<Peer>> allPeersAsync,
  ) {
    // The full-screen connecting placeholder belongs to the first connection;
    // once any link is secure the list stays visible so other peers can be
    // managed and connected while this one continues in the banner above.
    if (bleState.status == BleRuntimeStatus.connecting &&
        !bleState.hasSecureLink) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Connecting to ${bleState.activePeerName ?? 'BeChat device'}...',
            ),
            const SizedBox(height: 8),
            const Text(
              'Completing the application identity handshake.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
    }
    return allPeersAsync.when(
      data: (peers) {
        if (bleState.candidates.isEmpty && peers.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: EmptyState(
              type: EmptyStateType.noPeers,
              onAction: _startScan,
            ),
          );
        }
        final showSaved = bleState.candidates.isEmpty && peers.isNotEmpty;
        if (showSaved) return _buildSavedPeers(context, peers);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (bleState.candidates.isNotEmpty) ...[
              const _SectionLabel(
                label: 'NEARBY DEVICES',
                detail: 'BLE discovery hints; not saved peers yet',
              ),
              ...bleState.candidates.map(
                (candidate) => _CandidateTile(
                  candidate: candidate,
                  connecting: _connectingId == candidate.id,
                  onTap: _connectingId == null
                      ? () => _connect(candidate)
                      : null,
                ),
              ),
            ],
            if (peers.isNotEmpty) ...[
              const SizedBox(height: 8),
              const _SectionLabel(
                label: 'SAVED PEERS',
                detail: 'Identity exchanged previously over BLE',
              ),
              ...peers.map((peer) => PeerListItem(peer: peer)),
            ],
            const SizedBox(height: 16),
          ],
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text('Could not load peers: ${describeErrorForUser(e)}'),
        ),
      ),
    );
  }

  Widget _buildDemoContent(
    BuildContext context, {
    required bool isScanning,
    required List<Peer> discoveredPeers,
    required AsyncValue<List<Peer>> allPeersAsync,
  }) {
    if (isScanning) {
      return const Center(child: Text('Scanning for simulated devices...'));
    }

    if (_scanError != null) {
      return EmptyState(type: EmptyStateType.scanFailed, onAction: _startScan);
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
          return EmptyState(type: EmptyStateType.noPeers, onAction: _startScan);
        }
        return _buildSavedPeers(context, peers, scrollable: true);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Could not load peers: ${describeErrorForUser(e)}'),
      ),
    );
  }

  Widget _buildSavedPeers(
    BuildContext context,
    List<Peer> peers, {
    bool scrollable = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel(
          label: 'SAVED PEERS',
          detail: 'Saved only after a valid BLE identity handshake',
        ),
        if (scrollable)
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: peers.length,
              itemBuilder: (context, index) {
                return PeerListItem(peer: peers[index]);
              },
            ),
          )
        else ...[
          ...peers.map((peer) => PeerListItem(peer: peer)),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.detail});

  final String label;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          if (detail != null)
            Text(
              detail!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.candidate,
    required this.connecting,
    required this.onTap,
  });

  final BleCandidate candidate;
  final bool connecting;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        child: connecting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.bluetooth),
      ),
      title: Text(candidate.displayName),
      subtitle: Text(
        'BLE ID ${candidate.shortId} • ${candidate.rssi} dBm\n'
        'Discovery hint only; app identity is exchanged after connecting.',
        style: const TextStyle(fontSize: 12),
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

/// One managed link inside the connections banner: the peer's name, its own
/// independent phase chip and its per-peer Message and Disconnect actions.
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.link, this.onMessage, this.onDisconnect});

  final BlePeerLinkState link;
  final VoidCallback? onMessage;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = link.displayName ?? link.deviceName ?? 'BeChat device';
    final chipColor = switch (link.phase) {
      BleLinkPhase.secureReady => Colors.green,
      BleLinkPhase.failed => theme.colorScheme.error,
      BleLinkPhase.awaitingAuthorization => Colors.orange,
      _ => theme.colorScheme.onPrimaryContainer,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: chipColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        bleLinkPhaseLabel(link.phase),
                        style: TextStyle(
                          color: chipColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (link.signalStrength != null)
                      Text(
                        '${link.signalStrength} dBm',
                        style: TextStyle(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                if (link.error != null)
                  Text(
                    link.error!,
                    style: TextStyle(
                      color: theme.colorScheme.onErrorContainer,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          if (onMessage != null)
            TextButton(onPressed: onMessage, child: const Text('Message')),
          if (onDisconnect != null)
            IconButton(
              tooltip: 'Disconnect',
              onPressed: onDisconnect,
              icon: const Icon(Icons.link_off),
            ),
        ],
      ),
    );
  }
}
