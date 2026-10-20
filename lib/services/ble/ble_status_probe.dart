import 'package:flutter/services.dart';

class BlePlatformStatus {
  const BlePlatformStatus({
    required this.sdkInt,
    required this.scan,
    required this.connect,
    required this.advertise,
    required this.location,
    required this.permissionsGranted,
    required this.bluetoothEnabled,
    required this.leSupported,
    required this.advertisingSupported,
  });

  final int sdkInt;
  final bool scan;
  final bool connect;
  final bool advertise;
  final bool location;
  final bool permissionsGranted;
  final bool bluetoothEnabled;
  final bool leSupported;
  final bool advertisingSupported;

  bool get requiredPermissionsGranted {
    if (sdkInt >= 31) {
      return scan && connect && advertise;
    }
    return location;
  }

  factory BlePlatformStatus.fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('BLE status response must be a map.');
    }

    final map = value.cast<Object?, Object?>();

    int readInt(String key) {
      final field = map[key];
      if (field is int) return field;
      throw FormatException('BLE status field "$key" must be an integer.');
    }

    bool readBool(String key) {
      final field = map[key];
      if (field is bool) return field;
      throw FormatException('BLE status field "$key" must be a boolean.');
    }

    final sdkInt = readInt('sdkInt');
    if (sdkInt < 1) {
      throw const FormatException('BLE status sdkInt must be positive.');
    }

    final status = BlePlatformStatus(
      sdkInt: sdkInt,
      scan: readBool('scan'),
      connect: readBool('connect'),
      advertise: readBool('advertise'),
      location: readBool('location'),
      permissionsGranted: readBool('permissionsGranted'),
      bluetoothEnabled: readBool('bluetoothEnabled'),
      leSupported: readBool('leSupported'),
      advertisingSupported: readBool('advertisingSupported'),
    );

    if (status.permissionsGranted != status.requiredPermissionsGranted) {
      throw const FormatException(
        'BLE status reported inconsistent permission values.',
      );
    }

    return status;
  }
}

abstract interface class BleStatusProbe {
  Future<BlePlatformStatus> getStatus();
}

class BleStatusProbeException implements Exception {
  const BleStatusProbeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MethodChannelBleStatusProbe implements BleStatusProbe {
  MethodChannelBleStatusProbe({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('bechat/ble_status');

  final MethodChannel _channel;

  @override
  Future<BlePlatformStatus> getStatus() async {
    try {
      final result = await _channel.invokeMethod<Object?>('getStatus');
      return BlePlatformStatus.fromMap(result);
    } on BleStatusProbeException {
      rethrow;
    } on MissingPluginException {
      throw const BleStatusProbeException(
        'The Android BLE status check is unavailable. Rebuild and reinstall '
        'the app, then tap Retry.',
      );
    } on PlatformException catch (error) {
      final detail = error.message ?? error.code;
      throw BleStatusProbeException(
        'The Android BLE status check failed: $detail',
      );
    } on FormatException catch (error) {
      throw BleStatusProbeException(
        'The Android BLE status response was invalid: ${error.message}',
      );
    }
  }
}
