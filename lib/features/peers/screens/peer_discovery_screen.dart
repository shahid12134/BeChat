import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:bechat/core/constants/app_constants.dart';
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

class _PeerDiscoveryScreenState extends ConsumerState<PeerDiscoveryScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _scanController;
  Object? _scanError;
  String? _connectingId;
  bool _savingConnectionSetting = false;

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
    setState(() => _scanError = null);
    if (!AppConstants.demoDataEnabled) {
      await ref.read(bleRuntimeProvider.notifier).startScan();
      return;
    }
    if (ref.read(scanningProvider)) return;

    final scanningState = ref.read(scanningProvider.notifier);
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
      _showError('Unable to open the conversation: $error');
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  Future<void> _openActiveChat() async {
    final peerId = ref.read(bleRuntimeProvider).activePeerId;
    if (peerId == null) return;
    final peer = await ref.read(peerRepositoryProvider).getPeerByPeerId(peerId);
    if (peer == null) {
      _showError('The connected peer is not stored yet.');
      return;
    }
    final chat = await ref
        .read(chatRepositoryProvider)
        .getOrCreateChatForPeer(peer);
    await ref.read(chatListProvider.notifier).refreshChats();
    if (mounted) context.push('/chat/${chat.chatId}');
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
      _showError('Could not save the connection setting: $error');
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
    ref.listen(bleRuntimeProvider, (previous, next) {
      if (demoEnabled) return;
      if (next.status == BleRuntimeStatus.scanning) {
        if (!_scanController.isAnimating) _scanController.repeat();
      } else if (_scanController.isAnimating) {
        _scanController.stop();
        _scanController.reset();
      }
    });
    final isDemoScanning = ref.watch(scanningProvider);
    final isScanning = demoEnabled
        ? isDemoScanning
        : bleState.status == BleRuntimeStatus.scanning;
    final discoveredPeers = ref.watch(discoveredPeersProvider);
    final allPeersAsync = ref.watch(peerListProvider);
    final appSettingsAsync = ref.watch(appSettingsProvider);

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
            )
          else if (!bleState.isConnected)
            IconButton(
              tooltip: 'Scan for peers',
              onPressed: _startScan,
              icon: const Icon(Icons.bluetooth_searching),
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
                'Demo mode: nearby devices and discovery are simulated. '
                'No Bluetooth hardware is used.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          if (!demoEnabled) _buildConnectionSettings(context, appSettingsAsync),
          if (!demoEnabled)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.45,
              ),
              child: SingleChildScrollView(
                child: _buildBleBanner(context, bleState),
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
            child: demoEnabled
                ? _buildDemoContent(
                    context,
                    isScanning: isScanning,
                    discoveredPeers: discoveredPeers,
                    allPeersAsync: allPeersAsync,
                  )
                : _buildRealContent(context, bleState, allPeersAsync),
          ),
        ],
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
              : 'Allow unknown nearby devices to request a connection.',
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
    if (bleState.isConnected) {
      return Container(
        width: double.infinity,
        color: theme.colorScheme.primaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.bluetooth_connected),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connected to ${bleState.activePeerName ?? bleState.activePeerId}',
                    style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'App identity exchanged over BLE. This is not '
                    'cryptographic authentication.',
                    style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _openActiveChat,
              child: const Text('Message'),
            ),
            IconButton(
              tooltip: 'Disconnect',
              onPressed: () =>
                  ref.read(bleRuntimeProvider.notifier).disconnect(),
              icon: const Icon(Icons.link_off),
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
    if (bleState.status == BleRuntimeStatus.connecting) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
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
    if (bleState.status == BleRuntimeStatus.scanning) {
      return _buildScanningAnimation(
        context,
        title: 'Scanning for BeChat devices...',
        subtitle:
            'This phone is advertising while it scans. '
            'Range and Android BLE scanning limits apply.',
      );
    }
    if (bleState.status == BleRuntimeStatus.ready &&
        bleState.candidates.isEmpty) {
      return allPeersAsync.when(
        data: (peers) => peers.isEmpty
            ? EmptyState(type: EmptyStateType.noPeers, onAction: _startScan)
            : _buildSavedPeers(context, peers),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error loading peers: $e')),
      );
    }

    return allPeersAsync.when(
      data: (peers) {
        final showSaved = bleState.candidates.isEmpty && peers.isNotEmpty;
        if (showSaved) return _buildSavedPeers(context, peers);
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
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
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error loading peers: $e')),
    );
  }

  Widget _buildDemoContent(
    BuildContext context, {
    required bool isScanning,
    required List<Peer> discoveredPeers,
    required AsyncValue<List<Peer>> allPeersAsync,
  }) {
    if (isScanning) {
      return _buildScanningAnimation(
        context,
        title: 'Scanning for simulated devices...',
        subtitle: 'Demo mode only; no Bluetooth hardware is used.',
      );
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
        return _buildSavedPeers(context, peers);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error loading peers: $e')),
    );
  }

  Widget _buildScanningAnimation(
    BuildContext context, {
    required String title,
    required String subtitle,
  }) {
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
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
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
        const _SectionLabel(
          label: 'SAVED PEERS',
          detail: 'Saved only after a valid BLE identity handshake',
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
