import 'package:flutter/services.dart';

/// Exception raised when the native crypto backend cannot be reached.
///
/// The message is always fixed, non-secret text: native error details are
/// never forwarded to Dart so no secret-bearing information can leak through
/// initialization or diagnostics.
class NativeCryptoBackendException implements Exception {
  const NativeCryptoBackendException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Non-secret diagnostics for the production Rust crypto backend (Phase 1A).
///
/// Establishes only that the packaged native library loads and executes Rust
/// code. No private-key bytes, seeds or secret state cross this boundary, and
/// calling this does not provision, persist or modify any identity or the
/// application database.
class NativeCryptoBackend {
  NativeCryptoBackend({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('bechat/native_crypto');

  static const String channelName = 'bechat/native_crypto';
  static const String backendVersionMethod = 'backendVersion';

  final MethodChannel _channel;

  /// Returns the fixed, non-secret native backend identifier.
  ///
  /// Throws [NativeCryptoBackendException] when the native library is
  /// unavailable or the response is invalid.
  Future<String> backendVersion() async {
    try {
      final version = await _channel.invokeMethod<String>(backendVersionMethod);
      if (version == null || version.isEmpty) {
        throw const NativeCryptoBackendException(
          'The native crypto backend returned no version. Rebuild and '
              'reinstall the app, then retry.',
        );
      }
      return version;
    } on MissingPluginException {
      throw const NativeCryptoBackendException(
        'The native crypto backend is unavailable on this platform. Rebuild '
            'and reinstall the app, then retry.',
      );
    } on PlatformException {
      throw const NativeCryptoBackendException(
        'The native crypto backend is unavailable. Rebuild and reinstall the '
            'app, then retry.',
      );
    }
  }
}
