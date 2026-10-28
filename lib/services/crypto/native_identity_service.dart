import 'package:flutter/services.dart';
import 'package:bechat/services/crypto/native_crypto_backend.dart';

/// Non-secret identity states reported by the native identity subsystem.
///
/// [unknown] is used when the platform reports a state this build does not
/// recognize, so an unexpected value can never be mistaken for `ready`.
enum NativeIdentityState {
  /// No cryptographic identity exists yet on this installation.
  uninitialized,

  /// A Noise static identity is installed and its public key is available.
  ready,

  /// Public metadata exists but the encrypted private-key blob is gone.
  blobMissing,

  /// The encrypted blob is malformed or failed authenticated decryption.
  blobCorrupt,

  /// The encrypted blob has an envelope version or algorithm this build cannot read.
  blobUnsupported,

  /// The Android Keystore wrapping key is missing or invalidated.
  keyUnavailable,

  /// The non-secret public metadata is missing, malformed or inconsistent.
  metadataInvalid,

  /// The recovered private seed does not match the expected public identity.
  mismatch,

  /// The native identity backend failed to initialize.
  nativeError,

  /// The identity could not be persisted or read from device storage.
  storeFailed,

  /// A state this Dart build does not recognize.
  unknown,
}

/// Non-secret identity status.
///
/// This type has no field that can hold a private seed, a wrapping key or
/// encrypted blob bytes: those never leave the Kotlin/Rust boundary.
class NativeIdentityStatus {
  const NativeIdentityStatus({
    required this.state,
    this.publicKeyHex,
    this.fingerprintHex,
    this.message,
  });

  final NativeIdentityState state;

  /// Lowercase-hex Noise public identity, present only when [state] is [NativeIdentityState.ready].
  final String? publicKeyHex;

  /// Lowercase-hex SHA-256 fingerprint of the public identity, when available.
  final String? fingerprintHex;

  /// Fixed, non-secret explanation supplied by the platform.
  final String? message;

  /// Whether a validated identity is installed and ready for later phases.
  bool get isReady => state == NativeIdentityState.ready;

  factory NativeIdentityStatus.fromMap(Map<Object?, Object?> map) {
    return NativeIdentityStatus(
      state: _stateFromString(map['state']),
      publicKeyHex: _hexOrNull(map['publicKeyHex']),
      fingerprintHex: _hexOrNull(map['fingerprintHex']),
      message: map['message'] is String ? map['message']! as String : null,
    );
  }

  static NativeIdentityState _stateFromString(Object? value) {
    switch (value) {
      case 'uninitialized':
        return NativeIdentityState.uninitialized;
      case 'ready':
        return NativeIdentityState.ready;
      case 'blob_missing':
        return NativeIdentityState.blobMissing;
      case 'blob_corrupt':
        return NativeIdentityState.blobCorrupt;
      case 'blob_unsupported':
        return NativeIdentityState.blobUnsupported;
      case 'key_unavailable':
        return NativeIdentityState.keyUnavailable;
      case 'metadata_invalid':
        return NativeIdentityState.metadataInvalid;
      case 'mismatch':
        return NativeIdentityState.mismatch;
      case 'native_error':
        return NativeIdentityState.nativeError;
      case 'store_failed':
        return NativeIdentityState.storeFailed;
      default:
        return NativeIdentityState.unknown;
    }
  }

  static String? _hexOrNull(Object? value) {
    if (value is! String) return null;
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(value) ? value : null;
  }

  @override
  String toString() => 'NativeIdentityStatus(${state.name})';
}

/// The narrow native identity surface the initialization coordinator depends
/// on.
///
/// Declared separately so coordinator tests can supply a fake without a
/// MethodChannel. It deliberately has no seed-, blob- or byte-level members.
abstract interface class NativeIdentityGateway {
  /// Provisions a first identity when none exists, otherwise restores the
  /// established identity. Never replaces an existing identity.
  Future<NativeIdentityStatus> initialize();

  /// Reports the current non-secret state without provisioning anything.
  Future<NativeIdentityStatus> status();
}

/// Flutter-facing identity service.
///
/// Exposes only: initialize/restore, status, public identity and fingerprint
/// (through [NativeIdentityStatus]) and an explicitly confirmed reset. The
/// byte-level identity operations — seed generation, seed installation and
/// Keystore wrapping — are unreachable from Dart by design; calling this
/// service never creates or modifies the application database.
///
/// Application bootstrap reaches this only through
/// `IdentityInitializationCoordinator`, which decides between provisioning and
/// restoring from the persisted SQLite identity state.
class NativeIdentityService implements NativeIdentityGateway {
  NativeIdentityService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'bechat/native_identity';
  static const String initializeMethod = 'initialize';
  static const String statusMethod = 'status';
  static const String resetMethod = 'reset';
  static const String resetConfirmArgument = 'confirm';

  final MethodChannel _channel;

  /// Provisions a first identity when none exists, otherwise restores the
  /// established identity. Never replaces an existing identity.
  @override
  Future<NativeIdentityStatus> initialize() => _invoke(initializeMethod);

  /// Reports the current non-secret state without provisioning anything.
  @override
  Future<NativeIdentityStatus> status() => _invoke(statusMethod);

  /// Destructively resets the cryptographic identity.
  ///
  /// Requires explicit confirmation: without it the call is refused here,
  /// before any platform channel traffic, and the identity is left untouched.
  /// A future UI must collect that confirmation from the user.
  Future<NativeIdentityStatus> reset({required bool confirm}) async {
    if (!confirm) {
      // Refused here, before any platform traffic; the Future fails rather
      // than throwing synchronously so callers see one error shape.
      throw const NativeCryptoBackendException(
        'Resetting the cryptographic identity requires explicit confirmation.',
      );
    }
    return _invoke(resetMethod, <String, Object?>{resetConfirmArgument: true});
  }

  Future<NativeIdentityStatus> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      final result = await _channel.invokeMethod<Object?>(method, arguments);
      if (result is! Map) {
        throw const NativeCryptoBackendException(
          'The native identity service returned an unusable response. Rebuild '
          'and reinstall the app, then retry.',
        );
      }
      return NativeIdentityStatus.fromMap(result);
    } on MissingPluginException {
      throw const NativeCryptoBackendException(
        'The native identity service is unavailable on this platform. Rebuild '
        'and reinstall the app, then retry.',
      );
    } on PlatformException {
      // Fixed, non-secret: native detail is never forwarded to callers.
      throw const NativeCryptoBackendException(
        'The native identity service could not complete the request. Rebuild '
        'and reinstall the app, then retry.',
      );
    }
  }
}
