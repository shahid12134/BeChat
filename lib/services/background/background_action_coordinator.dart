import 'dart:async';

import 'package:bechat/app/app_messenger.dart';
import 'package:bechat/app/routes/app_router.dart';
import 'package:bechat/providers/background_service_provider.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/services/background/background_ble_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final backgroundActionCoordinatorProvider =
    Provider<BackgroundActionCoordinator>((ref) {
      final coordinator = BackgroundActionCoordinator(ref);
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

class BackgroundActionCoordinator {
  BackgroundActionCoordinator(this._ref);

  final Ref _ref;
  final Set<String> _seenEvents = {};
  StreamSubscription<BackgroundBleEvent>? _subscription;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final service = _ref.read(backgroundBleServiceProvider);
    _subscription = service.events.listen(_handleEvent);
    await service.initialize();
  }

  Future<void> _handleEvent(BackgroundBleEvent event) async {
    if (!_seenEvents.add(event.dedupeKey)) return;
    if (_seenEvents.length > 100) {
      _seenEvents.remove(_seenEvents.first);
    }
    final runtime = _ref.read(bleRuntimeProvider.notifier);
    switch (event.type) {
      case BackgroundBleEventType.acceptConnectionRequest:
        final requestId = event.requestId;
        if (requestId == null) return;
        try {
          await runtime.acceptIncomingRequest(requestId);
        } catch (_) {
          await _cancelNotification(requestId);
        }
        return;
      case BackgroundBleEventType.declineConnectionRequest:
        final requestId = event.requestId;
        if (requestId == null) return;
        try {
          await runtime.declineIncomingRequest(requestId);
        } catch (_) {
          await _cancelNotification(requestId);
        }
        return;
      case BackgroundBleEventType.blockConnectionRequest:
        final requestId = event.requestId;
        if (requestId == null) return;
        try {
          await runtime.blockIncomingRequest(requestId);
        } catch (_) {
          await _cancelNotification(requestId);
        }
        return;
      case BackgroundBleEventType.openChat:
        final chatId = event.chatId;
        if (chatId == null || chatId.isEmpty) return;
        goRouter.push('/chat/${Uri.encodeComponent(chatId)}');
        return;
      case BackgroundBleEventType.serviceFailed:
        runtime.markBackgroundServiceFailed(
          event.message?.trim().isNotEmpty == true
              ? event.message!
              : 'Background mode stopped unexpectedly.',
        );
        appMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text(
              'Background messaging stopped. Open BeChat to restart.',
            ),
          ),
        );
    }
  }

  Future<void> _cancelNotification(String requestId) async {
    try {
      await _ref
          .read(backgroundBleServiceProvider)
          .cancelConnectionRequestNotification(requestId);
    } catch (_) {}
  }

  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
