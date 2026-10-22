import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'src/rust/api/noise.dart' as noise;

class SpikeCheck {
  const SpikeCheck({
    required this.name,
    required this.passed,
    required this.detail,
  });

  final String name;
  final bool passed;
  final String detail;
}

class SpikeReport {
  const SpikeReport(this.checks);

  final List<SpikeCheck> checks;

  bool get passed => checks.every((check) => check.passed);
}

Future<void> _expectFailure(
  Future<void> Function() operation,
  String message,
) async {
  try {
    await operation();
  } catch (_) {
    return;
  }
  throw StateError(message);
}

Future<void> _runCheck(
  List<SpikeCheck> checks,
  String name,
  Future<void> Function() operation,
) async {
  try {
    await operation();
    checks.add(SpikeCheck(name: name, passed: true, detail: 'passed'));
  } catch (error) {
    checks.add(SpikeCheck(name: name, passed: false, detail: error.toString()));
  }
}

Future<void> _xxRoundTrip() async {
  final a = await noise.createTestPeer();
  final b = await noise.createTestPeer();
  int? initiator;
  int? responder;
  try {
    final aPublic = (await noise.publicIdentity(peerHandle: a)).publicKeyHex;
    final bPublic = (await noise.publicIdentity(peerHandle: b)).publicKeyHex;
    initiator = await noise.createSession(
      peerHandle: a,
      pattern: 'XX',
      initiator: true,
    );
    responder = await noise.createSession(
      peerHandle: b,
      pattern: 'XX',
      initiator: false,
    );

    final first = await noise.handshakeStart(sessionHandle: initiator);
    final second = await noise.handshakeStep(
      sessionHandle: responder,
      incoming: first.outgoing,
    );
    final third = await noise.handshakeStep(
      sessionHandle: initiator,
      incoming: second.outgoing,
    );
    final fourth = await noise.handshakeStep(
      sessionHandle: responder,
      incoming: third.outgoing,
    );

    if (third.remotePublicKeyHex != bPublic ||
        fourth.remotePublicKeyHex != aPublic ||
        !third.finished ||
        !fourth.finished) {
      throw StateError('XX remote identity or completion check failed');
    }

    final fromA = await noise.encrypt(
      sessionHandle: initiator,
      plaintext: utf8Bytes('hello from initiator'),
    );
    final decryptedByB = await noise.decrypt(
      sessionHandle: responder,
      ciphertext: fromA,
    );
    if (utf8String(decryptedByB) != 'hello from initiator') {
      throw StateError('XX initiator to responder round trip failed');
    }

    final fromB = await noise.encrypt(
      sessionHandle: responder,
      plaintext: utf8Bytes('hello from responder'),
    );
    final decryptedByA = await noise.decrypt(
      sessionHandle: initiator,
      ciphertext: fromB,
    );
    if (utf8String(decryptedByA) != 'hello from responder') {
      throw StateError('XX responder to initiator round trip failed');
    }

    final tampered = Uint8List.fromList(fromA);
    tampered[tampered.length - 1] ^= 0x80;
    await _expectFailure(() async {
      await noise.decrypt(sessionHandle: responder!, ciphertext: tampered);
    }, 'tampered ciphertext was accepted');
  } finally {
    if (initiator != null) {
      await noise.closeSession(sessionHandle: initiator);
    }
    if (responder != null) {
      await noise.closeSession(sessionHandle: responder);
    }
    await noise.closePeer(peerHandle: a);
    await noise.closePeer(peerHandle: b);
  }
}

Future<void> _ikRoundTrip() async {
  final a = await noise.createTestPeer();
  final b = await noise.createTestPeer();
  final c = await noise.createTestPeer();
  int? initiator;
  int? responder;
  int? wrongInitiator;
  int? wrongResponder;
  try {
    final aPublic = (await noise.publicIdentity(peerHandle: a)).publicKeyHex;
    final bPublic = (await noise.publicIdentity(peerHandle: b)).publicKeyHex;
    final cPublic = (await noise.publicIdentity(peerHandle: c)).publicKeyHex;

    initiator = await noise.createSession(
      peerHandle: a,
      pattern: 'IK',
      initiator: true,
      expectedRemotePublicKeyHex: bPublic,
    );
    responder = await noise.createSession(
      peerHandle: b,
      pattern: 'IK',
      initiator: false,
      expectedRemotePublicKeyHex: aPublic,
    );

    final first = await noise.handshakeStart(sessionHandle: initiator);
    final second = await noise.handshakeStep(
      sessionHandle: responder,
      incoming: first.outgoing,
    );
    final third = await noise.handshakeStep(
      sessionHandle: initiator,
      incoming: second.outgoing,
    );
    if (second.remotePublicKeyHex != aPublic ||
        third.remotePublicKeyHex != bPublic ||
        !second.finished ||
        !third.finished) {
      throw StateError('IK remote identity or completion check failed');
    }

    final fromA = await noise.encrypt(
      sessionHandle: initiator,
      plaintext: utf8Bytes('ik initiator'),
    );
    final decryptedByB = await noise.decrypt(
      sessionHandle: responder,
      ciphertext: fromA,
    );
    if (utf8String(decryptedByB) != 'ik initiator') {
      throw StateError('IK initiator to responder round trip failed');
    }

    wrongInitiator = await noise.createSession(
      peerHandle: a,
      pattern: 'IK',
      initiator: true,
      expectedRemotePublicKeyHex: cPublic,
    );
    wrongResponder = await noise.createSession(
      peerHandle: b,
      pattern: 'IK',
      initiator: false,
      expectedRemotePublicKeyHex: aPublic,
    );
    final wrongFirst = await noise.handshakeStart(
      sessionHandle: wrongInitiator,
    );
    await _expectFailure(() async {
      await noise.handshakeStep(
        sessionHandle: wrongResponder!,
        incoming: wrongFirst.outgoing,
      );
    }, 'IK handshake accepted a mismatched pinned identity');
  } finally {
    for (final handle in [
      initiator,
      responder,
      wrongInitiator,
      wrongResponder,
    ]) {
      if (handle != null) {
        await noise.closeSession(sessionHandle: handle);
      }
    }
    await noise.closePeer(peerHandle: a);
    await noise.closePeer(peerHandle: b);
    await noise.closePeer(peerHandle: c);
  }
}

Future<void> _malformedHandshake() async {
  final b = await noise.createTestPeer();
  final responder = await noise.createSession(
    peerHandle: b,
    pattern: 'XX',
    initiator: false,
  );
  try {
    await _expectFailure(() async {
      await noise.handshakeStep(
        sessionHandle: responder,
        incoming: Uint8List.fromList([0]),
      );
    }, 'truncated handshake was accepted');
    await _expectFailure(() async {
      await noise.encrypt(
        sessionHandle: responder,
        plaintext: utf8Bytes('not ready'),
      );
    }, 'failed session accepted transport data');
  } finally {
    await noise.closeSession(sessionHandle: responder);
    await noise.closePeer(peerHandle: b);
  }
}

Future<void> _closedSession() async {
  final a = await noise.createTestPeer();
  final b = await noise.createTestPeer();
  final initiator = await noise.createSession(
    peerHandle: a,
    pattern: 'XX',
    initiator: true,
  );
  final responder = await noise.createSession(
    peerHandle: b,
    pattern: 'XX',
    initiator: false,
  );
  try {
    final first = await noise.handshakeStart(sessionHandle: initiator);
    final second = await noise.handshakeStep(
      sessionHandle: responder,
      incoming: first.outgoing,
    );
    final third = await noise.handshakeStep(
      sessionHandle: initiator,
      incoming: second.outgoing,
    );
    await noise.handshakeStep(
      sessionHandle: responder,
      incoming: third.outgoing,
    );

    await noise.closeSession(sessionHandle: initiator);
    await _expectFailure(() async {
      await noise.encrypt(
        sessionHandle: initiator,
        plaintext: utf8Bytes('closed'),
      );
    }, 'closed session accepted an operation');
    if (await noise.closeSession(sessionHandle: initiator)) {
      throw StateError('closed session handle was closed twice');
    }
  } finally {
    await noise.closeSession(sessionHandle: initiator);
    await noise.closeSession(sessionHandle: responder);
    await noise.closePeer(peerHandle: a);
    await noise.closePeer(peerHandle: b);
  }
}

Future<void> _freshSessions() async {
  final a = await noise.createTestPeer();
  final b = await noise.createTestPeer();
  final first = await noise.createSession(
    peerHandle: a,
    pattern: 'XX',
    initiator: true,
  );
  final second = await noise.createSession(
    peerHandle: a,
    pattern: 'XX',
    initiator: true,
  );
  try {
    final firstMessage = await noise.handshakeStart(sessionHandle: first);
    final secondMessage = await noise.handshakeStart(sessionHandle: second);
    if (listEquals(firstMessage.outgoing, secondMessage.outgoing)) {
      throw StateError('fresh sessions reused ephemeral handshake material');
    }
  } finally {
    await noise.closeSession(sessionHandle: first);
    await noise.closeSession(sessionHandle: second);
    await noise.closePeer(peerHandle: a);
    await noise.closePeer(peerHandle: b);
  }
}

Future<SpikeReport> runNoiseSelfTest() async {
  final checks = <SpikeCheck>[];
  await _runCheck(
    checks,
    'XX handshake, identity pin, and round trip',
    _xxRoundTrip,
  );
  await _runCheck(
    checks,
    'IK handshake, trusted identities, and round trip',
    _ikRoundTrip,
  );
  await _runCheck(
    checks,
    'Malformed handshake fails closed',
    _malformedHandshake,
  );
  await _runCheck(checks, 'Closed session rejects operations', _closedSession);
  await _runCheck(
    checks,
    'Fresh session uses fresh ephemeral material',
    _freshSessions,
  );
  return SpikeReport(checks);
}

Future<SpikeCheck> runSecureStorageProbe() async {
  const key = 'spike_test_secret';
  const value = 'not-a-real-key';
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(storageNamespace: 'bechat_crypto_spike'),
  );
  try {
    await storage.write(key: key, value: value);
    final present = await storage.containsKey(key: key);
    final readBack = await storage.read(key: key);
    await storage.delete(key: key);
    final deleted = await storage.read(key: key);
    if (!present || readBack != value || deleted != null) {
      throw StateError('secure-storage write/read/delete check failed');
    }
    return const SpikeCheck(
      name: 'Android secure-storage probe',
      passed: true,
      detail:
          'test value round-tripped; plaintext is returned to Dart by the plugin',
    );
  } catch (error) {
    return SpikeCheck(
      name: 'Android secure-storage probe',
      passed: false,
      detail: error.toString(),
    );
  }
}

Uint8List utf8Bytes(String value) => Uint8List.fromList(utf8.encode(value));

String utf8String(Uint8List value) => utf8.decode(value);
