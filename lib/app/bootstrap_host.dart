import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bechat/app/app.dart';
import 'package:bechat/app/theme/app_theme.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/mock/mock_data.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';

class BootstrapHost extends StatefulWidget {
  final Future<void> Function()? bootstrap;

  const BootstrapHost({super.key, this.bootstrap});

  @override
  State<BootstrapHost> createState() => _BootstrapHostState();
}

class _BootstrapHostState extends State<BootstrapHost> {
  late Future<void> _bootstrapFuture;

  @override
  void initState() {
    super.initState();
    _startBootstrap();
  }

  void _startBootstrap() {
    final future = _runBootstrap();
    _bootstrapFuture = future;
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Future<void> _runBootstrap() async {
    final callback = widget.bootstrap ?? _initializeApp;
    await callback();
  }

  static Future<void> _initializeApp() async {
    await DatabaseHelper.database;
    final identity = await IdentityRepository().ensureIdentity();
    await PeerRepository().resetTransientPresence();
    if (AppConstants.demoDataEnabled) {
      await MockData.seedDemoData(identity);
    }
  }

  void _retry() {
    setState(_startBootstrap);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrapFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return MaterialApp(
            title: 'BeChat',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme(),
            darkTheme: AppTheme.darkTheme(),
            home: BootstrapErrorScreen(
              error: snapshot.error!,
              stackTrace: snapshot.stackTrace,
              onRetry: _retry,
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.done) {
          return const BeChatApp();
        }

        return MaterialApp(
          title: 'BeChat',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme(),
          darkTheme: AppTheme.darkTheme(),
          home: const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        );
      },
    );
  }
}

class BootstrapErrorScreen extends StatelessWidget {
  final Object error;
  final StackTrace? stackTrace;
  final VoidCallback onRetry;

  const BootstrapErrorScreen({
    super.key,
    required this.error,
    required this.onRetry,
    this.stackTrace,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BeChat')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 56,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Startup failed',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'BeChat could not initialize its local database or identity.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                '$error',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              if (stackTrace != null) ...[
                const SizedBox(height: 8),
                ExpansionTile(
                  title: const Text('Technical details'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        '$stackTrace',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
