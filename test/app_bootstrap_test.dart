import 'package:bechat/app/app_bootstrap.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/services/crypto/identity_initialization_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

const String kDeviceId = 'device-uuid-bootstrap-0001';

Identity bootstrapIdentity() {
  return Identity(
    id: kDeviceId,
    deviceId: kDeviceId,
    displayName: 'Bootstrap Device',
    createdAt: DateTime.utc(2026, 5, 1, 8),
  );
}

class RecordingIdentityStore implements IdentityMetadataStore {
  RecordingIdentityStore(this.calls, {this.fail = false});

  final List<String> calls;
  final bool fail;

  @override
  Future<Identity> ensureIdentity() async {
    calls.add('identity');
    if (fail) throw StateError('identity row unavailable');
    return bootstrapIdentity();
  }

  @override
  Future<Identity> savePublicIdentityMetadata({
    required String publicKeyHex,
    required String publicKeyFingerprint,
    String? privateKeyReference,
    String keyAlgorithm = AppConstants.noiseKeyAlgorithm,
    DateTime? identityCreatedAt,
  }) {
    throw UnimplementedError('bootstrap never persists metadata directly');
  }
}

void main() {
  test(
    'runs database, UUID identity, presence, crypto and demo in order',
    () async {
      final calls = <String>[];
      final identity = bootstrapIdentity();
      final bootstrap = AppBootstrap(
        identityStore: RecordingIdentityStore(calls),
        openDatabase: () async => calls.add('database'),
        resetTransientPresence: () async => calls.add('presence'),
        initializeIdentity: () async {
          calls.add('crypto');
          return const IdentityInitializationStatus(
            state: IdentityInitializationState.ready,
            deviceId: kDeviceId,
          );
        },
        seedDemoData: (seeded) async {
          calls.add('demo');
          expect(seeded.deviceId, identity.deviceId);
        },
      );

      final status = await bootstrap.run();

      expect(status.state, IdentityInitializationState.ready);
      expect(calls, ['database', 'identity', 'presence', 'crypto', 'demo']);
    },
  );

  test(
    'database failure stops before the UUID row and crypto identity',
    () async {
      final calls = <String>[];
      final bootstrap = AppBootstrap(
        identityStore: RecordingIdentityStore(calls),
        openDatabase: () async => throw StateError('database unavailable'),
        resetTransientPresence: () async => calls.add('presence'),
        initializeIdentity: () async {
          calls.add('crypto');
          return const IdentityInitializationStatus(
            state: IdentityInitializationState.ready,
          );
        },
        seedDemoData: (_) async => calls.add('demo'),
      );

      await expectLater(bootstrap.run(), throwsStateError);
      expect(calls, isEmpty);
    },
  );

  test('identity-row failure stops before the crypto identity', () async {
    final calls = <String>[];
    final bootstrap = AppBootstrap(
      identityStore: RecordingIdentityStore(calls, fail: true),
      openDatabase: () async => calls.add('database'),
      resetTransientPresence: () async => calls.add('presence'),
      initializeIdentity: () async {
        calls.add('crypto');
        return const IdentityInitializationStatus(
          state: IdentityInitializationState.ready,
        );
      },
      seedDemoData: (_) async => calls.add('demo'),
    );

    await expectLater(bootstrap.run(), throwsStateError);
    expect(calls, ['database', 'identity']);
  });

  test('crypto failure is degraded and does not stop the legacy app', () async {
    final calls = <String>[];
    const degraded = IdentityInitializationStatus(
      state: IdentityInitializationState.identityLost,
      deviceId: kDeviceId,
    );
    final bootstrap = AppBootstrap(
      identityStore: RecordingIdentityStore(calls),
      openDatabase: () async => calls.add('database'),
      resetTransientPresence: () async => calls.add('presence'),
      initializeIdentity: () async {
        calls.add('crypto');
        return degraded;
      },
      seedDemoData: (_) async => calls.add('demo'),
    );

    final status = await bootstrap.run();

    expect(status, same(degraded));
    expect(status.isDegraded, isTrue);
    expect(calls, ['database', 'identity', 'presence', 'crypto', 'demo']);
  });
}
