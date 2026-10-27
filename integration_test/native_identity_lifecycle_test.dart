import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:bechat/services/crypto/native_identity_service.dart';

/// Phase 1B runtime test of the production identity lifecycle on a real
/// device or emulator.
///
/// This drives the complete production path:
/// Dart -> MethodChannel `bechat/native_identity` -> Kotlin
/// `NativeIdentityController` -> [IdentityBlobStore] (Android Keystore
/// AES-256-GCM + `noBackupFilesDir`) -> JNI -> Rust identity core.
///
/// Only non-secret status crosses back into Dart. Corrupt/missing-blob and
/// Keystore-loss states are covered on-device by the Android instrumentation
/// suite, which can manipulate those files directly without the app exposing
/// test-only hooks.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final service = NativeIdentityService();

  testWidgets('identity provisions, restores, refuses unconfirmed reset, resets',
      (tester) async {
    // Start from a known state so the test is repeatable on one device.
    final cleared = await service.reset(confirm: true);
    expect(cleared.state, NativeIdentityState.uninitialized);

    // First provisioning.
    final first = await service.initialize();
    expect(first.state, NativeIdentityState.ready);
    expect(first.publicKeyHex, isNotNull);
    expect(first.publicKeyHex, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(first.fingerprintHex, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(first.message, isNull);

    // Restart / repeated initialization must restore, never rotate.
    final restored = await service.initialize();
    expect(restored.state, NativeIdentityState.ready);
    expect(restored.publicKeyHex, first.publicKeyHex);
    expect(restored.fingerprintHex, first.fingerprintHex);

    final reported = await service.status();
    expect(reported.state, NativeIdentityState.ready);
    expect(reported.publicKeyHex, first.publicKeyHex);

    // An unconfirmed reset is refused and changes nothing.
    await expectLater(
      service.reset(confirm: false),
      throwsA(isA<Exception>()),
    );
    final afterRefusal = await service.status();
    expect(afterRefusal.state, NativeIdentityState.ready);
    expect(afterRefusal.publicKeyHex, first.publicKeyHex);

    // A confirmed reset clears the identity.
    final reset = await service.reset(confirm: true);
    expect(reset.state, NativeIdentityState.uninitialized);
    expect(reset.publicKeyHex, isNull);
    expect(reset.fingerprintHex, isNull);
    expect((await service.status()).state, NativeIdentityState.uninitialized);

    // Re-provisioning after an explicit reset creates a new identity.
    final second = await service.initialize();
    expect(second.state, NativeIdentityState.ready);
    expect(second.publicKeyHex, isNot(first.publicKeyHex));

    // Leave the device without a persisted identity.
    expect((await service.reset(confirm: true)).state, NativeIdentityState.uninitialized);
  });
}
