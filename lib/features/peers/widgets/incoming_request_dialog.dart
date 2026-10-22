import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/services/ble/incoming_connection_request.dart';

class IncomingConnectionRequestHost extends ConsumerStatefulWidget {
  const IncomingConnectionRequestHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingConnectionRequestHost> createState() =>
      _IncomingConnectionRequestHostState();
}

class _IncomingConnectionRequestHostState
    extends ConsumerState<IncomingConnectionRequestHost> {
  bool _dialogVisible = false;
  String? _shownRequestId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _handleRequest(ref.read(bleRuntimeProvider).incomingRequest);
    });
  }

  void _handleRequest(IncomingConnectionRequest? request) {
    if (request == null) {
      if (_dialogVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_dialogVisible) return;
          Navigator.of(context, rootNavigator: true).pop();
        });
      }
      return;
    }
    if (request.requestId == _shownRequestId) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dialogVisible) return;
      final current = ref.read(bleRuntimeProvider).incomingRequest;
      if (current?.requestId != request.requestId) return;
      _show(current!);
    });
  }

  Future<void> _show(IncomingConnectionRequest request) async {
    _dialogVisible = true;
    _shownRequestId = request.requestId;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => IncomingConnectionRequestDialog(request: request),
    );
    _dialogVisible = false;
    _shownRequestId = null;
    if (!mounted) return;
    final current = ref.read(bleRuntimeProvider).incomingRequest;
    if (current != null && current.requestId == request.requestId) {
      _handleRequest(current);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<IncomingConnectionRequest?>(
      bleRuntimeProvider.select((state) => state.incomingRequest),
      (_, next) => _handleRequest(next),
    );
    return widget.child;
  }
}

class IncomingConnectionRequestDialog extends ConsumerStatefulWidget {
  const IncomingConnectionRequestDialog({super.key, required this.request});

  final IncomingConnectionRequest request;

  @override
  ConsumerState<IncomingConnectionRequestDialog> createState() =>
      _IncomingConnectionRequestDialogState();
}

class _IncomingConnectionRequestDialogState
    extends ConsumerState<IncomingConnectionRequestDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final signal = request.signalStrength;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Connection request'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${request.displayName} wants to connect to this device.'),
              const SizedBox(height: 12),
              Text('Device ID: ${request.shortId}'),
              if (signal != null) Text('Signal: $signal dBm'),
              const SizedBox(height: 12),
              Text(
                'The device name and ID were provided by the other device. '
                'They are not cryptographically verified.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actionsOverflowDirection: VerticalDirection.down,
        actions: [
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(
                    () => ref
                        .read(bleRuntimeProvider.notifier)
                        .blockIncomingRequest(request.requestId),
                  ),
            child: Text(
              'Block',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(
                    () => ref
                        .read(bleRuntimeProvider.notifier)
                        .declineIncomingRequest(request.requestId),
                  ),
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(
                    () => ref
                        .read(bleRuntimeProvider.notifier)
                        .acceptIncomingRequest(request.requestId),
                  ),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }
}
