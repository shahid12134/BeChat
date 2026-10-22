import 'package:bechat/services/background/background_ble_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final backgroundBleServiceProvider = Provider<BackgroundBleService>((ref) {
  final service = MethodChannelBackgroundBleService();
  ref.onDispose(service.dispose);
  return service;
});
