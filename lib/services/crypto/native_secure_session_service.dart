import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A reference to one native Noise session.
///
/// The reference is invalidated by [SecureSessionGateway.closeSession], after
/// which every session-targeting operation rejects it with
/// [SecureSessionClosed] before any platform traffic. The native engine
/// remains the owner of the underlying session; this class only tracks the
/// local Dart-side reference so a closed handle can never be reused.
final class SecureSessionHandle {
  SecureSessionHandle._(this._value);

  /// Creates an open handle for tests that need a reference without crossing
  /// the platform boundary. Production code must obtain handles only from
  /// [SecureSessionGateway.createSession].
  @visibleForTesting
  SecureSessionHandle.forTesting(int value) : _value = value;

  int _value;

  bool get isClosed => _value == 0;

  void _invalidate() => _value = 0;

  void _ensureOpen(String operation) {
    if (isClosed) {
      throw SecureSessionClosed('$operation: the session is closed.');
    }
  }
}

/// The authenticated remote identity reported by the native Noise engine once
/// a handshake authenticates it.
///
/// [publicKeyHex] is the remote static X25519 public key captured from the
/// Noise XX exchange. [deviceId] and [displayName] are the identity fields
/// embedded in the AEAD-protected handshake payload, verified under the
/// transport key the Noise engine derives. They prove that whoever holds
/// [publicKeyHex] presented that identity; they say nothing about the human
/// behind the device. Human-level trust decisions belong to the application
/// layer, never to this service.
final class RemoteAuthenticatedIdentity {
  const RemoteAuthenticatedIdentity({
    required this.publicKeyHex,
    required this.deviceId,
    required this.displayName,
    required this.protocolVersion,
    required this.capabilities,
  });

  /// Lowercase-hex X25519 static public key of the remote peer.
  final String publicKeyHex;

  /// Authenticated BeChat device ID presented by the remote peer.
  final String deviceId;

  /// Authenticated display name presented by the remote peer.
  final String displayName;

  /// Protocol version from the authenticated identity payload.
  final int protocolVersion;

  /// Bitfield of protocol capabilities from the authenticated payload.
  final int capabilities;

  /// Whether the authenticated peer advertises the given capability bit.
  bool supportsCapability(int capability) => (capabilities & capability) != 0;

  @override
  String toString() =>
      'RemoteAuthenticatedIdentity(deviceId: $deviceId, '
      'displayName: $displayName, protocolVersion: $protocolVersion, '
      'capabilities: $capabilities)';
}

/// The native session state machine stages reported by `getSessionStatus`.
enum SecureSessionStage { handshaking, awaitingConfirmation, ready, failed }

/// A non-secret snapshot of the native session state.
final class SecureSessionStatus {
  const SecureSessionStatus({
    required this.stage,
    required this.remoteIdentityAvailable,
    this.remotePublicKeyHex,
  });

  /// The current stage, or `null` when the platform reported a stage this
  /// build does not recognize. An unrecognized stage is never treated as
  /// ready.
  final SecureSessionStage? stage;

  /// Whether the authenticated remote identity has been delivered.
  final bool remoteIdentityAvailable;

  /// Lowercase-hex remote static public key once available, else `null`.
  final String? remotePublicKeyHex;

  /// True only when the native engine reports the session is fully `ready`:
  /// the handshake completed, any pinned-key check passed, the authenticated
  /// remote identity is available, and the explicit peer-identity
  /// confirmation was accepted.
  bool get isReady => stage == SecureSessionStage.ready;

  @override
  String toString() =>
      'SecureSessionStatus(stage: $stage, '
      'remoteIdentityAvailable: $remoteIdentityAvailable)';
}

/// The result of starting or advancing a Noise handshake.
final class HandshakeStepResult {
  const HandshakeStepResult({
    required this.outgoing,
    required this.finished,
    required this.confirmationRequired,
    this.remoteIdentity,
  });

  /// The outbound handshake message to transmit to the peer.
  final Uint8List outgoing;

  /// Whether the Noise handshake has completed.
  final bool finished;

  /// Whether explicit peer-identity confirmation is still required before the
  /// session becomes usable.
  final bool confirmationRequired;

  /// The authenticated remote identity, delivered exactly once by the
  /// handshake step that authenticates it; otherwise `null`.
  final RemoteAuthenticatedIdentity? remoteIdentity;
}

/// Fixed, non-secret failures raised by the Dart secure-session gateway.
///
/// Each subtype is a distinct error category. Messages are static Dart text;
/// no native error string, key material, handshake bytes, ciphertext,
/// plaintext or identity blob ever reaches an error message.
sealed class SecureSessionException implements Exception {
  const SecureSessionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The request was rejected as invalid before reaching the engine.
final class SecureSessionInvalidArgument extends SecureSessionException {
  const SecureSessionInvalidArgument(super.message);
}

/// The native session service was saturated and refused the operation.
final class SecureSessionBusy extends SecureSessionException {
  const SecureSessionBusy(super.message);
}

/// The native engine failed, the bridge is unavailable, or a platform error
/// occurred. Fixed text only; native detail is never forwarded.
final class SecureSessionNativeFailure extends SecureSessionException {
  const SecureSessionNativeFailure(super.message);
}

/// A closed or invalid Dart session reference was used.
final class SecureSessionClosed extends SecureSessionException {
  const SecureSessionClosed(super.message);
}

/// The platform returned a malformed, incomplete or wrongly typed response.
final class SecureSessionUnexpectedResponse extends SecureSessionException {
  const SecureSessionUnexpectedResponse(super.message);
}

/// Typed Dart access layer over the native Noise secure-session engine.
///
/// Every cryptographic operation delegates to the Rust engine through the
/// Kotlin `SecureSessionController` on the `bechat/secure_session`
/// MethodChannel. This service performs no cryptography in Dart, accepts no
/// private key or seed, and implements no plaintext fallback.
abstract interface class SecureSessionGateway {
  /// Opens a native session and returns a reference to it.
  ///
  /// [pinnedRemotePublicKey], when given, must be exactly 32 raw bytes and is
  /// forwarded to the engine as a lowercase-hex pin so the eventual peer
  /// static key must match it.
  Future<SecureSessionHandle> createSession({
    required bool initiator,
    required String deviceId,
    required String displayName,
    Uint8List? pinnedRemotePublicKey,
    String? expectedRemoteDeviceId,
  });

  /// Starts the Noise XX handshake. Initiator sessions only.
  Future<HandshakeStepResult> startHandshake(SecureSessionHandle session);

  /// Advances the handshake from one inbound peer message. Responder sessions
  /// only.
  Future<HandshakeStepResult> processHandshake(
    SecureSessionHandle session,
    Uint8List incoming,
  );

  /// Reads the non-secret native session state.
  Future<SecureSessionStatus> getSessionStatus(SecureSessionHandle session);

  /// Explicitly accepts the authenticated remote identity. Only after the
  /// native engine accepts this does the session become usable for [encrypt]
  /// and [decrypt].
  Future<void> confirmPeerIdentity(SecureSessionHandle session);

  /// Encrypts application plaintext through the established Noise session.
  Future<Uint8List> encrypt(SecureSessionHandle session, Uint8List plaintext);

  /// Decrypts one authenticated transport message.
  Future<Uint8List> decrypt(SecureSessionHandle session, Uint8List ciphertext);

  /// Closes the native session and invalidates the local reference.
  ///
  /// Idempotent, matching the native contract: closing an already-closed
  /// reference is a no-op.
  Future<void> closeSession(SecureSessionHandle session);
}

/// Production [SecureSessionGateway] over the `bechat/secure_session`
/// MethodChannel implemented by the Kotlin `SecureSessionController`.
final class NativeSecureSessionGateway implements SecureSessionGateway {
  NativeSecureSessionGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'bechat/secure_session';

  static const String _createSession = 'createSession';
  static const String _startHandshake = 'startHandshake';
  static const String _processHandshake = 'processHandshake';
  static const String _getSessionStatus = 'getSessionStatus';
  static const String _confirmPeerIdentity = 'confirmPeerIdentity';
  static const String _encrypt = 'encrypt';
  static const String _decrypt = 'decrypt';
  static const String _closeSession = 'closeSession';

  static const int _pinnedKeyBytes = 32;

  final MethodChannel _channel;

  @override
  Future<SecureSessionHandle> createSession({
    required bool initiator,
    required String deviceId,
    required String displayName,
    Uint8List? pinnedRemotePublicKey,
    String? expectedRemoteDeviceId,
  }) async {
    if (deviceId.isEmpty) {
      throw const SecureSessionInvalidArgument(
        'A local device ID is required to create a session.',
      );
    }
    if (displayName.isEmpty) {
      throw const SecureSessionInvalidArgument(
        'A local display name is required to create a session.',
      );
    }
    final pinHex = pinnedRemotePublicKey == null
        ? null
        : _encodePin(pinnedRemotePublicKey);

    final response = await _invokeMap(_createSession, <String, Object?>{
      'initiator': initiator,
      'deviceId': deviceId,
      'displayName': displayName,
      if (pinHex != null) 'pinnedRemotePublicKeyHex': pinHex,
      if (expectedRemoteDeviceId != null)
        'expectedRemoteDeviceId': expectedRemoteDeviceId,
    });

    final handle = response['handle'];
    if (handle is! int || handle <= 0) {
      throw const SecureSessionUnexpectedResponse(
        'The secure session service returned an unusable response.',
      );
    }
    return SecureSessionHandle._(handle);
  }

  @override
  Future<HandshakeStepResult> startHandshake(
    SecureSessionHandle session,
  ) async {
    session._ensureOpen('startHandshake');
    final response = await _invokeMap(_startHandshake, <String, Object?>{
      'handle': session._value,
    });
    return _parseHandshakeResult(response);
  }

  @override
  Future<HandshakeStepResult> processHandshake(
    SecureSessionHandle session,
    Uint8List incoming,
  ) async {
    session._ensureOpen('processHandshake');
    if (incoming.isEmpty) {
      throw const SecureSessionInvalidArgument(
        'A handshake message is required.',
      );
    }
    final response = await _invokeMap(_processHandshake, <String, Object?>{
      'handle': session._value,
      'incoming': incoming,
    });
    return _parseHandshakeResult(response);
  }

  @override
  Future<SecureSessionStatus> getSessionStatus(
    SecureSessionHandle session,
  ) async {
    session._ensureOpen('getSessionStatus');
    final response = await _invokeMap(_getSessionStatus, <String, Object?>{
      'handle': session._value,
    });
    return _parseStatus(response);
  }

  @override
  Future<void> confirmPeerIdentity(SecureSessionHandle session) async {
    session._ensureOpen('confirmPeerIdentity');
    final response = await _invokeMap(_confirmPeerIdentity, <String, Object?>{
      'handle': session._value,
    });
    if (response['confirmed'] != true) {
      throw const SecureSessionUnexpectedResponse(
        'The secure session service returned an unusable response.',
      );
    }
  }

  @override
  Future<Uint8List> encrypt(
    SecureSessionHandle session,
    Uint8List plaintext,
  ) async {
    session._ensureOpen('encrypt');
    final response = await _invokeMap(_encrypt, <String, Object?>{
      'handle': session._value,
      'plaintext': plaintext,
    });
    return _requireBytes(response, 'ciphertext');
  }

  @override
  Future<Uint8List> decrypt(
    SecureSessionHandle session,
    Uint8List ciphertext,
  ) async {
    session._ensureOpen('decrypt');
    final response = await _invokeMap(_decrypt, <String, Object?>{
      'handle': session._value,
      'ciphertext': ciphertext,
    });
    return _requireBytes(response, 'plaintext');
  }

  @override
  Future<void> closeSession(SecureSessionHandle session) async {
    if (session.isClosed) {
      // Idempotent, mirroring the native close contract.
      return;
    }
    final handle = session._value;
    // Invalidate the local reference immediately so it can never be reused
    // even if the platform close is still in flight.
    session._invalidate();
    await _invokeMap(_closeSession, <String, Object?>{'handle': handle});
  }

  // ------------------------------------------------------------- parsing

  HandshakeStepResult _parseHandshakeResult(Map<String, Object?> response) {
    final remoteIdentityRaw = response['remoteIdentity'];
    RemoteAuthenticatedIdentity? remoteIdentity;
    if (remoteIdentityRaw != null) {
      if (remoteIdentityRaw is! Map) {
        throw const SecureSessionUnexpectedResponse(
          'The secure session service returned an unusable response.',
        );
      }
      remoteIdentity = _parseRemoteIdentity(remoteIdentityRaw);
    }
    return HandshakeStepResult(
      outgoing: _requireBytes(response, 'outgoing'),
      finished: _requireBool(response, 'finished'),
      confirmationRequired: _requireBool(response, 'confirmationRequired'),
      remoteIdentity: remoteIdentity,
    );
  }

  RemoteAuthenticatedIdentity _parseRemoteIdentity(Map<dynamic, dynamic> map) {
    return RemoteAuthenticatedIdentity(
      publicKeyHex: _requireString(map, 'publicKeyHex'),
      deviceId: _requireString(map, 'deviceId'),
      displayName: _requireString(map, 'displayName'),
      protocolVersion: _requireInt(map, 'protocolVersion'),
      capabilities: _requireInt(map, 'capabilities'),
    );
  }

  SecureSessionStatus _parseStatus(Map<String, Object?> response) {
    final stageRaw = _requireString(response, 'stage');
    final remotePublicKeyHexRaw = response['remotePublicKeyHex'];
    if (remotePublicKeyHexRaw != null && remotePublicKeyHexRaw is! String) {
      throw const SecureSessionUnexpectedResponse(
        'The secure session service returned an unusable response.',
      );
    }
    return SecureSessionStatus(
      stage: _stageFromLabel(stageRaw),
      remoteIdentityAvailable: _requireBool(
        response,
        'remoteIdentityAvailable',
      ),
      remotePublicKeyHex: remotePublicKeyHexRaw as String?,
    );
  }

  /// Maps the fixed native stage labels. An unrecognized label returns `null`
  /// so it is never mistaken for `ready`.
  static SecureSessionStage? _stageFromLabel(String label) {
    switch (label) {
      case 'handshaking':
        return SecureSessionStage.handshaking;
      case 'awaiting_confirmation':
        return SecureSessionStage.awaitingConfirmation;
      case 'ready':
        return SecureSessionStage.ready;
      case 'failed':
        return SecureSessionStage.failed;
      default:
        return null;
    }
  }

  // ---------------------------------------------------------- transport

  /// Invokes one native method and returns its map response, mapping every
  /// platform failure onto a safe typed exception.
  Future<Map<String, Object?>> _invokeMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw const SecureSessionNativeFailure(
        'The secure session service is unavailable on this platform.',
      );
    } on PlatformException catch (error) {
      throw _mapPlatformError(error);
    }
    if (result is! Map) {
      throw const SecureSessionUnexpectedResponse(
        'The secure session service returned an unusable response.',
      );
    }
    return result.map(
      (Object? key, Object? value) =>
          MapEntry<String, Object?>(key.toString(), value),
    );
  }

  /// Maps the controller's fixed error codes onto typed exceptions. Native
  /// message text is never forwarded.
  static SecureSessionException _mapPlatformError(PlatformException error) {
    switch (error.code) {
      case 'SESSION_INVALID_ARGUMENT':
        return const SecureSessionInvalidArgument(
          'The secure session request was rejected as invalid.',
        );
      case 'SESSION_BUSY':
        return const SecureSessionBusy(
          'The secure session service is busy. Retry shortly.',
        );
      case 'SESSION_NATIVE_ERROR':
      default:
        // Unknown codes fail closed as a generic native failure.
        return const SecureSessionNativeFailure(
          'The native secure session operation failed.',
        );
    }
  }

  // ----------------------------------------------------------- helpers

  static String _encodePin(Uint8List pin) {
    if (pin.length != _pinnedKeyBytes) {
      throw const SecureSessionInvalidArgument(
        'A pinned remote public key must be exactly 32 bytes.',
      );
    }
    final buffer = StringBuffer();
    for (final byte in pin) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static Uint8List _requireBytes(Map<dynamic, dynamic> map, String key) {
    final value = map[key];
    if (value is Uint8List) {
      return value;
    }
    throw const SecureSessionUnexpectedResponse(
      'The secure session service returned an unusable response.',
    );
  }

  static bool _requireBool(Map<dynamic, dynamic> map, String key) {
    final value = map[key];
    if (value is bool) {
      return value;
    }
    throw const SecureSessionUnexpectedResponse(
      'The secure session service returned an unusable response.',
    );
  }

  static int _requireInt(Map<dynamic, dynamic> map, String key) {
    final value = map[key];
    if (value is int) {
      return value;
    }
    throw const SecureSessionUnexpectedResponse(
      'The secure session service returned an unusable response.',
    );
  }

  static String _requireString(Map<dynamic, dynamic> map, String key) {
    final value = map[key];
    if (value is String) {
      return value;
    }
    throw const SecureSessionUnexpectedResponse(
      'The secure session service returned an unusable response.',
    );
  }
}
