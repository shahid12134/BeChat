import 'package:flutter/material.dart';

import 'native_identity.dart';
import 'spike_self_test.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const SpikeApp());
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'BeChat crypto spike', home: const SpikePage());
  }
}

class SpikePage extends StatefulWidget {
  const SpikePage({super.key});

  @override
  State<SpikePage> createState() => _SpikePageState();
}

class _SpikePageState extends State<SpikePage> {
  final List<SpikeCheck> _checks = [];
  final NativeIdentityService _identity = const NativeIdentityService();
  NativeIdentityStatus? _identityStatus;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _refreshIdentity();
  }

  Future<void> _refreshIdentity() async {
    try {
      final status = await _identity.status();
      if (mounted) {
        setState(() => _identityStatus = status);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _identityStatus = NativeIdentityStatus(
            state: 'error',
            message: error.toString(),
          );
        });
      }
    }
  }

  Future<void> _runAll() async {
    setState(() {
      _running = true;
      _checks.clear();
    });
    final identityReport = await runNativeIdentitySelfTest();
    final noiseReport = await runNoiseSelfTest();
    final storageReport = await runSecureStorageProbe();
    if (!mounted) {
      return;
    }
    setState(() {
      _checks.addAll(identityReport.checks);
      _checks.addAll(noiseReport.checks);
      _checks.add(storageReport);
      _running = false;
    });
    await _refreshIdentity();
  }

  Future<void> _resetIdentity() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset identity?'),
        content: const Text(
          'This deletes the encrypted private-key blob and its Android '
          'Keystore wrapping key. The existing public identity cannot be '
          'recovered and peers must establish trust again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _running = true;
      _checks.clear();
    });
    String detail;
    try {
      final status = await _identity.reset();
      detail = status.toString();
    } catch (error) {
      detail = error.toString();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _checks.add(
        SpikeCheck(
          name: 'Explicit identity reset',
          passed: detail.startsWith('uninitialized'),
          detail: detail,
        ),
      );
      _running = false;
    });
    await _refreshIdentity();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BeChat crypto spike')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Feasibility spike only. This does not provide production E2EE.',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              title: Text(
                'Native identity: ${_identityStatus?.state ?? 'loading'}',
              ),
              subtitle: SelectableText(
                [
                  if (_identityStatus?.publicKeyHex != null)
                    'public=${_identityStatus!.publicKeyHex}',
                  if (_identityStatus?.fingerprintHex != null)
                    'fingerprint=${_identityStatus!.fingerprintHex}',
                  if (_identityStatus?.message != null)
                    _identityStatus!.message!,
                ].join('\n'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _running ? null : _runAll,
            child: Text(_running ? 'Running...' : 'Run self-test'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _running ? null : _resetIdentity,
            child: const Text('Reset identity'),
          ),
          const SizedBox(height: 16),
          for (final check in _checks)
            Card(
              color: check.passed
                  ? Colors.green.withValues(alpha: 0.12)
                  : Colors.red.withValues(alpha: 0.12),
              child: ListTile(
                leading: Icon(
                  check.passed ? Icons.check_circle : Icons.error,
                  color: check.passed ? Colors.green : Colors.red,
                ),
                title: Text(check.name),
                subtitle: SelectableText(check.detail),
              ),
            ),
        ],
      ),
    );
  }
}
