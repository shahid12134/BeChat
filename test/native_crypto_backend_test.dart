import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bechat/services/crypto/native_crypto_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativeCryptoBackend.channelName);
  late NativeCryptoBackend backend;
  late List<MethodCall> calls;

  setUp(() {
    backend = NativeCryptoBackend(channel: channel);
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return 'bechat-crypto-core/0.1.0 snow/0.10.0';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('backendVersion invokes the smoke method with no arguments', () async {
    final version = await backend.backendVersion();

    expect(version, 'bechat-crypto-core/0.1.0 snow/0.10.0');
    expect(calls, hasLength(1));
    expect(calls.single.method, NativeCryptoBackend.backendVersionMethod);
    expect(calls.single.arguments, isNull);
  });

  test('an empty native response fails closed with a fixed error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);

    await expectLater(
      backend.backendVersion(),
      throwsA(
        isA<NativeCryptoBackendException>().having(
          (e) => e.message,
          'message',
          contains('returned no version'),
        ),
      ),
    );
  });

  test('native errors never leak their detail into the Dart exception', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'NATIVE_CRYPTO_UNAVAILABLE',
            message: 'sensitive native detail that must not leak',
          );
        });

    final error = await backend
        .backendVersion()
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<NativeCryptoBackendException>());
    final text = error.toString();
    expect(text, isNot(contains('sensitive')));
    expect(text, contains('unavailable'));
  });

  test('a missing platform channel fails closed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    await expectLater(
      backend.backendVersion(),
      throwsA(isA<NativeCryptoBackendException>()),
    );
  });
}
