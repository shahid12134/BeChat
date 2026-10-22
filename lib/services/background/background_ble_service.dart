import 'dart:async';

import 'package:flutter/services.dart';

enum BackgroundBleEventType {
  acceptConnectionRequest,
  declineConnectionRequest,
  blockConnectionRequest,
  openChat,
  serviceFailed,
}

class BackgroundBleEvent {
  const BackgroundBleEvent({
    required this.type,
    this.eventId,
    this.requestId,
    this.chatId,
    this.message,
  });

  final BackgroundBleEventType type;
  final String? eventId;
  final String? requestId;
  final String? chatId;
  final String? message;

  String get dedupeKey =>
      eventId ?? '${type.name}:${requestId ?? ''}:${chatId ?? ''}';
}

class BackgroundNotificationPolicy {
  const BackgroundNotificationPolicy._();

  static String messageBody({
    required bool previewsEnabled,
    required String content,
  }) {
    return previewsEnabled ? content : 'New message';
  }
}

class BackgroundBlePlatformStatus {
  const BackgroundBlePlatformStatus({
    required this.supported,
    required this.notificationsAllowed,
    required this.serviceRunning,
  });

  final bool supported;
  final bool notificationsAllowed;
  final bool serviceRunning;

  static const unsupported = BackgroundBlePlatformStatus(
    supported: false,
    notificationsAllowed: false,
    serviceRunning: false,
  );
}

abstract class BackgroundBleService {
  Stream<BackgroundBleEvent> get events;

  Future<void> initialize();

  Future<BackgroundBlePlatformStatus> getStatus();

  Future<bool> requestNotificationPermission();

  Future<void> openNotificationSettings();

  Future<void> startService({required String statusText});

  Future<void> updateService({required String statusText});

  Future<void> stopService();

  Future<void> showMessageNotification({
    required String messageId,
    required String chatId,
    required String senderName,
    required String body,
  });

  Future<void> showConnectionRequestNotification({
    required String requestId,
    required String peerName,
  });

  Future<void> cancelConnectionRequestNotification(String requestId);
}

class MethodChannelBackgroundBleService implements BackgroundBleService {
  MethodChannelBackgroundBleService({
    MethodChannel? channel,
    this.permissionTimeout = const Duration(seconds: 30),
  }) : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'bechat/background';

  final MethodChannel _channel;
  final Duration permissionTimeout;
  final StreamController<BackgroundBleEvent> _events =
      StreamController<BackgroundBleEvent>.broadcast();
  bool _initialized = false;

  @override
  Stream<BackgroundBleEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      final pending = await _channel.invokeListMethod<Object?>('initialize');
      for (final item in pending ?? const <Object?>[]) {
        final event = _decodeEvent(item);
        if (event != null) _events.add(event);
      }
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'backgroundEvent') return null;
    final event = _decodeEvent(call.arguments);
    if (event != null) _events.add(event);
    return null;
  }

  BackgroundBleEvent? _decodeEvent(Object? value) {
    if (value is! Map) return null;
    final typeName = value['type'];
    final type = switch (typeName) {
      'acceptConnectionRequest' =>
        BackgroundBleEventType.acceptConnectionRequest,
      'declineConnectionRequest' =>
        BackgroundBleEventType.declineConnectionRequest,
      'blockConnectionRequest' => BackgroundBleEventType.blockConnectionRequest,
      'openChat' => BackgroundBleEventType.openChat,
      'serviceFailed' => BackgroundBleEventType.serviceFailed,
      _ => null,
    };
    if (type == null) return null;
    return BackgroundBleEvent(
      type: type,
      eventId: _string(value['eventId']),
      requestId: _string(value['requestId']),
      chatId: _string(value['chatId']),
      message: _string(value['message']),
    );
  }

  String? _string(Object? value) => value is String ? value : null;

  @override
  Future<BackgroundBlePlatformStatus> getStatus() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getStatus',
      );
      if (result == null) return BackgroundBlePlatformStatus.unsupported;
      return BackgroundBlePlatformStatus(
        supported: result['supported'] == true,
        notificationsAllowed: result['notificationsAllowed'] == true,
        serviceRunning: result['serviceRunning'] == true,
      );
    } on MissingPluginException {
      return BackgroundBlePlatformStatus.unsupported;
    } on PlatformException {
      return BackgroundBlePlatformStatus.unsupported;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      final granted = await _channel
          .invokeMethod<bool>('requestNotificationPermission')
          .timeout(permissionTimeout, onTimeout: () => false);
      return granted == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> openNotificationSettings() async {
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> startService({required String statusText}) async {
    await _invoke('startService', {'statusText': statusText});
  }

  @override
  Future<void> updateService({required String statusText}) async {
    await _invoke('updateService', {'statusText': statusText});
  }

  @override
  Future<void> stopService() async {
    await _invoke('stopService', const {});
  }

  @override
  Future<void> showMessageNotification({
    required String messageId,
    required String chatId,
    required String senderName,
    required String body,
  }) async {
    await _invoke('showMessageNotification', {
      'messageId': messageId,
      'chatId': chatId,
      'senderName': senderName,
      'body': body,
    });
  }

  @override
  Future<void> showConnectionRequestNotification({
    required String requestId,
    required String peerName,
  }) async {
    await _invoke('showConnectionRequestNotification', {
      'requestId': requestId,
      'peerName': peerName,
    });
  }

  @override
  Future<void> cancelConnectionRequestNotification(String requestId) async {
    await _invoke('cancelConnectionRequestNotification', {
      'requestId': requestId,
    });
  }

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      throw const BackgroundBleServiceException(
        'Android background support is not available on this platform.',
      );
    } on PlatformException catch (error) {
      throw BackgroundBleServiceException(
        error.message ?? 'Android background operation failed.',
      );
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}

class BackgroundBleServiceException implements Exception {
  const BackgroundBleServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
