import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bechat/services/crypto/native_crypto_backend.dart';
import 'package:bechat/services/crypto/native_identity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativeIdentityService.channelName);
  late NativeIdentityService service;
  late List<MethodCall> calls;

  Map<String, Object?> statusMap({
    required String state,
    String? publicKeyHex,
    String? fingerprintHex,
    String? message,
  }) => <String, Object?>{
    'state': state,
    'publicKeyHex': publicKeyHex,
    'fingerprintHex': fingerprintHex,
    'message': message,
  };

  void respondWith(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(() {
    service = NativeIdentityService(channel: channel);
    calls = <MethodCall>[];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('initialize calls the platform once with no arguments and parses ready status', () async {
    const publicKey =
        'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
    respondWith(
      (_) => statusMap(
        state: 'ready',
        publicKeyHex: publicKey,
        fingerprintHex: List.filled(32, '0').join() + List.filled(32, '1').join(),
      ),
    );

    final status = await service.initialize();

    expect(status.state, NativeIdentityState.ready);
    expect(status.isReady, isTrue);
    expect(status.publicKeyHex, publicKey);
    expect(status.fingerprintHex, hasLength(64));
    expect(calls, hasLength(1));
    expect(calls.single.method, NativeIdentityService.initializeMethod);
    expect(calls.single.arguments, isNull);
  });

  test('every documented native state is mapped, and unknown values never become ready', () {
    const expected = <String, NativeIdentityState>{
      'uninitialized': NativeIdentityState.uninitialized,
      'ready': NativeIdentityState.ready,
      'blob_missing': NativeIdentityState.blobMissing,
      'blob_corrupt': NativeIdentityState.blobCorrupt,
      'blob_unsupported': NativeIdentityState.blobUnsupported,
      'key_unavailable': NativeIdentityState.keyUnavailable,
      'metadata_invalid': NativeIdentityState.metadataInvalid,
      'mismatch': NativeIdentityState.mismatch,
      'native_error': NativeIdentityState.nativeError,
      'store_failed': NativeIdentityState.storeFailed,
    };

    for (final entry in expected.entries) {
      final status = NativeIdentityStatus.fromMap(
        statusMap(state: entry.key, message: 'fixed text'),
      );
      expect(status.state, entry.value, reason: entry.key);
      expect(status.message, 'fixed text');
    }

    final unknown = NativeIdentityStatus.fromMap(
      statusMap(state: 'something_new', publicKeyHex: List.filled(32, 'ab').join()),
    );
    expect(unknown.state, NativeIdentityState.unknown);
    expect(unknown.isReady, isFalse);
  });

  test('malformed public fields are dropped instead of surfaced', () {
    final status = NativeIdentityStatus.fromMap(
      statusMap(
        state: 'ready',
        publicKeyHex: 'not-hex',
        fingerprintHex: List.filled(32, 'AB').join(),
      ),
    );

    expect(status.publicKeyHex, isNull);
    expect(status.fingerprintHex, isNull);
  });

  test('reset without confirmation is refused before any platform traffic', () async {
    respondWith((_) => statusMap(state: 'uninitialized'));

    await expectLater(
      service.reset(confirm: false),
      throwsA(isA<NativeCryptoBackendException>()),
    );
    expect(calls, isEmpty, reason: 'no channel call may happen without confirmation');
  });

  test('reset with confirmation is sent explicitly', () async {
    respondWith((_) => statusMap(state: 'uninitialized'));

    final status = await service.reset(confirm: true);

    expect(status.state, NativeIdentityState.uninitialized);
    expect(calls, hasLength(1));
    expect(calls.single.method, NativeIdentityService.resetMethod);
    expect(calls.single.arguments, {NativeIdentityService.resetConfirmArgument: true});
  });

  test('reset failures report a fixed message and never leak native detail', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          throw PlatformException(
            code: 'RESET_NOT_CONFIRMED',
            message: 'sensitive native detail that must not leak',
          );
        });

    final error = await service
        .reset(confirm: true)
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<NativeCryptoBackendException>());
    expect(error.toString(), isNot(contains('sensitive')));
    expect(error.toString(), contains('could not complete'));
  });

  test('a missing platform channel fails closed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    await expectLater(
      service.status(),
      throwsA(isA<NativeCryptoBackendException>()),
    );
  });

  test('an unusable native response fails closed', () async {
    respondWith((_) => 'not-a-map');

    await expectLater(
      service.initialize(),
      throwsA(
        isA<NativeCryptoBackendException>().having(
          (e) => e.message,
          'message',
          contains('unusable response'),
        ),
      ),
    );
  });

  test('the Dart service exposes no seed or byte-level identity surface', () {
    final source = File(
      'lib/services/crypto/native_identity_service.dart',
    ).readAsStringSync();

    // The seed-bearing native entry points are Kotlin/Rust only.
    for (final forbidden in <String>[
      'nativeGenerateSeed',
      'nativeInstallSeed',
      'nativePublicKeyForSeed',
      'nativeInstalledPublicKeyHex',
      'Uint8List',
      'List<int>',
    ]) {
      expect(
        source.contains(forbidden),
        isFalse,
        reason: '$forbidden must not appear in the Dart-facing identity service',
      );
    }
  });
}
