import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final bleRuntimeProvider =
    StateNotifierProvider<BleRuntimeController, BleRuntimeState>((ref) {
      return BleRuntimeController(ref);
    });
