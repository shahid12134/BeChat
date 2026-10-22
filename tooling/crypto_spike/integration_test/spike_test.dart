import 'package:crypto_spike/spike_self_test.dart';
import 'package:crypto_spike/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('Noise XX/IK bridge self-test', (tester) async {
    final report = await runNoiseSelfTest();
    final failures = report.checks.where((check) => !check.passed).toList();
    expect(
      failures,
      isEmpty,
      reason: failures
          .map((check) => '${check.name}: ${check.detail}')
          .join('\n'),
    );
  });

  testWidgets('Android secure-storage probe', (tester) async {
    final check = await runSecureStorageProbe();
    expect(check.passed, isTrue, reason: check.detail);
  });
}
