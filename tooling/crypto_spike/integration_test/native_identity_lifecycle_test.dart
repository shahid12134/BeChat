import 'package:crypto_spike/native_identity.dart';
import 'package:crypto_spike/spike_self_test.dart';
import 'package:crypto_spike/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('native identity persists, fails closed, and resets', (
    tester,
  ) async {
    const service = NativeIdentityService();

    await service.reset();
    expect((await service.status()).state, 'uninitialized');

    final first = await service.provision();
    expect(first.state, 'ready');
    expect(first.publicKeyHex, hasLength(64));
    expect(first.fingerprintHex, hasLength(64));

    final restored = await service.restore();
    expect(restored.state, 'ready');
    expect(restored.publicKeyHex, first.publicKeyHex);

    final identityReport = await runNativeIdentitySelfTest();
    expect(
      identityReport.checks.where((check) => !check.passed),
      isEmpty,
      reason: identityReport.checks
          .where((check) => !check.passed)
          .map((check) => '${check.name}: ${check.detail}')
          .join('\n'),
    );

    final mismatch = await service.verifyPublicKeyMismatchRejected();
    expect(mismatch.rejected, isTrue);
    expect(mismatch.status.publicKeyHex, first.publicKeyHex);

    final corrupt = await service.debugCorruptBlob();
    expect(corrupt.state, 'corrupt');
    expect((await service.restore()).state, 'corrupt');

    await service.reset();
    expect((await service.status()).state, 'uninitialized');

    final second = await service.provision();
    expect(second.state, 'ready');
    expect(second.publicKeyHex, isNot(first.publicKeyHex));

    final missingBlob = await service.debugDeleteBlob();
    expect(missingBlob.state, 'identity_lost');
    expect((await service.restore()).state, 'identity_lost');

    await service.reset();
    final third = await service.provision();
    expect(third.state, 'ready');

    final missingKey = await service.debugDeleteKeystoreKey();
    expect(missingKey.state, 'key_unavailable');
    expect((await service.restore()).state, 'key_unavailable');

    await service.reset();
    final fourth = await service.provision();
    expect(fourth.state, 'ready');
    expect(fourth.publicKeyHex, isNot(third.publicKeyHex));

    await service.reset();
    expect((await service.status()).state, 'uninitialized');
  });
}
