import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

/// Fixed, non-secret test vectors (32-byte values written as lowercase hex).
const String kPublicKeyHex =
    'ab12cd34ef56ab78cd90ef12ab34cd56ef78ab90cd12ef34ab56cd78ef90ab12';
const String kFingerprintHex =
    '9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0';
const String kOpaqueReference = 'keystore:bechat_identity_wrap_v1';

void main() {
  late Database db;
  late IdentityRepository repository;

  setUp(() async {
    db = await openTestDatabase();
    repository = IdentityRepository(database: () async => db);
  });

  tearDown(() async {
    await db.close();
  });

  group('Identity model', () {
    test('serializes and deserializes the cryptographic metadata fields', () {
      final now = DateTime.now();
      final identity = Identity(
        id: 'device-1',
        deviceId: 'device-1',
        displayName: 'My Device',
        publicKey: kPublicKeyHex,
        privateKeyReference: kOpaqueReference,
        publicKeyFingerprint: kFingerprintHex,
        keyAlgorithm: AppConstants.noiseKeyAlgorithm,
        identityCreatedAt: now,
        createdAt: now,
        updatedAt: now,
      );

      final restored = Identity.fromMap(identity.toMap());

      expect(restored.publicKey, kPublicKeyHex);
      expect(restored.publicKeyFingerprint, kFingerprintHex);
      expect(restored.keyAlgorithm, AppConstants.noiseKeyAlgorithm);
      expect(restored.privateKeyReference, kOpaqueReference);
      expect(restored.identityCreatedAt, isNotNull);
    });

    test('legacy rows without the new columns deserialize as null', () {
      final restored = Identity.fromMap({
        'id': 'device-1',
        'device_id': 'device-1',
        'display_name': 'Legacy',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      expect(restored.publicKey, isNull);
      expect(restored.publicKeyFingerprint, isNull);
      expect(restored.keyAlgorithm, isNull);
      expect(restored.identityCreatedAt, isNull);
    });
  });

  group('savePublicIdentityMetadata', () {
    test('persists public key, fingerprint, algorithm and reference', () async {
      final created = await repository.ensureIdentity();

      final updated = await repository.savePublicIdentityMetadata(
        publicKeyHex: kPublicKeyHex,
        publicKeyFingerprint: kFingerprintHex,
        privateKeyReference: kOpaqueReference,
      );

      expect(updated.publicKey, kPublicKeyHex);
      expect(updated.publicKeyFingerprint, kFingerprintHex);
      expect(updated.keyAlgorithm, AppConstants.noiseKeyAlgorithm);
      expect(updated.privateKeyReference, kOpaqueReference);
      expect(updated.identityCreatedAt, isNotNull);
      expect(updated.identityCreatedAt!.isUtc, isTrue);

      final reread = await repository.getIdentity();
      expect(reread!.publicKey, kPublicKeyHex);
      expect(reread.publicKeyFingerprint, kFingerprintHex);
      expect(reread.keyAlgorithm, AppConstants.noiseKeyAlgorithm);
      expect(reread.identityCreatedAt, updated.identityCreatedAt);

      final byDeviceId = await repository.getIdentityByDeviceId(
        created.deviceId,
      );
      expect(byDeviceId!.publicKey, kPublicKeyHex);
    });

    test('preserves device UUID, display name and creation time', () async {
      final created = await repository.ensureIdentity();
      await repository.updateIdentity(
        created.copyWith(displayName: 'Renamed Device'),
      );

      await repository.savePublicIdentityMetadata(
        publicKeyHex: kPublicKeyHex,
        publicKeyFingerprint: kFingerprintHex,
      );

      final row = (await db.query('identity')).single;
      expect(row['device_id'], created.deviceId);
      expect(row['id'], created.id);
      expect(row['display_name'], 'Renamed Device');
      expect(row['created_at'], created.createdAt!.toIso8601String());
      expect(await db.query('identity'), hasLength(1));
    });

    test('keeps an existing reference when none is supplied', () async {
      await repository.ensureIdentity();
      await repository.savePublicIdentityMetadata(
        publicKeyHex: kPublicKeyHex,
        publicKeyFingerprint: kFingerprintHex,
        privateKeyReference: kOpaqueReference,
      );

      await repository.savePublicIdentityMetadata(
        publicKeyHex: kPublicKeyHex,
        publicKeyFingerprint: kFingerprintHex,
      );

      final row = (await db.query('identity')).single;
      expect(row['private_key_reference'], kOpaqueReference);
    });

    test('rejects malformed public keys and fingerprints', () async {
      await repository.ensureIdentity();

      final malformedKeys = <String>[
        kPublicKeyHex.toUpperCase(),
        kPublicKeyHex.substring(0, 63),
        '${kPublicKeyHex}00',
        'z' * 64,
        'preserved-public-key',
        '',
      ];
      for (final key in malformedKeys) {
        await expectLater(
          repository.savePublicIdentityMetadata(
            publicKeyHex: key,
            publicKeyFingerprint: kFingerprintHex,
          ),
          throwsArgumentError,
          reason: 'public key "$key" must be rejected',
        );
      }

      await expectLater(
        repository.savePublicIdentityMetadata(
          publicKeyHex: kPublicKeyHex,
          publicKeyFingerprint: kFingerprintHex.toUpperCase(),
        ),
        throwsArgumentError,
      );

      // Nothing was written by any rejected call.
      final row = (await db.query('identity')).single;
      expect(row['public_key'], isNull);
      expect(row['public_key_fingerprint'], isNull);
    });

    test('rejects references that could carry key material or a path', () async {
      await repository.ensureIdentity();

      final unsafeReferences = <String>[
        '/data/user/0/com.bechat.bechat/no_backup/bechat_identity/identity.blob',
        r'C:\Users\someone\blob.bin',
        kPublicKeyHex, // a raw key value is not a reference
        'AAAA$kFingerprintHex==',
        'blob with spaces',
        '',
      ];
      for (final reference in unsafeReferences) {
        await expectLater(
          repository.savePublicIdentityMetadata(
            publicKeyHex: kPublicKeyHex,
            publicKeyFingerprint: kFingerprintHex,
            privateKeyReference: reference,
          ),
          throwsArgumentError,
          reason: 'reference "$reference" must be rejected',
        );
      }
    });

    test('rejects an empty key algorithm', () async {
      await repository.ensureIdentity();

      await expectLater(
        repository.savePublicIdentityMetadata(
          publicKeyHex: kPublicKeyHex,
          publicKeyFingerprint: kFingerprintHex,
          keyAlgorithm: '   ',
        ),
        throwsArgumentError,
      );
    });

    test('refuses to create an identity row', () async {
      expect(await db.query('identity'), isEmpty);

      await expectLater(
        repository.savePublicIdentityMetadata(
          publicKeyHex: kPublicKeyHex,
          publicKeyFingerprint: kFingerprintHex,
        ),
        throwsA(isA<StateError>()),
      );

      expect(await db.query('identity'), isEmpty);
    });

    test('stores no private key material or envelope in the row', () async {
      await repository.ensureIdentity();
      await repository.savePublicIdentityMetadata(
        publicKeyHex: kPublicKeyHex,
        publicKeyFingerprint: kFingerprintHex,
        privateKeyReference: kOpaqueReference,
      );

      final row = (await db.query('identity')).single;

      // Column set is exactly the schema: no private key, seed or blob column.
      expect(
        row.keys.where(
          (column) =>
              column.contains('seed') ||
              column.contains('blob') ||
              column.contains('wrapped') ||
              column == 'private_key',
        ),
        isEmpty,
      );

      // The only private-ish value is the opaque reference, and it is not a
      // location or a key.
      expect(row['private_key_reference'], kOpaqueReference);
      expect(row['private_key_reference'], isNot(contains('/')));
      expect((row['private_key_reference']! as String).length, lessThan(128));

      final values = row.values.whereType<String>().toList();
      expect(values, contains(kPublicKeyHex));
      expect(values, contains(kFingerprintHex));
      // A private seed would be a 32-byte hex string that is not the public key.
      final unexpectedHex = values.where(
        (value) => value.length == 64 && value != kPublicKeyHex,
      );
      expect(unexpectedHex, everyElement(kFingerprintHex));
    });
  });
}
