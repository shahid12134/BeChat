import 'package:flutter/material.dart';

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
  bool _running = false;

  Future<void> _runAll() async {
    setState(() {
      _running = true;
      _checks.clear();
    });
    final noiseReport = await runNoiseSelfTest();
    final storageReport = await runSecureStorageProbe();
    if (!mounted) {
      return;
    }
    setState(() {
      _checks.addAll(noiseReport.checks);
      _checks.add(storageReport);
      _running = false;
    });
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
          FilledButton(
            onPressed: _running ? null : _runAll,
            child: Text(_running ? 'Running...' : 'Run self-test'),
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
