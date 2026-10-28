import 'package:flutter/foundation.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/services/crypto/native_identity_service.dart';

/// Non-secret outcome of cryptographic identity initialization.
///
/// Every state that is not [ready] means operations that require the
/// cryptographic identity must fail closed. The legacy plaintext message path
/// is independent of this state and remains available.
enum IdentityInitializationState {
  /// Initialization has started but has not produced an outcome yet.
  initializing,

  /// A native identity is validated and synchronized with SQLite.
  ready,

  /// SQLite recorded an identity, but the native key is missing, unavailable
  /// or uninitialized. Nothing was replaced or reset.
  identityLost,

  /// Native storage reports a corrupt or unsupported identity envelope.
  nativeStorageInvalid,

  /// Native and SQLite identity metadata disagree, or stored metadata is
  /// partial/malformed. Nothing was overwritten.
  mismatch,

  /// A validated native identity could not be written to SQLite.
  synchronizationFailed,

  /// The native identity feature is not available on this platform.
  unsupportedPlatform,

  /// Any other native initialization failure.
  failed,
}

/// The initialized identity status exposed to the application.
///
/// Contains only public, non-secret values. There is deliberately no field for
/// a seed, wrapping key, encrypted blob, Keystore alias or filesystem path.
class IdentityInitializationStatus {
  const IdentityInitializationStatus({
    required this.state,
    this.deviceId,
    this.publicKeyHex,
    this.publicKeyFingerprint,
    this.keyAlgorithm,
  });

  final IdentityInitializationState state;

  /// The local device UUID from the existing SQLite identity row.
  final String? deviceId;

  /// The validated or previously stored Noise public identity, when known.
  final String? publicKeyHex;

  /// Lowercase-hex SHA-256 fingerprint of [publicKeyHex], when known.
  final String? publicKeyFingerprint;

  /// Algorithm identifier associated with [publicKeyHex], when known.
  final String? keyAlgorithm;

  bool get isReady => state == IdentityInitializationState.ready;

  /// Whether the cryptographic identity needs attention.
  ///
  /// [initializing] is not degraded: it has no outcome yet.
  bool get isDegraded =>
      state != IdentityInitializationState.ready &&
      state != IdentityInitializationState.initializing;

  /// Fixed, non-secret explanation suitable for status UI and logs.
  ///
  /// Native error detail is never forwarded, so this text cannot leak seed
  /// material, native paths or provider internals.
  String get message => switch (state) {
    IdentityInitializationState.initializing =>
      'Cryptographic identity is initializing.',
    IdentityInitializationState.ready => 'Cryptographic identity is ready.',
    IdentityInitializationState.identityLost =>
      'The cryptographic identity is missing or unavailable. '
          'Local data was kept.',
    IdentityInitializationState.nativeStorageInvalid =>
      'The stored cryptographic identity is damaged or unsupported. '
          'Local data was kept.',
    IdentityInitializationState.mismatch =>
      'The stored cryptographic identity does not match the native identity. '
          'Local data was kept.',
    IdentityInitializationState.synchronizationFailed =>
      'The cryptographic identity could not be saved to local storage.',
    IdentityInitializationState.unsupportedPlatform =>
      'Cryptographic identity is not available on this platform.',
    IdentityInitializationState.failed =>
      'The cryptographic identity could not be initialized.',
  };

  @override
  String toString() =>
      'IdentityInitializationStatus(${state.name}, deviceId: $deviceId)';
}

/// Single-flight coordinator between native Noise identity state and the
/// persistent SQLite identity row.
///
/// Protocol:
///
/// 1. Wait for database initialization (callers must still treat database
///    failure as fatal bootstrap failure; this class does not swallow it).
/// 2. Ensure the existing UUID identity row exists.
/// 3. Assess native state read-only with [NativeIdentityGateway.status].
/// 4. Provision only when SQLite has no cryptographic metadata *and* native
///    storage positively reports [NativeIdentityState.uninitialized].
/// 5. Reconcile an established native identity with SQLite, preserving the
///    device UUID, row ID, display name, row creation time and any existing
///    identity creation timestamp.
/// 6. Publish a non-secret [IdentityInitializationStatus].
///
/// It never resets, overwrites or repairs an established identity by
/// generating a new key. Repeated and concurrent calls share one operation;
/// a successful or unsupported outcome is returned to later callers without
/// touching native storage again.
class IdentityInitializationCoordinator {
  IdentityInitializationCoordinator({
    required IdentityMetadataStore repository,
    required NativeIdentityGateway nativeIdentity,
    Future<void> Function()? ensureDatabase,
    bool Function()? isSupportedPlatform,
    DateTime Function()? now,
  }) : _repository = repository,
       _nativeIdentity = nativeIdentity,
       _ensureDatabase = ensureDatabase ?? (() => DatabaseHelper.database),
       _isSupportedPlatform = isSupportedPlatform ?? _defaultPlatformSupported,
       _now = now ?? (() => DateTime.now().toUtc());

  final IdentityMetadataStore _repository;
  final NativeIdentityGateway _nativeIdentity;
  final Future<void> Function() _ensureDatabase;
  final bool Function() _isSupportedPlatform;
  final DateTime Function() _now;

  static final RegExp _hex32 = RegExp(r'^[0-9a-f]{64}$');

  Future<IdentityInitializationStatus>? _inFlight;
  IdentityInitializationStatus? _settled;

  static bool _defaultPlatformSupported() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Runs, or joins, the single initialization operation.
  ///
  /// Database failures propagate so bootstrap keeps its existing fatal error
  /// behaviour. Cryptographic identity failures are returned as a degraded
  /// status instead; they never destroy local data and never prevent the
  /// legacy message path from starting.
  Future<IdentityInitializationStatus> initialize() {
    final settled = _settled;
    if (settled != null) return Future.value(settled);

    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final operation = _initialize();
    _inFlight = operation;
    return operation.then(
      (status) {
        if (identical(_inFlight, operation)) _inFlight = null;
        if (status.state == IdentityInitializationState.ready ||
            status.state == IdentityInitializationState.unsupportedPlatform) {
          _settled = status;
        }
        return status;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_inFlight, operation)) _inFlight = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  Future<IdentityInitializationStatus> _initialize() async {
    if (!_isSupportedPlatform()) {
      return const IdentityInitializationStatus(
        state: IdentityInitializationState.unsupportedPlatform,
      );
    }

    // Deliberately outside the cryptographic failure handling: a database
    // failure is a bootstrap failure, not a degraded identity.
    await _ensureDatabase();
    final identity = await _repository.ensureIdentity();

    final NativeIdentityStatus native;
    try {
      native = await _nativeIdentity.status();
    } catch (_) {
      return _statusFor(identity, IdentityInitializationState.failed);
    }

    return _reconcile(identity, native);
  }

  Future<IdentityInitializationStatus> _reconcile(
    Identity identity,
    NativeIdentityStatus native,
  ) async {
    switch (native.state) {
      case NativeIdentityState.uninitialized:
        return _reconcileUninitialized(identity);
      case NativeIdentityState.ready:
        return _reconcileReady(identity, native);
      case NativeIdentityState.blobMissing:
      case NativeIdentityState.keyUnavailable:
        // The identity existed at some point but cannot be recovered. Never
        // provision a replacement over established SQLite metadata.
        return _statusFor(identity, IdentityInitializationState.identityLost);
      case NativeIdentityState.blobCorrupt:
      case NativeIdentityState.blobUnsupported:
      case NativeIdentityState.metadataInvalid:
        return _statusFor(
          identity,
          IdentityInitializationState.nativeStorageInvalid,
        );
      case NativeIdentityState.mismatch:
        return _statusFor(identity, IdentityInitializationState.mismatch);
      case NativeIdentityState.nativeError:
      case NativeIdentityState.storeFailed:
      case NativeIdentityState.unknown:
        return _statusFor(identity, IdentityInitializationState.failed);
    }
  }

  Future<IdentityInitializationStatus> _reconcileUninitialized(
    Identity identity,
  ) async {
    if (_hasCryptoMetadata(identity)) {
      // SQLite remembers an identity, so this is loss, not a fresh install.
      // A valid stored key is a lost identity; partial or malformed metadata
      // is a conflict that needs explicit recovery rather than provisioning.
      return _statusFor(
        identity,
        _isHex32(identity.publicKey)
            ? IdentityInitializationState.identityLost
            : IdentityInitializationState.mismatch,
      );
    }

    final NativeIdentityStatus provisioned;
    try {
      provisioned = await _nativeIdentity.initialize();
    } catch (_) {
      return _statusFor(identity, IdentityInitializationState.failed);
    }

    if (provisioned.state == NativeIdentityState.ready) {
      return _reconcileReady(identity, provisioned);
    }

    // Provisioning did not produce a validated identity. Map the outcome but
    // never call initialize() a second time in this operation.
    return _statusForNonReadyNative(identity, provisioned);
  }

  Future<IdentityInitializationStatus> _reconcileReady(
    Identity identity,
    NativeIdentityStatus native,
  ) async {
    final publicKey = native.publicKeyHex;
    final fingerprint = native.fingerprintHex;
    if (publicKey == null ||
        fingerprint == null ||
        !_hex32.hasMatch(publicKey) ||
        !_hex32.hasMatch(fingerprint)) {
      // A ready state without complete, well-formed public information is not
      // an identity this build can trust or persist.
      return _statusFor(identity, IdentityInitializationState.failed);
    }

    final storedKey = identity.publicKey;
    final hasStoredKey = storedKey != null && storedKey.isNotEmpty;

    if (!hasStoredKey && _hasCryptoMetadata(identity)) {
      // Partial metadata is only repairable when its fingerprint proves it
      // describes this same native identity. Anything else is a conflict.
      final storedFingerprint = identity.publicKeyFingerprint;
      final storedAlgorithm = identity.keyAlgorithm;
      final fingerprintMatches =
          storedFingerprint == null || storedFingerprint == fingerprint;
      final algorithmMatches =
          storedAlgorithm == null || storedAlgorithm == _algorithm;
      if (storedFingerprint == null ||
          !fingerprintMatches ||
          !algorithmMatches) {
        return _statusFor(identity, IdentityInitializationState.mismatch);
      }
    }

    if (hasStoredKey && storedKey != publicKey) {
      return _statusFor(identity, IdentityInitializationState.mismatch);
    }

    final storedFingerprint = identity.publicKeyFingerprint;
    if (storedFingerprint != null && storedFingerprint != fingerprint) {
      return _statusFor(identity, IdentityInitializationState.mismatch);
    }

    final storedAlgorithm = identity.keyAlgorithm;
    if (storedAlgorithm != null && storedAlgorithm != _algorithm) {
      return _statusFor(identity, IdentityInitializationState.mismatch);
    }

    final needsWrite =
        !hasStoredKey ||
        storedFingerprint == null ||
        storedAlgorithm == null ||
        identity.identityCreatedAt == null;
    if (!needsWrite) {
      return _statusForValues(
        identity,
        IdentityInitializationState.ready,
        publicKey: publicKey,
        fingerprint: fingerprint,
        algorithm: _algorithm,
      );
    }

    return _persistReady(identity, publicKey, fingerprint);
  }

  /// Persists a validated public identity on the existing row.
  ///
  /// An existing [Identity.identityCreatedAt] is always passed through so the
  /// original provision timestamp is preserved. When the native layer cannot
  /// report its own key-generation time (it does not expose one), the fallback
  /// recorded here is explicitly the time of successful metadata
  /// synchronization, not a fabricated earlier timestamp.
  Future<IdentityInitializationStatus> _persistReady(
    Identity identity,
    String publicKey,
    String fingerprint,
  ) async {
    try {
      final saved = await _repository.savePublicIdentityMetadata(
        publicKeyHex: publicKey,
        publicKeyFingerprint: fingerprint,
        keyAlgorithm: _algorithm,
        identityCreatedAt: identity.identityCreatedAt ?? _now(),
      );
      return _statusForValues(
        saved,
        IdentityInitializationState.ready,
        publicKey: publicKey,
        fingerprint: fingerprint,
        algorithm: _algorithm,
      );
    } catch (_) {
      // The native identity stays installed; a later retry reconciles from
      // the ready native state without generating another key.
      return _statusFor(
        identity,
        IdentityInitializationState.synchronizationFailed,
      );
    }
  }

  IdentityInitializationStatus _statusForNonReadyNative(
    Identity identity,
    NativeIdentityStatus native,
  ) {
    switch (native.state) {
      case NativeIdentityState.blobMissing:
      case NativeIdentityState.keyUnavailable:
        return _statusFor(identity, IdentityInitializationState.identityLost);
      case NativeIdentityState.blobCorrupt:
      case NativeIdentityState.blobUnsupported:
      case NativeIdentityState.metadataInvalid:
        return _statusFor(
          identity,
          IdentityInitializationState.nativeStorageInvalid,
        );
      case NativeIdentityState.mismatch:
        return _statusFor(identity, IdentityInitializationState.mismatch);
      case NativeIdentityState.uninitialized:
      case NativeIdentityState.nativeError:
      case NativeIdentityState.storeFailed:
      case NativeIdentityState.unknown:
        return _statusFor(identity, IdentityInitializationState.failed);
      case NativeIdentityState.ready:
        // Callers only reach this mapping after a non-ready outcome.
        return _statusFor(identity, IdentityInitializationState.failed);
    }
  }

  IdentityInitializationStatus _statusFor(
    Identity identity,
    IdentityInitializationState state,
  ) {
    return _statusForValues(identity, state);
  }

  IdentityInitializationStatus _statusForValues(
    Identity identity,
    IdentityInitializationState state, {
    String? publicKey,
    String? fingerprint,
    String? algorithm,
  }) {
    return IdentityInitializationStatus(
      state: state,
      deviceId: identity.deviceId,
      publicKeyHex: publicKey ?? identity.publicKey,
      publicKeyFingerprint: fingerprint ?? identity.publicKeyFingerprint,
      keyAlgorithm: algorithm ?? identity.keyAlgorithm,
    );
  }

  static const String _algorithm = AppConstants.noiseKeyAlgorithm;

  static bool _isHex32(String? value) =>
      value != null && _hex32.hasMatch(value);

  /// Whether the row carries any cryptographic metadata at all.
  ///
  /// A legacy identity row can hold a placeholder public key and an opaque
  /// reference. Those are not proof of a Noise identity, but they must still
  /// stop blind provisioning: partial or malformed metadata is a conflict to
  /// resolve explicitly, not a clean install.
  static bool _hasCryptoMetadata(Identity identity) {
    final publicKey = identity.publicKey;
    return (publicKey != null && publicKey.isNotEmpty) ||
        identity.publicKeyFingerprint != null ||
        identity.keyAlgorithm != null ||
        identity.identityCreatedAt != null;
  }
}
