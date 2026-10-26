import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:bechat/services/crypto/native_crypto_backend.dart';

/// Phase 1A runtime smoke test.
///
/// Proves the packaged `libbechat_crypto.so` loads inside the production
/// Android app and that Rust code executes across the real
/// Dart -> MethodChannel -> Kotlin -> JNI boundary.
///
/// Returns only a fixed, non-secret version string: no identity is
/// generated, no database is touched and no key material is involved.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native crypto backend loads and reports its version',
      (tester) async {
    final version = await NativeCryptoBackend().backendVersion();

    expect(version, 'bechat-crypto-core/0.1.0 snow/0.10.0');
  });
}
