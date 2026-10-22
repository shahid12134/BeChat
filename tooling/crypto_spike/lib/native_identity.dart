import 'package:flutter/services.dart';

class NativeIdentityStatus {
  const NativeIdentityStatus({
    required this.state,
    this.publicKeyHex,
    this.fingerprintHex,
    this.message,
  });

  final String state;
  final String? publicKeyHex;
  final String? fingerprintHex;
  final String? message;

  bool get isReady => state == 'ready';

  factory NativeIdentityStatus.fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('identity status is not a map');
    }
    return NativeIdentityStatus(
      state: value['state'] as String? ?? 'error',
      publicKeyHex: value['publicKeyHex'] as String?,
      fingerprintHex: value['fingerprintHex'] as String?,
      message: value['message'] as String?,
    );
  }

  @override
  String toString() {
    final details = [
      state,
      if (fingerprintHex != null) 'fingerprint=$fingerprintHex',
      if (message != null) message!,
    ];
    return details.join(' ');
  }
}

class NativeIdentityMismatchResult {
  const NativeIdentityMismatchResult({
    required this.rejected,
    required this.status,
  });

  final bool rejected;
  final NativeIdentityStatus status;

  factory NativeIdentityMismatchResult.fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('identity mismatch result is not a map');
    }
    return NativeIdentityMismatchResult(
      rejected: value['rejected'] as bool? ?? false,
      status: NativeIdentityStatus.fromMap(value['status']),
    );
  }
}

class NativeIdentityService {
  const NativeIdentityService({
    MethodChannel channel = const MethodChannel('bechat.spike/native_identity'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<NativeIdentityStatus> status() async {
    final result = await _channel.invokeMethod<Object?>('status');
    return NativeIdentityStatus.fromMap(result);
  }

  Future<NativeIdentityStatus> provision() async {
    final result = await _channel.invokeMethod<Object?>('provision');
    return NativeIdentityStatus.fromMap(result);
  }

  Future<NativeIdentityStatus> restore() async {
    final result = await _channel.invokeMethod<Object?>('restore');
    return NativeIdentityStatus.fromMap(result);
  }

  Future<NativeIdentityStatus> reset() async {
    final result = await _channel.invokeMethod<Object?>('reset');
    return NativeIdentityStatus.fromMap(result);
  }

  Future<NativeIdentityStatus> debugDeleteBlob() async {
    final result = await _channel.invokeMethod<Object?>('debugDeleteBlob');
    return NativeIdentityStatus.fromMap(result);
  }

  Future<NativeIdentityStatus> debugCorruptBlob() async {
    final result = await _channel.invokeMethod<Object?>('debugCorruptBlob');
    return NativeIdentityStatus.fromMap(result);
  }

  Future<NativeIdentityStatus> debugDeleteKeystoreKey() async {
    final result = await _channel.invokeMethod<Object?>(
      'debugDeleteKeystoreKey',
    );
    return NativeIdentityStatus.fromMap(result);
  }

  Future<NativeIdentityMismatchResult> verifyPublicKeyMismatchRejected() async {
    final result = await _channel.invokeMethod<Object?>(
      'verifyPublicKeyMismatchRejected',
    );
    return NativeIdentityMismatchResult.fromMap(result);
  }
}
