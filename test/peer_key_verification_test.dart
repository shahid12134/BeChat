import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

/// Fixed, non-secret test vectors (32-byte values written as lowercase hex).
const String kKeyA =
    '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0';
const String kKeyB =
    '112233445566778899001122334455667788990011223344556677889900aabb';
const String kFingerprintA =
    '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';
const String kFingerprintB =
    'fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321';

void main() {
  late Database db;
  late PeerRepository repository;

  setUp(() async {
    db = await openTestDatabase();
    repository = PeerRepository(database: () async => db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> addPeer(String peerId) => repository.upsertPeer(
    Peer(peerId: peerId, displayName: 'Peer', deviceName: 'Peer Phone'),
  );

  Future<Map<String, Object?>> row(String peerId) async => (await db.query(
    'peers',
    where: 'peer_id = ?',
    whereArgs: [peerId],
  )).single;

  /// Simulates the future, explicitly reviewed verification workflow.
  Future<void> markVerified(String peerId, {String? verifiedAt}) => db.update(
    'peers',
    {
      'verification_state': PeerKeyVerificationState.verified.name,
      'key_verified_at': verifiedAt ?? DateTime.now().toUtc().toIso8601String(),
    },
    where: 'peer_id = ?',
    whereArgs: [peerId],
  );

  group('Peer model', () {
    test('serializes and deserializes verification metadata', () {
      final now = DateTime.now();
      final peer = Peer(
        id: 'row-1',
        peerId: 'peer-1',
        displayName: 'Alice',
        deviceName: 'Alice Phone',
        publicKey: kKeyA,
        publicKeyFingerprint: kFingerprintA,
        keyVerificationState: PeerKeyVerificationState.verified,
        keyVerifiedAt: now,
        keyChangedAt: now,
        isBlocked: true,
      );

      final restored = Peer.fromMap(peer.toMap());

      expect(restored.publicKey, kKeyA);
      expect(restored.publicKeyFingerprint, kFingerprintA);
      expect(restored.keyVerificationState, PeerKeyVerificationState.verified);
      expect(restored.keyVerifiedAt, isNotNull);
      expect(restored.keyChangedAt, isNotNull);
      expect(restored.isBlocked, isTrue);
      expect(restored.hasVerifiedKey, isTrue);
    });

    test('defaults to no key state and never invents trust', () {
      const peer = Peer(
        peerId: 'peer-1',
        displayName: 'Alice',
        deviceName: 'Alice Phone',
      );

      expect(peer.keyVerificationState, PeerKeyVerificationState.none);
      expect(peer.hasPublicKey, isFalse);
      expect(peer.hasVerifiedKey, isFalse);
    });

    test('an unrecognized stored state never reads back as verified', () {
      final unknown = Peer.fromMap({
        'peer_id': 'peer-1',
        'display_name': 'Alice',
        'device_name': 'Alice Phone',
        'public_key': kKeyA,
        'verification_state': 'trusted-forever',
      });
      expect(unknown.keyVerificationState, PeerKeyVerificationState.unverified);

      // A verification state without a key is not a verified key.
      final keyless = Peer.fromMap({
        'peer_id': 'peer-1',
        'display_name': 'Alice',
        'device_name': 'Alice Phone',
        'verification_state': 'verified',
      });
      expect(keyless.keyVerificationState, PeerKeyVerificationState.none);
      expect(keyless.hasVerifiedKey, isFalse);

      // Legacy rows have no state column at all.
      final legacy = Peer.fromMap({
        'peer_id': 'peer-1',
        'display_name': 'Alice',
        'device_name': 'Alice Phone',
        'public_key': kKeyA,
      });
      expect(legacy.keyVerificationState, PeerKeyVerificationState.unverified);
      expect(legacy.hasVerifiedKey, isFalse);
    });
  });

  group('recordCandidatePublicKey', () {
    test('stores a newly observed key as unverified', () async {
      await addPeer('peer-1');

      final state = await repository.recordCandidatePublicKey(
        'peer-1',
        publicKeyHex: kKeyA,
        fingerprintHex: kFingerprintA,
      );

      expect(state, PeerKeyVerificationState.unverified);
      final stored = await row('peer-1');
      expect(stored['public_key'], kKeyA);
      expect(stored['public_key_fingerprint'], kFingerprintA);
      expect(stored['verification_state'], 'unverified');
      expect(stored['key_verified_at'], isNull);
      expect(stored['key_changed_at'], isNull);
    });

    test('never marks a peer verified, however often it is called', () async {
      await addPeer('peer-1');

      await repository.recordCandidatePublicKey('peer-1', publicKeyHex: kKeyA);
      await repository.recordCandidatePublicKey('peer-1', publicKeyHex: kKeyA);

      final peer = await repository.getPeerByPeerId('peer-1');
      expect(peer!.keyVerificationState, PeerKeyVerificationState.unverified);
      expect(peer.hasVerifiedKey, isFalse);
    });

    test(
      'repeated observation of the same key keeps existing verification',
      () async {
        await addPeer('peer-1');
        await repository.recordCandidatePublicKey(
          'peer-1',
          publicKeyHex: kKeyA,
          fingerprintHex: kFingerprintA,
        );
        await markVerified('peer-1', verifiedAt: '2026-06-01T00:00:00.000Z');
        final before = await row('peer-1');

        final state = await repository.recordCandidatePublicKey(
          'peer-1',
          publicKeyHex: kKeyA,
        );

        expect(state, PeerKeyVerificationState.verified);
        final after = await row('peer-1');
        expect(after['verification_state'], 'verified');
        expect(after['key_verified_at'], before['key_verified_at']);
        expect(after['updated_at'], before['updated_at']);
      },
    );

    test('a different key becomes changed and clears verification', () async {
      await addPeer('peer-1');
      await repository.recordCandidatePublicKey(
        'peer-1',
        publicKeyHex: kKeyA,
        fingerprintHex: kFingerprintA,
      );
      await markVerified('peer-1');

      final state = await repository.recordCandidatePublicKey(
        'peer-1',
        publicKeyHex: kKeyB,
        fingerprintHex: kFingerprintB,
      );

      expect(state, PeerKeyVerificationState.changed);
      final stored = await row('peer-1');
      expect(stored['public_key'], kKeyB);
      expect(stored['public_key_fingerprint'], kFingerprintB);
      expect(stored['verification_state'], 'changed');
      expect(stored['key_verified_at'], isNull);
      expect(stored['key_changed_at'], isNotNull);
      expect(DateTime.parse(stored['key_changed_at']! as String).isUtc, isTrue);

      final peer = await repository.getPeerByPeerId('peer-1');
      expect(peer!.hasVerifiedKey, isFalse);
      expect(peer.keyVerificationState, PeerKeyVerificationState.changed);
    });

    test('preserves blocked state, presence and unrelated fields', () async {
      await repository.upsertPeer(
        Peer(
          peerId: 'peer-blocked',
          displayName: 'Blocked Peer',
          deviceName: 'Blocked Phone',
          signalStrength: -61,
          lastSeen: DateTime(2026, 4, 4, 12),
        ),
      );
      await repository.blockPeer('peer-blocked');
      final before = await row('peer-blocked');

      await repository.recordCandidatePublicKey(
        'peer-blocked',
        publicKeyHex: kKeyA,
        fingerprintHex: kFingerprintA,
      );

      final after = await row('peer-blocked');
      expect(after['is_blocked'], 1);
      expect(after['status'], PeerStatus.blocked.name);
      expect(after['display_name'], 'Blocked Peer');
      expect(after['device_name'], 'Blocked Phone');
      expect(after['signal_strength'], -61);
      expect(after['last_seen'], before['last_seen']);
      expect(after['created_at'], before['created_at']);
      expect(after['first_seen'], before['first_seen']);
      expect(after['id'], before['id']);
    });

    test('an unknown peer writes nothing', () async {
      final state = await repository.recordCandidatePublicKey(
        'peer-absent',
        publicKeyHex: kKeyA,
      );

      expect(state, isNull);
      expect(await db.query('peers'), isEmpty);
    });

    test('rejects malformed keys and fingerprints', () async {
      await addPeer('peer-1');

      final malformed = <String>[
        kKeyA.toUpperCase(),
        kKeyA.substring(0, 63),
        'not-a-key',
        '',
      ];
      for (final key in malformed) {
        await expectLater(
          repository.recordCandidatePublicKey('peer-1', publicKeyHex: key),
          throwsArgumentError,
          reason: 'key "$key" must be rejected',
        );
      }

      await expectLater(
        repository.recordCandidatePublicKey(
          'peer-1',
          publicKeyHex: kKeyA,
          fingerprintHex: 'short',
        ),
        throwsArgumentError,
      );

      final stored = await row('peer-1');
      expect(stored['public_key'], isNull);
      expect(stored['verification_state'], 'none');
    });

    test(
      'a matching device id or display name never establishes trust',
      () async {
        await repository.upsertPeer(
          const Peer(
            peerId: 'peer-alice',
            displayName: 'Alice',
            deviceName: 'Alice Phone',
            publicKey: kKeyA,
          ),
        );
        await markVerified('peer-alice');

        // Re-registering the very same peer record (same peer id and display
        // name) must not be what creates trust; only the key state does.
        await repository.upsertPeer(
          const Peer(
            peerId: 'peer-alice',
            displayName: 'Alice',
            deviceName: 'Alice Phone',
          ),
        );

        final peer = await repository.getPeerByPeerId('peer-alice');
        expect(peer!.publicKey, kKeyA);
        expect(peer.keyVerificationState, PeerKeyVerificationState.verified);
        expect(peer.hasVerifiedKey, isTrue);

        // A peer created purely from discovery data is never verified.
        await repository.upsertPeer(
          const Peer(
            peerId: 'peer-unknown',
            displayName: 'Alice',
            deviceName: 'Alice Phone',
          ),
        );
        final discovered = await repository.getPeerByPeerId('peer-unknown');
        expect(discovered!.keyVerificationState, PeerKeyVerificationState.none);
        expect(discovered.hasVerifiedKey, isFalse);
      },
    );
  });

  group('key changes through the generic peer writes', () {
    test('upsertPeer cannot promote a peer to verified', () async {
      await addPeer('peer-1');
      await repository.recordCandidatePublicKey('peer-1', publicKeyHex: kKeyA);

      await repository.upsertPeer(
        const Peer(
          peerId: 'peer-1',
          displayName: 'Peer',
          deviceName: 'Peer Phone',
          keyVerificationState: PeerKeyVerificationState.verified,
        ),
      );

      final stored = await row('peer-1');
      expect(stored['verification_state'], 'unverified');
      expect(stored['key_verified_at'], isNull);
    });

    test(
      'upsertPeer downgrades a verified peer when the key changes',
      () async {
        await addPeer('peer-1');
        await repository.recordCandidatePublicKey(
          'peer-1',
          publicKeyHex: kKeyA,
        );
        await markVerified('peer-1');

        await repository.upsertPeer(
          const Peer(
            peerId: 'peer-1',
            displayName: 'Peer',
            deviceName: 'Peer Phone',
            publicKey: kKeyB,
          ),
        );

        final stored = await row('peer-1');
        expect(stored['public_key'], kKeyB);
        expect(stored['verification_state'], 'changed');
        expect(stored['key_verified_at'], isNull);
        expect(stored['key_changed_at'], isNotNull);
      },
    );

    test('updatePeer cannot promote a peer to verified', () async {
      await addPeer('peer-1');
      await repository.recordCandidatePublicKey('peer-1', publicKeyHex: kKeyA);

      await repository.updatePeer(
        const Peer(
          peerId: 'peer-1',
          displayName: 'Peer',
          deviceName: 'Peer Phone',
          publicKey: kKeyA,
          publicKeyFingerprint: kFingerprintB,
          keyVerificationState: PeerKeyVerificationState.verified,
        ),
      );

      final stored = await row('peer-1');
      expect(stored['verification_state'], 'unverified');
      expect(stored['key_verified_at'], isNull);
      expect(stored['public_key'], kKeyA);
    });

    test('clearing the key clears the verification metadata', () async {
      await addPeer('peer-1');
      await repository.recordCandidatePublicKey(
        'peer-1',
        publicKeyHex: kKeyA,
        fingerprintHex: kFingerprintA,
      );
      await markVerified('peer-1');

      await repository.updatePeer(
        const Peer(
          peerId: 'peer-1',
          displayName: 'Peer',
          deviceName: 'Peer Phone',
        ),
      );

      final stored = await row('peer-1');
      expect(stored['public_key'], isNull);
      expect(stored['public_key_fingerprint'], isNull);
      expect(stored['verification_state'], 'none');
      expect(stored['key_verified_at'], isNull);
    });

    test('upsertPeer keeps an existing key when the model has none', () async {
      await addPeer('peer-1');
      await repository.recordCandidatePublicKey(
        'peer-1',
        publicKeyHex: kKeyA,
        fingerprintHex: kFingerprintA,
      );

      await repository.upsertPeer(
        const Peer(
          peerId: 'peer-1',
          displayName: 'Peer Renamed',
          deviceName: 'Peer Phone',
        ),
      );

      final stored = await row('peer-1');
      expect(stored['public_key'], kKeyA);
      expect(stored['public_key_fingerprint'], kFingerprintA);
      expect(stored['verification_state'], 'unverified');
      expect(stored['display_name'], 'Peer Renamed');
    });
  });
}
