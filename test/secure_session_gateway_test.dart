import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bechat/providers/secure_session_providers.dart';
import 'package:bechat/services/crypto/native_secure_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativeSecureSessionGateway.channelName);
  late NativeSecureSessionGateway gateway;
  late List<MethodCall> calls;

  /// A fixed 32-byte remote public key as lowercase hex (64 chars).
  const remoteKeyHex =
      'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

  Map<String, Object?> handshakeMap({
    required List<int> outgoing,
    required bool finished,
    required bool confirmationRequired,
    Map<String, Object?>? remoteIdentity,
  }) => <String, Object?>{
    'outgoing': Uint8List.fromList(outgoing),
    'finished': finished,
    'confirmationRequired': confirmationRequired,
    'remoteIdentity': remoteIdentity,
  };

  Map<String, Object?> statusMap({
    required String stage,
    required bool remoteIdentityAvailable,
    String? remotePublicKeyHex,
  }) => <String, Object?>{
    'stage': stage,
    'remoteIdentityAvailable': remoteIdentityAvailable,
    'remotePublicKeyHex': remotePublicKeyHex,
  };

  Map<String, Object?> identityMap({
    String publicKeyHex = remoteKeyHex,
    String deviceId = 'peer-device',
    String displayName = 'Peer',
    int protocolVersion = 1,
    int capabilities = 0x01,
  }) => <String, Object?>{
    'publicKeyHex': publicKeyHex,
    'deviceId': deviceId,
    'displayName': displayName,
    'protocolVersion': protocolVersion,
    'capabilities': capabilities,
  };

  void respondWith(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  /// A fake native session mirroring the Kotlin controller's response shapes
  /// and error codes so tests never contradict the real contract.
  Object? Function(MethodCall) fakeController({
    int Function(int handle)? stageForHandle,
  }) {
    var nextHandle = 1;
    return (call) {
      switch (call.method) {
        case 'createSession':
          return <String, Object?>{'handle': nextHandle++};
        case 'startHandshake':
          return handshakeMap(
            outgoing: const [1, 2, 3],
            finished: false,
            confirmationRequired: false,
          );
        case 'processHandshake':
          return handshakeMap(
            outgoing: const [4, 5],
            finished: true,
            confirmationRequired: true,
            remoteIdentity: identityMap(),
          );
        case 'getSessionStatus':
          final handle = (call.arguments as Map)['handle']! as int;
          final label = stageForHandle == null
              ? 'awaiting_confirmation'
              : _stageLabel(stageForHandle(handle));
          return statusMap(
            stage: label,
            remoteIdentityAvailable: true,
            remotePublicKeyHex: remoteKeyHex,
          );
        case 'confirmPeerIdentity':
          return <String, Object?>{'confirmed': true};
        case 'encrypt':
          return <String, Object?>{
            'ciphertext': Uint8List.fromList([9, 9]),
          };
        case 'decrypt':
          return <String, Object?>{
            'plaintext': Uint8List.fromList([7, 7]),
          };
        case 'closeSession':
          return <String, Object?>{'closed': true};
        default:
          return null;
      }
    };
  }

  setUp(() {
    gateway = NativeSecureSessionGateway(channel: channel);
    calls = <MethodCall>[];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('method contract', () {
    test(
      'createSession calls the correct method with serialized arguments',
      () async {
        respondWith(fakeController());

        final handle = await gateway.createSession(
          initiator: true,
          deviceId: 'local-device',
          displayName: 'Local',
          pinnedRemotePublicKey: Uint8List.fromList(List<int>.filled(32, 1)),
          expectedRemoteDeviceId: 'peer-device',
        );

        expect(handle.isClosed, isFalse);
        expect(calls, hasLength(1));
        expect(calls.single.method, 'createSession');
        final args = Map<String, Object?>.from(calls.single.arguments as Map);
        expect(args['initiator'], isTrue);
        expect(args['deviceId'], 'local-device');
        expect(args['displayName'], 'Local');
        expect(
          args['pinnedRemotePublicKeyHex'],
          allOf(hasLength(64), matches(RegExp(r'^[0-9a-f]{64}$'))),
        );
        expect(args['expectedRemoteDeviceId'], 'peer-device');
      },
    );

    test(
      'createSession omits optional pin and expected-device when absent',
      () async {
        respondWith(fakeController());

        await gateway.createSession(
          initiator: false,
          deviceId: 'local-device',
          displayName: 'Local',
        );

        final args = Map<String, Object?>.from(calls.single.arguments as Map);
        expect(args.containsKey('pinnedRemotePublicKeyHex'), isFalse);
        expect(args.containsKey('expectedRemoteDeviceId'), isFalse);
        expect(args['initiator'], isFalse);
      },
    );

    test(
      'startHandshake sends only the handle and parses a pending step',
      () async {
        respondWith(fakeController());
        final handle = await gateway.createSession(
          initiator: true,
          deviceId: 'a',
          displayName: 'b',
        );
        calls.clear();

        final step = await gateway.startHandshake(handle);

        expect(calls.single.method, 'startHandshake');
        expect(calls.single.arguments, {'handle': 1});
        expect(step.outgoing, isA<Uint8List>());
        expect(step.outgoing, const [1, 2, 3]);
        expect(step.finished, isFalse);
        expect(step.confirmationRequired, isFalse);
        expect(step.remoteIdentity, isNull);
      },
    );

    test(
      'processHandshake forwards binary input and parses the identity',
      () async {
        respondWith(fakeController());
        final handle = await gateway.createSession(
          initiator: false,
          deviceId: 'a',
          displayName: 'b',
        );
        calls.clear();

        final step = await gateway.processHandshake(
          handle,
          Uint8List.fromList(const [1, 2]),
        );

        expect(calls.single.method, 'processHandshake');
        final args = Map<String, Object?>.from(calls.single.arguments as Map);
        expect(args['handle'], 1);
        expect(args['incoming'], isA<Uint8List>());
        expect(args['incoming'], const [1, 2]);
        expect(step.finished, isTrue);
        expect(step.confirmationRequired, isTrue);
        final identity = step.remoteIdentity!;
        expect(identity.publicKeyHex, remoteKeyHex);
        expect(identity.deviceId, 'peer-device');
        expect(identity.displayName, 'Peer');
        expect(identity.protocolVersion, 1);
        expect(identity.capabilities, 0x01);
        expect(identity.supportsCapability(0x01), isTrue);
        expect(identity.supportsCapability(0x02), isFalse);
      },
    );

    test('getSessionStatus parses a typed status snapshot', () async {
      respondWith(fakeController(stageForHandle: (_) => 2));
      final handle = await gateway.createSession(
        initiator: true,
        deviceId: 'a',
        displayName: 'b',
      );
      calls.clear();

      final status = await gateway.getSessionStatus(handle);

      expect(calls.single.method, 'getSessionStatus');
      expect(calls.single.arguments, {'handle': 1});
      expect(status.stage, SecureSessionStage.ready);
      expect(status.isReady, isTrue);
      expect(status.remoteIdentityAvailable, isTrue);
      expect(status.remotePublicKeyHex, remoteKeyHex);
    });

    test(
      'confirmPeerIdentity sends the handle and requires confirmed true',
      () async {
        respondWith(fakeController());
        final handle = await gateway.createSession(
          initiator: true,
          deviceId: 'a',
          displayName: 'b',
        );
        calls.clear();

        await gateway.confirmPeerIdentity(handle);

        expect(calls.single.method, 'confirmPeerIdentity');
        expect(calls.single.arguments, {'handle': 1});
      },
    );

    test(
      'encrypt and decrypt forward binary payloads and return binary',
      () async {
        respondWith(fakeController());
        final handle = await gateway.createSession(
          initiator: true,
          deviceId: 'a',
          displayName: 'b',
        );
        calls.clear();

        final ciphertext = await gateway.encrypt(
          handle,
          Uint8List.fromList(const [1, 2, 3]),
        );
        expect(calls.last.method, 'encrypt');
        final encArgs = Map<String, Object?>.from(calls.last.arguments as Map);
        expect(encArgs['plaintext'], isA<Uint8List>());
        expect(encArgs['plaintext'], const [1, 2, 3]);
        expect(ciphertext, isA<Uint8List>());
        expect(ciphertext, const [9, 9]);

        final plaintext = await gateway.decrypt(
          handle,
          Uint8List.fromList(const [9, 9]),
        );
        expect(calls.last.method, 'decrypt');
        final decArgs = Map<String, Object?>.from(calls.last.arguments as Map);
        expect(decArgs['ciphertext'], isA<Uint8List>());
        expect(decArgs['ciphertext'], const [9, 9]);
        expect(plaintext, const [7, 7]);
      },
    );

    test('closeSession calls the native close with the handle', () async {
      respondWith(fakeController());
      final handle = await gateway.createSession(
        initiator: true,
        deviceId: 'a',
        displayName: 'b',
      );
      calls.clear();

      await gateway.closeSession(handle);

      expect(calls.single.method, 'closeSession');
      expect(calls.single.arguments, {'handle': 1});
    });
  });

  group('validation and error handling', () {
    test('a createSession response without a handle is rejected', () async {
      respondWith((_) => <String, Object?>{});

      await expectLater(
        gateway.createSession(initiator: true, deviceId: 'a', displayName: 'b'),
        throwsA(isA<SecureSessionUnexpectedResponse>()),
      );
    });

    test('a non-positive handle is rejected as unusable', () async {
      respondWith((_) => <String, Object?>{'handle': 0});

      await expectLater(
        gateway.createSession(initiator: true, deviceId: 'a', displayName: 'b'),
        throwsA(isA<SecureSessionUnexpectedResponse>()),
      );
    });

    test('a wrongly typed handle is rejected', () async {
      respondWith((_) => <String, Object?>{'handle': 'one'});

      await expectLater(
        gateway.createSession(initiator: true, deviceId: 'a', displayName: 'b'),
        throwsA(isA<SecureSessionUnexpectedResponse>()),
      );
    });

    test(
      'empty local device ID or display name is refused before traffic',
      () async {
        respondWith(fakeController());

        await expectLater(
          gateway.createSession(
            initiator: true,
            deviceId: '',
            displayName: 'b',
          ),
          throwsA(isA<SecureSessionInvalidArgument>()),
        );
        await expectLater(
          gateway.createSession(
            initiator: true,
            deviceId: 'a',
            displayName: '',
          ),
          throwsA(isA<SecureSessionInvalidArgument>()),
        );
        expect(calls, isEmpty);
      },
    );

    test('a pin that is not 32 bytes is refused before traffic', () async {
      respondWith(fakeController());

      await expectLater(
        gateway.createSession(
          initiator: true,
          deviceId: 'a',
          displayName: 'b',
          pinnedRemotePublicKey: Uint8List.fromList(const [1, 2, 3]),
        ),
        throwsA(isA<SecureSessionInvalidArgument>()),
      );
      expect(calls, isEmpty);
    });

    test('an empty handshake message is refused before traffic', () async {
      respondWith(fakeController());
      final handle = await gateway.createSession(
        initiator: false,
        deviceId: 'a',
        displayName: 'b',
      );
      calls.clear();

      await expectLater(
        gateway.processHandshake(handle, Uint8List(0)),
        throwsA(isA<SecureSessionInvalidArgument>()),
      );
      expect(calls, isEmpty);
    });

    test(
      'a malformed handshake response (missing outgoing) is rejected',
      () async {
        respondWith(
          (call) => switch (call.method) {
            'createSession' => <String, Object?>{'handle': 1},
            _ => <String, Object?>{
              'finished': true,
              'confirmationRequired': true,
              'remoteIdentity': null,
            },
          },
        );
        final handle = await gateway.createSession(
          initiator: true,
          deviceId: 'a',
          displayName: 'b',
        );

        await expectLater(
          gateway.startHandshake(handle),
          throwsA(isA<SecureSessionUnexpectedResponse>()),
        );
      },
    );

    test('a wrongly typed binary field is rejected', () async {
      respondWith(
        (call) => switch (call.method) {
          'createSession' => <String, Object?>{'handle': 1},
          _ => <String, Object?>{
            'outgoing': 'not-bytes',
            'finished': true,
            'confirmationRequired': true,
            'remoteIdentity': null,
          },
        },
      );
      final handle = await gateway.createSession(
        initiator: true,
        deviceId: 'a',
        displayName: 'b',
      );

      await expectLater(
        gateway.startHandshake(handle),
        throwsA(isA<SecureSessionUnexpectedResponse>()),
      );
    });

    test('a wrongly typed remoteIdentity is rejected', () async {
      respondWith(
        (call) => switch (call.method) {
          'createSession' => <String, Object?>{'handle': 1},
          _ => <String, Object?>{
            'outgoing': Uint8List.fromList(const [1]),
            'finished': true,
            'confirmationRequired': true,
            'remoteIdentity': 'not-a-map',
          },
        },
      );
      final handle = await gateway.createSession(
        initiator: true,
        deviceId: 'a',
        displayName: 'b',
      );

      await expectLater(
        gateway.startHandshake(handle),
        throwsA(isA<SecureSessionUnexpectedResponse>()),
      );
    });

    test(
      'a non-map response is rejected for status, encrypt and decrypt',
      () async {
        respondWith(fakeController());
        final handle = await gateway.createSession(
          initiator: true,
          deviceId: 'a',
          displayName: 'b',
        );

        respondWith((_) => 'not-a-map');
        await expectLater(
          gateway.getSessionStatus(handle),
          throwsA(isA<SecureSessionUnexpectedResponse>()),
        );
        await expectLater(
          gateway.encrypt(handle, Uint8List.fromList(const [1])),
          throwsA(isA<SecureSessionUnexpectedResponse>()),
        );
        await expectLater(
          gateway.decrypt(handle, Uint8List.fromList(const [1])),
          throwsA(isA<SecureSessionUnexpectedResponse>()),
        );
      },
    );

    test(
      'an unknown stage is handled conservatively and never ready',
      () async {
        respondWith(
          (call) => switch (call.method) {
            'createSession' => <String, Object?>{'handle': 1},
            _ => statusMap(
              stage: 'something_new',
              remoteIdentityAvailable: true,
              remotePublicKeyHex: remoteKeyHex,
            ),
          },
        );
        final handle = await gateway.createSession(
          initiator: true,
          deviceId: 'a',
          displayName: 'b',
        );

        final status = await gateway.getSessionStatus(handle);
        expect(status.stage, isNull);
        expect(status.isReady, isFalse);
      },
    );

    test('a wrongly typed remotePublicKeyHex in status is rejected', () async {
      respondWith(
        (call) => switch (call.method) {
          'createSession' => <String, Object?>{'handle': 1},
          _ => <String, Object?>{
            'stage': 'ready',
            'remoteIdentityAvailable': true,
            'remotePublicKeyHex': 12345,
          },
        },
      );
      final handle = await gateway.createSession(
        initiator: true,
        deviceId: 'a',
        displayName: 'b',
      );

      await expectLater(
        gateway.getSessionStatus(handle),
        throwsA(isA<SecureSessionUnexpectedResponse>()),
      );
    });

    test('a missing confirmed flag is rejected as unusable', () async {
      respondWith(
        (call) => switch (call.method) {
          'createSession' => <String, Object?>{'handle': 1},
          _ => <String, Object?>{'confirmed': false},
        },
      );
      final handle = await gateway.createSession(
        initiator: true,
        deviceId: 'a',
        displayName: 'b',
      );

      await expectLater(
        gateway.confirmPeerIdentity(handle),
        throwsA(isA<SecureSessionUnexpectedResponse>()),
      );
    });

    test('native error codes map to typed exceptions', () async {
      final handle = await _openHandle(gateway, respondWith, fakeController);

      Future<SecureSessionException> errorFrom(String code) {
        respondWith(
          (_) => throw PlatformException(code: code, message: 'raw detail'),
        );
        return gateway
            .encrypt(handle, Uint8List.fromList(const [1]))
            .then<SecureSessionException>(
              (_) => fail('expected a failure'),
              onError: (Object e) => e as SecureSessionException,
            );
      }

      expect(
        await errorFrom('SESSION_INVALID_ARGUMENT'),
        isA<SecureSessionInvalidArgument>(),
      );
      expect(await errorFrom('SESSION_BUSY'), isA<SecureSessionBusy>());
      expect(
        await errorFrom('SESSION_NATIVE_ERROR'),
        isA<SecureSessionNativeFailure>(),
      );
      expect(
        await errorFrom('SOME_UNKNOWN_CODE'),
        isA<SecureSessionNativeFailure>(),
      );
    });

    test(
      'PlatformException and missing-plugin failures are not successes',
      () async {
        final handle = await _openHandle(gateway, respondWith, fakeController);

        respondWith(
          (_) => throw PlatformException(code: 'SESSION_NATIVE_ERROR'),
        );
        await expectLater(
          gateway.encrypt(handle, Uint8List.fromList(const [1])),
          throwsA(isA<SecureSessionNativeFailure>()),
        );

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await expectLater(
          gateway.encrypt(handle, Uint8List.fromList(const [1])),
          throwsA(isA<SecureSessionNativeFailure>()),
        );
      },
    );

    test(
      'no error message carries raw native or secret-bearing text',
      () async {
        final handle = await _openHandle(gateway, respondWith, fakeController);
        const raw = 'sensitive native detail that must not leak';
        respondWith(
          (_) => throw PlatformException(
            code: 'SESSION_NATIVE_ERROR',
            message: raw,
          ),
        );

        final error = await gateway
            .encrypt(handle, Uint8List.fromList(const [1]))
            .then<Object?>((_) => null, onError: (Object e) => e);

        expect(error, isNotNull);
        expect(error.toString(), isNot(contains(raw)));
        expect(error.toString(), isNot(contains('sensitive')));
        expect(error.toString(), isNot(contains('seed')));
        expect(error.toString(), isNot(contains('private')));
      },
    );
  });

  group('session lifecycle', () {
    test('a session is not ready until native reports ready', () async {
      respondWith(
        (call) => switch (call.method) {
          'createSession' => <String, Object?>{'handle': 1},
          _ => statusMap(stage: 'handshaking', remoteIdentityAvailable: false),
        },
      );
      final handle = await gateway.createSession(
        initiator: true,
        deviceId: 'a',
        displayName: 'b',
      );

      final status = await gateway.getSessionStatus(handle);
      expect(status.isReady, isFalse);
      expect(status.stage, SecureSessionStage.handshaking);
    });

    test(
      'a finished handshake with confirmation required is not yet ready',
      () async {
        respondWith(
          (call) => switch (call.method) {
            'createSession' => <String, Object?>{'handle': 1},
            'startHandshake' => handshakeMap(
              outgoing: const [1],
              finished: true,
              confirmationRequired: true,
              remoteIdentity: identityMap(),
            ),
            _ => statusMap(
              stage: 'awaiting_confirmation',
              remoteIdentityAvailable: true,
            ),
          },
        );
        final handle = await gateway.createSession(
          initiator: true,
          deviceId: 'a',
          displayName: 'b',
        );

        final step = await gateway.startHandshake(handle);
        expect(step.finished, isTrue);
        expect(step.confirmationRequired, isTrue);

        final status = await gateway.getSessionStatus(handle);
        expect(status.isReady, isFalse);
        expect(status.stage, SecureSessionStage.awaitingConfirmation);
      },
    );

    test('confirmation errors propagate as typed failures', () async {
      final handle = await _openHandle(gateway, respondWith, fakeController);
      respondWith(
        (_) => throw PlatformException(
          code: 'SESSION_NATIVE_ERROR',
          message: 'session is not awaiting confirmation',
        ),
      );

      await expectLater(
        gateway.confirmPeerIdentity(handle),
        throwsA(isA<SecureSessionNativeFailure>()),
      );
    });

    test(
      'closing invalidates the reference and later operations are rejected',
      () async {
        respondWith(fakeController());
        final handle = await gateway.createSession(
          initiator: true,
          deviceId: 'a',
          displayName: 'b',
        );
        calls.clear();

        await gateway.closeSession(handle);
        expect(handle.isClosed, isTrue);
        calls.clear();

        await expectLater(
          gateway.encrypt(handle, Uint8List.fromList(const [1])),
          throwsA(isA<SecureSessionClosed>()),
        );
        await expectLater(
          gateway.decrypt(handle, Uint8List.fromList(const [1])),
          throwsA(isA<SecureSessionClosed>()),
        );
        await expectLater(
          gateway.startHandshake(handle),
          throwsA(isA<SecureSessionClosed>()),
        );
        await expectLater(
          gateway.processHandshake(handle, Uint8List.fromList(const [1])),
          throwsA(isA<SecureSessionClosed>()),
        );
        await expectLater(
          gateway.getSessionStatus(handle),
          throwsA(isA<SecureSessionClosed>()),
        );
        await expectLater(
          gateway.confirmPeerIdentity(handle),
          throwsA(isA<SecureSessionClosed>()),
        );
        expect(
          calls,
          isEmpty,
          reason: 'closed references never reach the channel',
        );
      },
    );

    test('closing an already-closed reference is a no-op', () async {
      respondWith(fakeController());
      final handle = await gateway.createSession(
        initiator: true,
        deviceId: 'a',
        displayName: 'b',
      );
      await gateway.closeSession(handle);
      calls.clear();

      await gateway.closeSession(handle);

      expect(calls, isEmpty);
    });

    test('a failed encrypt does not fall back to plaintext', () async {
      final handle = await _openHandle(gateway, respondWith, fakeController);
      respondWith((_) => throw PlatformException(code: 'SESSION_NATIVE_ERROR'));

      final result = await gateway
          .encrypt(handle, Uint8List.fromList(const [1, 2, 3]))
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect(result, isA<SecureSessionException>());
      expect(result, isNot(isA<Uint8List>()));
    });
  });

  group('provider', () {
    test('the provider produces the production MethodChannel gateway', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final provided = container.read(secureSessionGatewayProvider);
      expect(provided, isA<NativeSecureSessionGateway>());
    });

    test('a fake gateway can be injected', () {
      final fake = _FakeGateway();
      final container = ProviderContainer(
        overrides: [secureSessionGatewayProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      expect(container.read(secureSessionGatewayProvider), same(fake));
    });

    test('reading or recreating the provider sends no channel traffic', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      respondWith((_) => fail('no channel traffic expected'));

      container.read(secureSessionGatewayProvider);
      container.invalidate(secureSessionGatewayProvider);
      container.read(secureSessionGatewayProvider);

      expect(calls, isEmpty);
    });
  });
}

/// The native stage ordinals used by the fake controller, mapped to the fixed
/// Kotlin labels.
String _stageLabel(int ordinal) => switch (ordinal) {
  0 => 'handshaking',
  1 => 'awaiting_confirmation',
  2 => 'ready',
  3 => 'failed',
  _ => 'unknown_stage',
};

/// Obtains a valid open handle by driving the fake controller once.
Future<SecureSessionHandle> _openHandle(
  NativeSecureSessionGateway gateway,
  void Function(Object? Function(MethodCall)) respondWith,
  Object? Function(MethodCall) Function({int Function(int)? stageForHandle})
  fakeController,
) async {
  respondWith(fakeController());
  return gateway.createSession(
    initiator: true,
    deviceId: 'a',
    displayName: 'b',
  );
}

/// A fake gateway that records calls without touching any channel.
class _FakeGateway implements SecureSessionGateway {
  int created = 0;
  int closed = 0;

  @override
  Future<SecureSessionHandle> createSession({
    required bool initiator,
    required String deviceId,
    required String displayName,
    Uint8List? pinnedRemotePublicKey,
    String? expectedRemoteDeviceId,
  }) async {
    created++;
    return SecureSessionHandle.forTesting(1);
  }

  @override
  Future<HandshakeStepResult> startHandshake(
    SecureSessionHandle session,
  ) async => HandshakeStepResult(
    outgoing: Uint8List(0),
    finished: false,
    confirmationRequired: false,
  );

  @override
  Future<HandshakeStepResult> processHandshake(
    SecureSessionHandle session,
    Uint8List incoming,
  ) async => HandshakeStepResult(
    outgoing: Uint8List(0),
    finished: false,
    confirmationRequired: false,
  );

  @override
  Future<SecureSessionStatus> getSessionStatus(
    SecureSessionHandle session,
  ) async => const SecureSessionStatus(
    stage: SecureSessionStage.handshaking,
    remoteIdentityAvailable: false,
  );

  @override
  Future<void> confirmPeerIdentity(SecureSessionHandle session) async {}

  @override
  Future<Uint8List> encrypt(
    SecureSessionHandle session,
    Uint8List plaintext,
  ) async => Uint8List(0);

  @override
  Future<Uint8List> decrypt(
    SecureSessionHandle session,
    Uint8List ciphertext,
  ) async => Uint8List(0);

  @override
  Future<void> closeSession(SecureSessionHandle session) async {
    closed++;
  }
}
