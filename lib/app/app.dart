import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/app/app_messenger.dart';
import 'package:bechat/app/theme/app_theme.dart';
import 'package:bechat/app/routes/app_router.dart';
import 'package:bechat/services/background/background_action_coordinator.dart';

class BeChatApp extends ConsumerStatefulWidget {
  const BeChatApp({super.key});

  @override
  ConsumerState<BeChatApp> createState() => _BeChatAppState();
}

class _BeChatAppState extends ConsumerState<BeChatApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(backgroundActionCoordinatorProvider).initialize());
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'BeChat',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: appMessengerKey,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: ThemeMode.system,
      routerConfig: goRouter,
    );
  }
}
