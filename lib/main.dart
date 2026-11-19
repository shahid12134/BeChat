import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/app/bootstrap_host.dart';
import 'package:bechat/services/online/firebase_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // One-time Firebase startup (idempotent) before anything can touch Auth or
  // Firestore. BLE keeps working even if this is never reached.
  await FirebaseBootstrap.ensureInitialized();

  runApp(const ProviderScope(child: BootstrapHost()));
}
