import 'dart:async';
import 'dart:io';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/services/crypto/identity_initialization_coordinator.dart';
import 'package:bechat/services/crypto/native_identity_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

/// Fixed, non-secret test vectors (32-byte values written as lowercase hex).
const String kKeyA =
    '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0';
const String kKeyB =
    '112233445566778899001122334455667788990011223344556677889900aabb';
const String kFingerprintA =
    '1111111111111111111111111111111111111111111111111111111111111111';
const String kFingerprintB =
    '2222222222222222222222222222222222222222222222222222222222222222';

const String kDeviceId = 'device-uuid-coordinator-0001';
const String kDisplayName = 'Coordinator Device';

final DateTime kRowCreatedAt = DateTime.utc(2026, 5, 1, 8);
final DateTime kIdentityCreatedAt = DateTime.utc(2026, 5, 2, 9, 30);
final DateTime kSyncNow = DateTime.utc(2026, 10, 28, 12, 34, 56);

Identity identityRow({
  String? publicKey,
  String? fingerprint,
  String? algorithm,
  DateTime? identityCreatedAt,
  String? reference,
}) {
  return Identity(
    id: kDeviceId,
    deviceId: kDeviceId,
    displayName: kDisplayName,
    publicKey: publicKey,
    publicKeyFingerprint: fingerprint,
    keyAlgorithm: algorithm,
    identityCreatedAt: identityCreatedAt,
    privateKeyReference: reference,
    createdAt: kRowCreatedAt,
    updatedAt: kRowCreatedAt,
  );
}

NativeIdentityStatus ready({
  String key = kKeyA,
  String fingerprint = kFingerprintA,
}) {
  return NativeIdentityStatus(
    state: NativeIdentityState.ready,
    publicKeyHex: key,
    fingerprintHex: fingerprint,
  );
}

NativeIdentityStatus nativeState(NativeIdentityState state) {
  return NativeIdentityStatus(state: state);
}

class FakeIdentityStore implements IdentityMetadataStore {
  FakeIdentityStore(this.identity);

  Identity identity;
  int ensureCalls = 0;
  int persistCalls = 0;
  bool failEnsure = false;
  bool failPersist = false;
  Object? persistError;
  final List<DateTime?> persistedCreatedAt = <DateTime?>[];

  @override
  Future<Identity> ensureIdentity() async {
    ensureCalls++;
    if (failEnsure) throw StateError('identity row unavailable');
    return identity;
  }

  @override
  Future<Identity> savePublicIdentityMetadata({
    required String publicKeyHex,
    required String publicKeyFingerprint,
    String? privateKeyReference,
    String keyAlgorithm = AppConstants.noiseKeyAlgorithm,
    DateTime? identityCreatedAt,
  }) async {
    persistCalls++;
    persistedCreatedAt.add(identityCreatedAt);
    if (failPersist) {
      throw persistError ?? StateError('identity metadata write failed');
    }

    identity = Identity(
      id: identity.id,
      deviceId: identity.deviceId,
      displayName: identity.displayName,
      publicKey: publicKeyHex,
      privateKeyReference: privateKeyReference ?? identity.privateKeyReference,
      publicKeyFingerprint: publicKeyFingerprint,
      keyAlgorithm: keyAlgorithm,
      identityCreatedAt:
          identityCreatedAt ?? identity.identityCreatedAt ?? kSyncNow,
      createdAt: identity.createdAt,
      updatedAt: kSyncNow,
    );
    return identity;
  }
}

class FakeNativeIdentityGateway implements NativeIdentityGateway {
  FakeNativeIdentityGateway({
    required this.statusResult,
    this.initializeResult,
  });

  NativeIdentityStatus statusResult;
  NativeIdentityStatus? initializeResult;
  Object? statusError;
  Object? initializeError;
  Completer<void>? statusGate;
  final List<String> calls = <String>[];

  @override
  Future<NativeIdentityStatus> status() async {
    calls.add('status');
    final gate = statusGate;
    if (gate != null) await gate.future;
    final error = statusError;
    if (error != null) throw error;
    return statusResult;
  }

  @override
  Future<NativeIdentityStatus> initialize() async {
    calls.add('initialize');
    final error = initializeError;
    if (error != null) throw error;
    return initializeResult ?? statusResult;
  }
}

IdentityInitializationCoordinator coordinatorFor({
  required FakeIdentityStore store,
  required FakeNativeIdentityGateway native,
  bool supported = true,
  Future<void> Function()? ensureDatabase,
}) {
  return IdentityInitializationCoordinator(
    repository: store,
    nativeIdentity: native,
    ensureDatabase: ensureDatabase ?? () async {},
    isSupportedPlatform: () => supported,
    now: () => kSyncNow,
  );
}

void main() {
  group('fresh installation', () {
    test(
      'provisions exactly one identity and persists validated metadata',
      () async {
        final store = FakeIdentityStore(identityRow());
        final native = FakeNativeIdentityGateway(
          statusResult: nativeState(NativeIdentityState.uninitialized),
          initializeResult: ready(),
        );
        final coordinator = coordinatorFor(store: store, native: native);

        final result = await coordinator.initialize();

        expect(result.state, IdentityInitializationState.ready);
        expect(result.isReady, isTrue);
        expect(result.deviceId, kDeviceId);
        expect(result.publicKeyHex, kKeyA);
        expect(result.publicKeyFingerprint, kFingerprintA);
        expect(result.keyAlgorithm, AppConstants.noiseKeyAlgorithm);
        expect(native.calls, ['status', 'initialize']);
        expect(store.persistCalls, 1);
        expect(store.identity.publicKey, kKeyA);
        expect(store.identity.publicKeyFingerprint, kFingerprintA);
        expect(store.identity.keyAlgorithm, AppConstants.noiseKeyAlgorithm);
        expect(store.identity.identityCreatedAt, kSyncNow);
        expect(store.identity.deviceId, kDeviceId);
        expect(store.identity.id, kDeviceId);
        expect(store.identity.displayName, kDisplayName);
        expect(store.identity.createdAt, kRowCreatedAt);
      },
    );

    test('preserves an existing opaque reference and row timestamps', () async {
      final store = FakeIdentityStore(
        identityRow(reference: 'keystore:bechat_identity_wrap_v1'),
      );
      final native = FakeNativeIdentityGateway(
        statusResult: nativeState(NativeIdentityState.uninitialized),
        initializeResult: ready(),
      );

      await coordinatorFor(store: store, native: native).initialize();

      expect(
        store.identity.privateKeyReference,
        'keystore:bechat_identity_wrap_v1',
      );
      expect(store.identity.createdAt, kRowCreatedAt);
    });

    test('a provisioning failure is reported and never persisted', () async {
      final store = FakeIdentityStore(identityRow());
      final native = FakeNativeIdentityGateway(
        statusResult: nativeState(NativeIdentityState.uninitialized),
        initializeResult: nativeState(NativeIdentityState.nativeError),
      );

      final result = await coordinatorFor(
        store: store,
        native: native,
      ).initialize();

      expect(result.state, IdentityInitializationState.failed);
      expect(native.calls, ['status', 'initialize']);
      expect(store.persistCalls, 0);
      expect(store.identity.publicKey, isNull);
    });

    test('a provisioning throw is reported without a retry', () async {
      final store = FakeIdentityStore(identityRow());
      final native = FakeNativeIdentityGateway(
        statusResult: nativeState(NativeIdentityState.uninitialized),
      )..initializeError = StateError('native failed');

      final result = await coordinatorFor(
        store: store,
        native: native,
      ).initialize();

      expect(result.state, IdentityInitializationState.failed);
      expect(native.calls, ['status', 'initialize']);
      expect(store.persistCalls, 0);
    });

    test('ready-without-public-info is rejected as malformed', () async {
      final store = FakeIdentityStore(identityRow());
      final native = FakeNativeIdentityGateway(
        statusResult: nativeState(NativeIdentityState.uninitialized),
        initializeResult: const NativeIdentityStatus(
          state: NativeIdentityState.ready,
          publicKeyHex: kKeyA,
        ),
      );

      final result = await coordinatorFor(
        store: store,
        native: native,
      ).initialize();

      expect(result.state, IdentityInitializationState.failed);
      expect(store.persistCalls, 0);
    });
  });

  group('normal restart', () {
    test(
      'matching native and SQLite metadata stays stable without a write',
      () async {
        final store = FakeIdentityStore(
          identityRow(
            publicKey: kKeyA,
            fingerprint: kFingerprintA,
            algorithm: AppConstants.noiseKeyAlgorithm,
            identityCreatedAt: kIdentityCreatedAt,
          ),
        );
        final before = store.identity;
        final native = FakeNativeIdentityGateway(statusResult: ready());

        final result = await coordinatorFor(
          store: store,
          native: native,
        ).initialize();

        expect(result.state, IdentityInitializationState.ready);
        expect(result.publicKeyHex, kKeyA);
        expect(native.calls, ['status']);
        expect(store.persistCalls, 0);
        expect(store.identity, same(before));
        expect(store.identity.identityCreatedAt, kIdentityCreatedAt);
      },
    );

    test('repeated calls share one successful operation', () async {
      final store = FakeIdentityStore(
        identityRow(
          publicKey: kKeyA,
          fingerprint: kFingerprintA,
          algorithm: AppConstants.noiseKeyAlgorithm,
          identityCreatedAt: kIdentityCreatedAt,
        ),
      );
      final native = FakeNativeIdentityGateway(statusResult: ready());
      final coordinator = coordinatorFor(store: store, native: native);

      final first = await coordinator.initialize();
      final second = await coordinator.initialize();
      final third = await coordinator.initialize();

      expect(first.state, IdentityInitializationState.ready);
      expect(second.state, IdentityInitializationState.ready);
      expect(third.state, IdentityInitializationState.ready);
      expect(native.calls, ['status']);
    });

    test('concurrent calls share one native status assessment', () async {
      final gate = Completer<void>();
      final store = FakeIdentityStore(
        identityRow(
          publicKey: kKeyA,
          fingerprint: kFingerprintA,
          algorithm: AppConstants.noiseKeyAlgorithm,
          identityCreatedAt: kIdentityCreatedAt,
        ),
      );
      final native = FakeNativeIdentityGateway(statusResult: ready())
        ..statusGate = gate;
      final coordinator = coordinatorFor(store: store, native: native);

      final first = coordinator.initialize();
      final second = coordinator.initialize();
      gate.complete();
      final results = await Future.wait([first, second]);

      expect(
        results.map((status) => status.state),
        everyElement(IdentityInitializationState.ready),
      );
      expect(native.calls, ['status']);
      expect(store.ensureCalls, 1);
    });

    test(
      'repairs a missing fingerprint, algorithm and timestamp unambiguously',
      () async {
        final store = FakeIdentityStore(identityRow(publicKey: kKeyA));
        final native = FakeNativeIdentityGateway(statusResult: ready());

        final result = await coordinatorFor(
          store: store,
          native: native,
        ).initialize();

        expect(result.state, IdentityInitializationState.ready);
        expect(store.persistCalls, 1);
        expect(store.identity.publicKey, kKeyA);
        expect(store.identity.publicKeyFingerprint, kFingerprintA);
        expect(store.identity.keyAlgorithm, AppConstants.noiseKeyAlgorithm);
        expect(store.identity.identityCreatedAt, kSyncNow);
        expect(store.persistedCreatedAt.single, kSyncNow);
      },
    );

    test('repairs matching fingerprint-only metadata', () async {
      final store = FakeIdentityStore(
        identityRow(
          fingerprint: kFingerprintA,
          identityCreatedAt: kIdentityCreatedAt,
        ),
      );
      final native = FakeNativeIdentityGateway(statusResult: ready());

      final result = await coordinatorFor(
        store: store,
        native: native,
      ).initialize();

      expect(result.state, IdentityInitializationState.ready);
      expect(store.persistCalls, 1);
      expect(store.identity.publicKey, kKeyA);
      expect(store.identity.publicKeyFingerprint, kFingerprintA);
      expect(store.identity.identityCreatedAt, kIdentityCreatedAt);
    });

    test('preserves an existing creation timestamp while repairing', () async {
      final store = FakeIdentityStore(
        identityRow(
          publicKey: kKeyA,
          fingerprint: kFingerprintA,
          identityCreatedAt: kIdentityCreatedAt,
        ),
      );
      final native = FakeNativeIdentityGateway(statusResult: ready());

      await coordinatorFor(store: store, native: native).initialize();

      expect(store.persistCalls, 1);
      expect(store.persistedCreatedAt.single, kIdentityCreatedAt);
      expect(store.identity.identityCreatedAt, kIdentityCreatedAt);
      expect(store.identity.keyAlgorithm, AppConstants.noiseKeyAlgorithm);
    });

    test(
      'partial metadata without a matching fingerprint never provisions',
      () async {
        final store = FakeIdentityStore(
          identityRow(algorithm: AppConstants.noiseKeyAlgorithm),
        );
        final native = FakeNativeIdentityGateway(statusResult: ready());

        final result = await coordinatorFor(
          store: store,
          native: native,
        ).initialize();

        expect(result.state, IdentityInitializationState.mismatch);
        expect(store.persistCalls, 0);
        expect(native.calls, ['status']);
      },
    );
  });

  group('identity loss and mismatch', () {
    test(
      'SQLite identity with uninitialized native storage is loss, not fresh',
      () async {
        final store = FakeIdentityStore(
          identityRow(
            publicKey: kKeyA,
            fingerprint: kFingerprintA,
            algorithm: AppConstants.noiseKeyAlgorithm,
            identityCreatedAt: kIdentityCreatedAt,
          ),
        );
        final native = FakeNativeIdentityGateway(
          statusResult: nativeState(NativeIdentityState.uninitialized),
        );

        final result = await coordinatorFor(
          store: store,
          native: native,
        ).initialize();

        expect(result.state, IdentityInitializationState.identityLost);
        expect(result.isDegraded, isTrue);
        expect(native.calls, ['status'], reason: 'loss must never provision');
        expect(store.persistCalls, 0);
      },
    );

    test(
      'partial SQLite metadata with uninitialized native storage is a conflict',
      () async {
        final store = FakeIdentityStore(
          identityRow(fingerprint: kFingerprintA),
        );
        final native = FakeNativeIdentityGateway(
          statusResult: nativeState(NativeIdentityState.uninitialized),
        );

        final result = await coordinatorFor(
          store: store,
          native: native,
        ).initialize();

        expect(result.state, IdentityInitializationState.mismatch);
        expect(native.calls, ['status']);
        expect(store.persistCalls, 0);
      },
    );

    test('malformed placeholder SQLite metadata is never replaced', () async {
      final store = FakeIdentityStore(
        identityRow(
          publicKey: 'legacy-identity-key-placeholder',
          reference: 'legacy-reference',
        ),
      );
      final native = FakeNativeIdentityGateway(
        statusResult: nativeState(NativeIdentityState.uninitialized),
      );

      final result = await coordinatorFor(
        store: store,
        native: native,
      ).initialize();

      expect(result.state, IdentityInitializationState.mismatch);
      expect(native.calls, ['status']);
      expect(store.persistCalls, 0);
      expect(store.identity.publicKey, 'legacy-identity-key-placeholder');
    });

    test('missing blob and unavailable Keystore are identity loss', () async {
      for (final state in <NativeIdentityState>[
        NativeIdentityState.blobMissing,
        NativeIdentityState.keyUnavailable,
      ]) {
        final store = FakeIdentityStore(
          identityRow(
            publicKey: kKeyA,
            fingerprint: kFingerprintA,
            algorithm: AppConstants.noiseKeyAlgorithm,
            identityCreatedAt: kIdentityCreatedAt,
          ),
        );
        final native = FakeNativeIdentityGateway(
          statusResult: nativeState(state),
        );

        final result = await coordinatorFor(
          store: store,
          native: native,
        ).initialize();

        expect(
          result.state,
          IdentityInitializationState.identityLost,
          reason: state.name,
        );
        expect(native.calls, ['status']);
        expect(store.persistCalls, 0);
      }
    });

    test('corrupt or unsupported native storage fails closed', () async {
      for (final state in <NativeIdentityState>[
        NativeIdentityState.blobCorrupt,
        NativeIdentityState.blobUnsupported,
        NativeIdentityState.metadataInvalid,
      ]) {
        final store = FakeIdentityStore(
          identityRow(
            publicKey: kKeyA,
            fingerprint: kFingerprintA,
            algorithm: AppConstants.noiseKeyAlgorithm,
            identityCreatedAt: kIdentityCreatedAt,
          ),
        );
        final native = FakeNativeIdentityGateway(
          statusResult: nativeState(state),
        );

        final result = await coordinatorFor(
          store: store,
          native: native,
        ).initialize();

        expect(
          result.state,
          IdentityInitializationState.nativeStorageInvalid,
          reason: state.name,
        );
        expect(store.persistCalls, 0);
        expect(store.identity.publicKey, kKeyA);
      }
    });

    test('native mismatch maps to mismatch without a write', () async {
      final store = FakeIdentityStore(
        identityRow(
          publicKey: kKeyA,
          fingerprint: kFingerprintA,
          algorithm: AppConstants.noiseKeyAlgorithm,
          identityCreatedAt: kIdentityCreatedAt,
        ),
      );
      final native = FakeNativeIdentityGateway(
        statusResult: nativeState(NativeIdentityState.mismatch),
      );

      final result = await coordinatorFor(
        store: store,
        native: native,
      ).initialize();

      expect(result.state, IdentityInitializationState.mismatch);
      expect(store.persistCalls, 0);
    });

    test('other native failures map to failed', () async {
      for (final state in <NativeIdentityState>[
        NativeIdentityState.nativeError,
        NativeIdentityState.storeFailed,
        NativeIdentityState.unknown,
      ]) {
        final store = FakeIdentityStore(identityRow());
        final native = FakeNativeIdentityGateway(
          statusResult: nativeState(state),
        );

        final result = await coordinatorFor(
          store: store,
          native: native,
        ).initialize();

        expect(
          result.state,
          IdentityInitializationState.failed,
          reason: state.name,
        );
        expect(native.calls, ['status']);
        expect(store.persistCalls, 0);
      }
    });

    test('a different native public key never overwrites SQLite', () async {
      final store = FakeIdentityStore(
        identityRow(
          publicKey: kKeyA,
          fingerprint: kFingerprintA,
          algorithm: AppConstants.noiseKeyAlgorithm,
          identityCreatedAt: kIdentityCreatedAt,
        ),
      );
      final native = FakeNativeIdentityGateway(
        statusResult: ready(key: kKeyB, fingerprint: kFingerprintB),
      );

      final result = await coordinatorFor(
        store: store,
        native: native,
      ).initialize();

      expect(result.state, IdentityInitializationState.mismatch);
      expect(store.persistCalls, 0);
      expect(store.identity.publicKey, kKeyA);
      expect(store.identity.publicKeyFingerprint, kFingerprintA);
      expect(store.identity.identityCreatedAt, kIdentityCreatedAt);
    });

    test('a different fingerprint never overwrites SQLite', () async {
      final store = FakeIdentityStore(
        identityRow(
          publicKey: kKeyA,
          fingerprint: kFingerprintA,
          algorithm: AppConstants.noiseKeyAlgorithm,
          identityCreatedAt: kIdentityCreatedAt,
        ),
      );
      final native = FakeNativeIdentityGateway(
        statusResult: ready(fingerprint: kFingerprintB),
      );

      final result = await coordinatorFor(
        store: store,
        native: native,
      ).initialize();

      expect(result.state, IdentityInitializationState.mismatch);
      expect(store.persistCalls, 0);
    });

    test('a different algorithm never overwrites SQLite', () async {
      final store = FakeIdentityStore(
        identityRow(
          publicKey: kKeyA,
          fingerprint: kFingerprintA,
          algorithm: 'legacy-algorithm',
          identityCreatedAt: kIdentityCreatedAt,
        ),
      );
      final native = FakeNativeIdentityGateway(statusResult: ready());

      final result = await coordinatorFor(
        store: store,
        native: native,
      ).initialize();

      expect(result.state, IdentityInitializationState.mismatch);
      expect(store.persistCalls, 0);
      expect(store.identity.keyAlgorithm, 'legacy-algorithm');
    });

    test('a malformed native ready status is rejected', () async {
      final store = FakeIdentityStore(identityRow());
      final native = FakeNativeIdentityGateway(
        statusResult: const NativeIdentityStatus(
          state: NativeIdentityState.ready,
          publicKeyHex: 'not-a-public-key',
          fingerprintHex: kFingerprintA,
        ),
      );

      final result = await coordinatorFor(
        store: store,
        native: native,
      ).initialize();

      expect(result.state, IdentityInitializationState.failed);
      expect(store.persistCalls, 0);
    });

    test(
      'a native status throw is reported as failed without provisioning',
      () async {
        final store = FakeIdentityStore(identityRow());
        final native = FakeNativeIdentityGateway(
          statusResult: nativeState(NativeIdentityState.uninitialized),
        )..statusError = StateError('channel failed');

        final result = await coordinatorFor(
          store: store,
          native: native,
        ).initialize();

        expect(result.state, IdentityInitializationState.failed);
        expect(native.calls, ['status']);
        expect(store.persistCalls, 0);
      },
    );
  });

  group('interrupted provisioning and retry', () {
    test('a failed metadata write does not generate a second key', () async {
      final store = FakeIdentityStore(identityRow())..failPersist = true;
      final native = FakeNativeIdentityGateway(
        statusResult: nativeState(NativeIdentityState.uninitialized),
        initializeResult: ready(),
      );
      final coordinator = coordinatorFor(store: store, native: native);

      final first = await coordinator.initialize();
      expect(first.state, IdentityInitializationState.synchronizationFailed);
      expect(native.calls, ['status', 'initialize']);
      expect(store.identity.publicKey, isNull);

      // Simulate the process retrying with the native identity now present.
      store.failPersist = false;
      native.statusResult = ready();

      final second = await coordinator.initialize();

      expect(second.state, IdentityInitializationState.ready);
      expect(second.publicKeyHex, kKeyA);
      expect(native.calls, ['status', 'initialize', 'status']);
      expect(
        native.calls.where((call) => call == 'initialize'),
        hasLength(1),
        reason: 'a retry must reconcile, not provision again',
      );
      expect(store.identity.publicKey, kKeyA);
      expect(store.persistCalls, 2);
    });

    test(
      'a failed repair keeps existing metadata and retries safely',
      () async {
        final store = FakeIdentityStore(
          identityRow(publicKey: kKeyA, identityCreatedAt: kIdentityCreatedAt),
        )..failPersist = true;
        final native = FakeNativeIdentityGateway(statusResult: ready());
        final coordinator = coordinatorFor(store: store, native: native);

        final first = await coordinator.initialize();
        expect(first.state, IdentityInitializationState.synchronizationFailed);
        expect(store.identity.publicKeyFingerprint, isNull);
        expect(store.identity.identityCreatedAt, kIdentityCreatedAt);

        store.failPersist = false;
        final second = await coordinator.initialize();

        expect(second.state, IdentityInitializationState.ready);
        expect(store.identity.publicKeyFingerprint, kFingerprintA);
        expect(store.identity.identityCreatedAt, kIdentityCreatedAt);
        expect(native.calls, ['status', 'status']);
      },
    );
  });

  group('bootstrap separation and platform handling', () {
    test('database failure propagates before any native call', () async {
      final store = FakeIdentityStore(identityRow());
      final native = FakeNativeIdentityGateway(statusResult: ready());
      final coordinator = coordinatorFor(
        store: store,
        native: native,
        ensureDatabase: () async => throw StateError('database unavailable'),
      );

      await expectLater(coordinator.initialize(), throwsStateError);
      expect(store.ensureCalls, 0);
      expect(native.calls, isEmpty);
    });

    test('identity row failure propagates before any native call', () async {
      final store = FakeIdentityStore(identityRow())..failEnsure = true;
      final native = FakeNativeIdentityGateway(statusResult: ready());

      await expectLater(
        coordinatorFor(store: store, native: native).initialize(),
        throwsStateError,
      );
      expect(native.calls, isEmpty);
    });

    test('unsupported platform never opens the database or channel', () async {
      var databaseOpened = false;
      final store = FakeIdentityStore(identityRow());
      final native = FakeNativeIdentityGateway(statusResult: ready());
      final coordinator = coordinatorFor(
        store: store,
        native: native,
        supported: false,
        ensureDatabase: () async => databaseOpened = true,
      );

      final result = await coordinator.initialize();

      expect(result.state, IdentityInitializationState.unsupportedPlatform);
      expect(databaseOpened, isFalse);
      expect(native.calls, isEmpty);
    });

    test(
      'published statuses contain no secrets, paths or native detail',
      () async {
        final statuses = <IdentityInitializationStatus>[
          for (final state in IdentityInitializationState.values)
            IdentityInitializationStatus(state: state),
        ];

        for (final status in statuses) {
          final text = '${status.message} $status';
          for (final forbidden in <String>[
            '/',
            r'\',
            'seed',
            'blob',
            'keystore',
            'C:',
            'BEGIN',
          ]) {
            expect(
              text.toLowerCase(),
              isNot(contains(forbidden.toLowerCase())),
              reason:
                  'status "${status.state.name}" must not leak "$forbidden"',
            );
          }
        }
      },
    );

    test('the background service has no native identity path', () async {
      for (final path in <String>[
        'lib/services/background/background_action_coordinator.dart',
        'lib/services/background/background_ble_service.dart',
        'android/app/src/main/kotlin/com/bechat/bechat/BeChatForegroundService.kt',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source, isNot(contains('NativeIdentity')), reason: path);
        expect(source, isNot(contains('bechat/native_identity')), reason: path);
      }
    });

    test('production constructs the native gateway in exactly one place', () {
      final matches = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where(
            (file) =>
                file.readAsStringSync().contains('NativeIdentityService()'),
          )
          .map((file) => file.path.replaceAll(r'\', '/'))
          .toList();

      expect(matches, ['lib/providers/identity_initialization_providers.dart']);
    });
  });

  group('SQLite integration', () {
    late Database db;

    setUp(() async {
      db = await openTestDatabase();
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'fresh provisioning fills the existing UUID row without replacing it',
      () async {
        final repository = IdentityRepository(database: () async => db);
        final created = await repository.ensureIdentity();
        await repository.updateIdentity(
          created.copyWith(displayName: 'Renamed Device'),
        );

        final coordinator = IdentityInitializationCoordinator(
          repository: repository,
          nativeIdentity: FakeNativeIdentityGateway(
            statusResult: nativeState(NativeIdentityState.uninitialized),
            initializeResult: ready(),
          ),
          ensureDatabase: () async {},
          isSupportedPlatform: () => true,
          now: () => kSyncNow,
        );

        final result = await coordinator.initialize();

        expect(result.state, IdentityInitializationState.ready);
        final row = (await db.query('identity')).single;
        expect(row['device_id'], created.deviceId);
        expect(row['id'], created.id);
        expect(row['display_name'], 'Renamed Device');
        expect(row['created_at'], created.createdAt!.toIso8601String());
        expect(row['public_key'], kKeyA);
        expect(row['public_key_fingerprint'], kFingerprintA);
        expect(row['key_algorithm'], AppConstants.noiseKeyAlgorithm);
        expect(row['identity_created_at'], isNotNull);
        expect(await db.query('identity'), hasLength(1));
      },
    );

    test(
      'a native/SQLite key conflict leaves the row byte-for-byte intact',
      () async {
        final repository = IdentityRepository(database: () async => db);
        await repository.ensureIdentity();
        await repository.savePublicIdentityMetadata(
          publicKeyHex: kKeyA,
          publicKeyFingerprint: kFingerprintA,
          identityCreatedAt: kIdentityCreatedAt,
        );
        final before = (await db.query('identity')).single;

        final coordinator = IdentityInitializationCoordinator(
          repository: repository,
          nativeIdentity: FakeNativeIdentityGateway(
            statusResult: ready(key: kKeyB, fingerprint: kFingerprintB),
          ),
          ensureDatabase: () async {},
          isSupportedPlatform: () => true,
          now: () => kSyncNow,
        );

        final result = await coordinator.initialize();

        expect(result.state, IdentityInitializationState.mismatch);
        expect((await db.query('identity')).single, before);
        expect(
          (await db.query('peers')),
          isEmpty,
          reason: 'reconciliation must not touch peer trust records',
        );
      },
    );

    test('reconciliation preserves existing peer trust history', () async {
      final repository = IdentityRepository(database: () async => db);
      await repository.ensureIdentity();
      await repository.savePublicIdentityMetadata(
        publicKeyHex: kKeyA,
        publicKeyFingerprint: kFingerprintA,
        identityCreatedAt: kIdentityCreatedAt,
      );

      final peers = PeerRepository(database: () async => db);
      await peers.upsertPeer(
        Peer(
          peerId: 'peer-verified-0001',
          displayName: 'Verified Peer',
          deviceName: 'Verified Peer Device',
          status: PeerStatus.offline,
          publicKey: kKeyB,
          publicKeyFingerprint: kFingerprintB,
          keyVerificationState: PeerKeyVerificationState.verified,
          keyVerifiedAt: kIdentityCreatedAt,
          createdAt: kRowCreatedAt,
          updatedAt: kRowCreatedAt,
        ),
      );
      final peerBefore = (await db.query('peers')).single;

      // A matching reconciliation and a conflicting one must both leave the
      // verified peer record untouched.
      await IdentityInitializationCoordinator(
        repository: repository,
        nativeIdentity: FakeNativeIdentityGateway(statusResult: ready()),
        ensureDatabase: () async {},
        isSupportedPlatform: () => true,
        now: () => kSyncNow,
      ).initialize();

      final conflicting = await IdentityInitializationCoordinator(
        repository: repository,
        nativeIdentity: FakeNativeIdentityGateway(
          statusResult: ready(key: kKeyB, fingerprint: kFingerprintB),
        ),
        ensureDatabase: () async {},
        isSupportedPlatform: () => true,
        now: () => kSyncNow,
      ).initialize();

      expect(conflicting.state, IdentityInitializationState.mismatch);
      expect((await db.query('peers')).single, peerBefore);
      expect(peerBefore['verification_state'], 'verified');
    });
  });
}
