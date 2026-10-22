import 'dart:async';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/app_settings.dart';
import 'package:bechat/providers/app_settings_providers.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class BleAvailabilityButton extends ConsumerStatefulWidget {
  const BleAvailabilityButton({super.key});

  @override
  ConsumerState<BleAvailabilityButton> createState() =>
      _BleAvailabilityButtonState();
}

class _BleAvailabilityButtonState extends ConsumerState<BleAvailabilityButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (AppConstants.demoDataEnabled) return const SizedBox.shrink();

    final settingsAsync = ref.watch(appSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    final runtime = ref.watch(bleRuntimeProvider);
    final enabled = settings?.bleEnabled ?? false;
    final starting =
        !_busy &&
        enabled &&
        (runtime.status == BleRuntimeStatus.idle ||
            runtime.status == BleRuntimeStatus.starting ||
            runtime.status == BleRuntimeStatus.connecting);
    final showProgress = _busy || starting;

    return IconButton(
      tooltip: _tooltip(settingsAsync, settings, runtime),
      onPressed: settingsAsync.isLoading ? null : _toggle,
      icon: showProgress
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              _icon(settingsAsync, settings, runtime),
              color: _iconColor(context, settings, runtime),
            ),
    );
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final settingsAsync = ref.read(appSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    if (settings == null) {
      _showMessage('Could not load the BeChat availability setting.');
      return;
    }
    if (!settings.bleEnabled) {
      await _setAvailability(true);
      return;
    }

    final runtime = ref.read(bleRuntimeProvider);
    switch (runtime.status) {
      case BleRuntimeStatus.unauthorized:
      case BleRuntimeStatus.bluetoothOff:
      case BleRuntimeStatus.unsupported:
      case BleRuntimeStatus.error:
        await _showStatusHelp(runtime);
        return;
      case BleRuntimeStatus.idle:
      case BleRuntimeStatus.starting:
      case BleRuntimeStatus.ready:
      case BleRuntimeStatus.scanning:
      case BleRuntimeStatus.connecting:
      case BleRuntimeStatus.connected:
        break;
    }

    if (!mounted) return;
    if (runtime.isConnected) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Turn off BeChat?'),
          content: Text(
            'Turning off BeChat will disconnect from '
            '${runtime.activePeerName ?? runtime.activePeerId ?? 'the peer'}. '
            'Saved chats and peers will stay on this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Turn Off'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _setAvailability(false);
  }

  Future<void> _setAvailability(bool enabled) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(appSettingsProvider.notifier).setBleEnabled(enabled);
      await ref
          .read(bleRuntimeProvider.notifier)
          .setAvailabilityEnabled(enabled);
    } catch (error) {
      _showMessage('Could not update BeChat availability: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showStatusHelp(BleRuntimeState runtime) async {
    if (!mounted) return;
    final status = runtime.status;
    final title = switch (status) {
      BleRuntimeStatus.bluetoothOff => 'Bluetooth is off',
      BleRuntimeStatus.unauthorized => 'Bluetooth permission required',
      BleRuntimeStatus.unsupported => 'BLE is unavailable',
      BleRuntimeStatus.error => 'BeChat could not start',
      _ => 'BeChat is offline',
    };
    final message = switch (status) {
      BleRuntimeStatus.bluetoothOff =>
        'BeChat is offline because Bluetooth is off. Turn on Bluetooth in '
            'Android settings, then tap Retry. BeChat never enables the system '
            'Bluetooth radio by itself.',
      BleRuntimeStatus.unauthorized =>
        runtime.error ??
            'Grant Nearby Devices permission so BeChat can advertise and '
                'connect.',
      BleRuntimeStatus.unsupported =>
        runtime.error ??
            'This device does not support the BLE roles BeChat needs.',
      BleRuntimeStatus.error =>
        runtime.error ?? 'The Bluetooth operation failed.',
      _ =>
        'BeChat is not advertising or scanning right now. Start it again or '
            'turn it off until you need it.',
    };

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(sheetContext).textTheme.titleLarge),
                const SizedBox(height: 12),
                Text(message),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (status == BleRuntimeStatus.unauthorized)
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          unawaited(
                            ref
                                .read(bleRuntimeProvider.notifier)
                                .openAppSettings(),
                          );
                        },
                        child: const Text('Open Settings'),
                      ),
                    if (status != BleRuntimeStatus.unsupported)
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          unawaited(
                            ref.read(bleRuntimeProvider.notifier).retry(),
                          );
                        },
                        child: const Text('Retry'),
                      ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        unawaited(_setAvailability(false));
                      },
                      child: const Text('Turn Off BeChat'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  IconData _icon(
    AsyncValue<AppSettings> settingsAsync,
    AppSettings? settings,
    BleRuntimeState runtime,
  ) {
    if (settingsAsync.hasError || settings == null) {
      return Icons.bluetooth_disabled;
    }
    if (!settings.bleEnabled) return Icons.bluetooth_disabled;
    return switch (runtime.status) {
      BleRuntimeStatus.ready ||
      BleRuntimeStatus.scanning ||
      BleRuntimeStatus.connected => Icons.bluetooth,
      BleRuntimeStatus.unauthorized => Icons.lock_outline,
      BleRuntimeStatus.bluetoothOff => Icons.bluetooth_disabled,
      BleRuntimeStatus.unsupported => Icons.phonelink_erase,
      BleRuntimeStatus.error => Icons.error_outline,
      BleRuntimeStatus.idle ||
      BleRuntimeStatus.starting ||
      BleRuntimeStatus.connecting => Icons.bluetooth_searching,
    };
  }

  Color? _iconColor(
    BuildContext context,
    AppSettings? settings,
    BleRuntimeState runtime,
  ) {
    final colors = Theme.of(context).colorScheme;
    if (settings?.bleEnabled != true) return colors.onSurfaceVariant;
    return switch (runtime.status) {
      BleRuntimeStatus.ready ||
      BleRuntimeStatus.scanning ||
      BleRuntimeStatus.connected => colors.primary,
      BleRuntimeStatus.unauthorized ||
      BleRuntimeStatus.bluetoothOff ||
      BleRuntimeStatus.unsupported ||
      BleRuntimeStatus.error => colors.error,
      BleRuntimeStatus.idle ||
      BleRuntimeStatus.starting ||
      BleRuntimeStatus.connecting => colors.onSurfaceVariant,
    };
  }

  String _tooltip(
    AsyncValue<AppSettings> settingsAsync,
    AppSettings? settings,
    BleRuntimeState runtime,
  ) {
    if (settingsAsync.hasError) {
      return 'Could not load BeChat availability';
    }
    if (settings == null) return 'Loading BeChat availability';
    if (!settings.bleEnabled) return 'BeChat is offline. Tap to turn on.';
    return switch (runtime.status) {
      BleRuntimeStatus.ready => 'BeChat is online. Tap to turn off.',
      BleRuntimeStatus.scanning =>
        'BeChat is online and scanning. Tap to turn off.',
      BleRuntimeStatus.connected =>
        'BeChat is online and connected. Tap to turn off.',
      BleRuntimeStatus.starting ||
      BleRuntimeStatus.connecting ||
      BleRuntimeStatus.idle => 'BeChat is starting. Tap to turn off.',
      BleRuntimeStatus.bluetoothOff =>
        'BeChat is offline because Bluetooth is off. Tap for help.',
      BleRuntimeStatus.unauthorized =>
        'Bluetooth permission is required. Tap for help.',
      BleRuntimeStatus.unsupported =>
        'BLE is unavailable on this device. Tap for help.',
      BleRuntimeStatus.error => 'BeChat could not start. Tap for details.',
    };
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }
}
