import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/services/crypto/identity_initialization_coordinator.dart';
import 'package:bechat/services/crypto/native_identity_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';

/// Phase 1D runtime test: real SQLite identity row plus the real Android
/// Keystore-backed native identity.
///
/// Drives the production coordinator across a fresh install, a simulated
/// interrupted SQLite synchronization and native identity loss. No seed, blob
/// or Keystore detail is read or asserted here.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final native = NativeIdentityService();
  late Database db;
  late IdentityRepository repository;

  IdentityInitializationCoordinator newCoordinator() {
    return IdentityInitializationCoordinator(
      repository: repository,
      nativeIdentity: native,
      ensureDatabase: () => DatabaseHelper.database,
      isSupportedPlatform: () => true,
    );
  }

  setUp(() async {
    await native.reset(confirm: true);
    db = await DatabaseHelper.database;
    await db.delete('identity');
    repository = IdentityRepository(database: () async => db);
  });

  tearDown(() async {
    await native.reset(confirm: true);
  });

  testWidgets('fresh install provisions once and preserves the UUID row', (
    tester,
  ) async {
    final first = await newCoordinator().initialize();

    expect(first.state, IdentityInitializationState.ready);
    expect(first.publicKeyHex, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(first.publicKeyFingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));

    final rows = await db.query('identity');
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row['device_id'], first.deviceId);
    expect(row['id'], first.deviceId);
    expect(row['public_key'], first.publicKeyHex);
    expect(row['public_key_fingerprint'], first.publicKeyFingerprint);

    final nativeStatus = await native.status();
    expect(nativeStatus.state, NativeIdentityState.ready);
    expect(nativeStatus.publicKeyHex, first.publicKeyHex);

    // A restart restores the same identity and does not rotate the row.
    final second = await newCoordinator().initialize();
    expect(second.state, IdentityInitializationState.ready);
    expect(second.publicKeyHex, first.publicKeyHex);
    expect(second.deviceId, first.deviceId);
    expect(await db.query('identity'), hasLength(1));
    expect((await db.query('identity')).single, row);
  });

  testWidgets('missing SQLite metadata reconciles the established native key', (
    tester,
  ) async {
    final first = await newCoordinator().initialize();
    expect(first.state, IdentityInitializationState.ready);
    final deviceId = (await db.query('identity')).single['device_id'];

    // Simulate a process interruption after native provisioning but before
    // SQLite metadata persistence.
    await db.update('identity', {
      'public_key': null,
      'public_key_fingerprint': null,
      'key_algorithm': null,
      'identity_created_at': null,
    });

    final reconciled = await newCoordinator().initialize();

    expect(reconciled.state, IdentityInitializationState.ready);
    expect(reconciled.publicKeyHex, first.publicKeyHex);
    expect(reconciled.deviceId, deviceId);
    final row = (await db.query('identity')).single;
    expect(row['device_id'], deviceId);
    expect(row['public_key'], first.publicKeyHex);
    expect(
      (await native.status()).publicKeyHex,
      first.publicKeyHex,
      reason: 'reconciliation must not generate a second key',
    );
  });

  testWidgets('native identity loss preserves SQLite metadata and app data', (
    tester,
  ) async {
    final first = await newCoordinator().initialize();
    expect(first.state, IdentityInitializationState.ready);
    final before = (await db.query('identity')).single;

    await native.reset(confirm: true);

    final lost = await newCoordinator().initialize();

    expect(lost.state, IdentityInitializationState.identityLost);
    expect(lost.isDegraded, isTrue);
    expect(
      (await native.status()).state,
      NativeIdentityState.uninitialized,
      reason: 'loss must never trigger automatic provisioning',
    );
    expect((await db.query('identity')).single, before);
  });
}
