import 'dart:async';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/providers/identity_initialization_providers.dart';
import 'package:bechat/services/crypto/identity_initialization_coordinator.dart';
import 'package:bechat/services/crypto/native_identity_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const String kKey =
    'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
const String kFingerprint =
    'f0e1d2c3b4a5968778695a4b3c2d1e0ff0e1d2c3b4a5968778695a4b3c2d1e0f';

Identity identityRow() {
  return Identity(
    id: 'device-1',
    deviceId: 'device-1',
    displayName: 'Device One',
    createdAt: DateTime.utc(2026, 5, 1, 8),
  );
}

class _Store implements IdentityMetadataStore {
  Identity identity = identityRow();

  @override
  Future<Identity> ensureIdentity() async => identity;

  @override
  Future<Identity> savePublicIdentityMetadata({
    required String publicKeyHex,
    required String publicKeyFingerprint,
    String? privateKeyReference,
    String keyAlgorithm = AppConstants.noiseKeyAlgorithm,
    DateTime? identityCreatedAt,
  }) async {
    identity = identity.copyWith(
      publicKey: publicKeyHex,
      publicKeyFingerprint: publicKeyFingerprint,
      keyAlgorithm: keyAlgorithm,
      identityCreatedAt: identityCreatedAt ?? DateTime.utc(2026, 10, 28),
    );
    return identity;
  }
}

class _Gateway implements NativeIdentityGateway {
  _Gateway({required this.statusResult, this.initializeResult});

  NativeIdentityStatus statusResult;
  NativeIdentityStatus? initializeResult;
  int statusCalls = 0;
  int initializeCalls = 0;
  Completer<void>? gate;

  @override
  Future<NativeIdentityStatus> status() async {
    statusCalls++;
    final gate = this.gate;
    if (gate != null) await gate.future;
    return statusResult;
  }

  @override
  Future<NativeIdentityStatus> initialize() async {
    initializeCalls++;
    return initializeResult ?? statusResult;
  }
}

IdentityInitializationCoordinator _coordinator(
  _Store store,
  _Gateway gateway, {
  Future<void> Function()? ensureDatabase,
}) {
  return IdentityInitializationCoordinator(
    repository: store,
    nativeIdentity: gateway,
    ensureDatabase: ensureDatabase ?? () async {},
    isSupportedPlatform: () => true,
    now: () => DateTime.utc(2026, 10, 28),
  );
}

ProviderContainer _container(IdentityInitializationCoordinator coordinator) {
  return ProviderContainer(
    overrides: [
      identityInitializationCoordinatorProvider.overrideWithValue(coordinator),
    ],
  );
}

void main() {
  test('starts initializing and publishes a ready status', () async {
    final gateway = _Gateway(
      statusResult: const NativeIdentityStatus(
        state: NativeIdentityState.uninitialized,
      ),
      initializeResult: const NativeIdentityStatus(
        state: NativeIdentityState.ready,
        publicKeyHex: kKey,
        fingerprintHex: kFingerprint,
      ),
    );
    final container = _container(_coordinator(_Store(), gateway));
    addTearDown(container.dispose);

    expect(
      container.read(identityInitializationProvider).state,
      IdentityInitializationState.initializing,
    );

    final result = await container
        .read(identityInitializationProvider.notifier)
        .initialize();

    expect(result.state, IdentityInitializationState.ready);
    final published = container.read(identityInitializationProvider);
    expect(published.state, IdentityInitializationState.ready);
    expect(published.publicKeyHex, kKey);
    expect(published.publicKeyFingerprint, kFingerprint);
    expect(gateway.initializeCalls, 1);
  });

  test('publishes a degraded status without throwing', () async {
    final gateway = _Gateway(
      statusResult: const NativeIdentityStatus(
        state: NativeIdentityState.blobCorrupt,
      ),
    );
    final container = _container(_coordinator(_Store(), gateway));
    addTearDown(container.dispose);

    final result = await container
        .read(identityInitializationProvider.notifier)
        .initialize();

    expect(result.state, IdentityInitializationState.nativeStorageInvalid);
    expect(result.isDegraded, isTrue);
    expect(
      container.read(identityInitializationProvider).state,
      IdentityInitializationState.nativeStorageInvalid,
    );
    expect(gateway.initializeCalls, 0);
  });

  test('concurrent controller calls join one coordinator operation', () async {
    final gate = Completer<void>();
    final gateway = _Gateway(
      statusResult: const NativeIdentityStatus(
        state: NativeIdentityState.ready,
        publicKeyHex: kKey,
        fingerprintHex: kFingerprint,
      ),
    )..gate = gate;
    final store = _Store()
      ..identity = identityRow().copyWith(
        publicKey: kKey,
        publicKeyFingerprint: kFingerprint,
        keyAlgorithm: AppConstants.noiseKeyAlgorithm,
        identityCreatedAt: DateTime.utc(2026, 5, 2),
      );
    final container = _container(_coordinator(store, gateway));
    addTearDown(container.dispose);

    final notifier = container.read(identityInitializationProvider.notifier);
    final first = notifier.initialize();
    final second = notifier.initialize();
    gate.complete();
    final results = await Future.wait([first, second]);

    expect(
      results.map((status) => status.state),
      everyElement(IdentityInitializationState.ready),
    );
    expect(gateway.statusCalls, 1);
    expect(
      container.read(identityInitializationProvider).state,
      IdentityInitializationState.ready,
    );
  });

  test('database failure propagates instead of becoming a status', () async {
    final container = _container(
      _coordinator(
        _Store(),
        _Gateway(
          statusResult: const NativeIdentityStatus(
            state: NativeIdentityState.ready,
          ),
        ),
        ensureDatabase: () async => throw StateError('database unavailable'),
      ),
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(identityInitializationProvider.notifier).initialize(),
      throwsStateError,
    );
  });
}
