import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/mock/mock_data.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/services/crypto/identity_initialization_coordinator.dart';

/// Seeds optional demo rows for a freshly created local identity.
typedef DemoDataSeeder = Future<void> Function(Identity identity);

/// The authoritative application startup sequence.
///
/// Failures in [openDatabase], [IdentityMetadataStore.ensureIdentity] or
/// transient-presence reset propagate and remain bootstrap failures. The
/// cryptographic identity step is different: it reports a degraded
/// [IdentityInitializationStatus] instead of throwing, so existing local data
/// and the legacy plaintext message path stay available.
class AppBootstrap {
  AppBootstrap({
    required this.identityStore,
    required this.initializeIdentity,
    Future<void> Function()? openDatabase,
    Future<void> Function()? resetTransientPresence,
    DemoDataSeeder? seedDemoData,
  }) : _openDatabase = openDatabase ?? (() => DatabaseHelper.database),
       _resetTransientPresence =
           resetTransientPresence ??
           (() => PeerRepository().resetTransientPresence()),
       _seedDemoData = seedDemoData ?? _seedDemoDataIfEnabled;

  final IdentityMetadataStore identityStore;

  /// Runs the single-flight cryptographic identity coordinator.
  final Future<IdentityInitializationStatus> Function() initializeIdentity;

  final Future<void> Function() _openDatabase;
  final Future<void> Function() _resetTransientPresence;
  final DemoDataSeeder _seedDemoData;

  static Future<void> _seedDemoDataIfEnabled(Identity identity) async {
    if (AppConstants.demoDataEnabled) {
      await MockData.seedDemoData(identity);
    }
  }

  /// Initializes storage, the UUID identity and then the cryptographic
  /// identity, in that order.
  Future<IdentityInitializationStatus> run() async {
    // Fatal if this fails: the existing startup error screen handles it.
    await _openDatabase();

    // Creates the UUID row only when none exists. The row is required before
    // any cryptographic metadata can be persisted.
    final identity = await identityStore.ensureIdentity();

    await _resetTransientPresence();

    // Degraded, not fatal. The coordinator preserves the row and never
    // provisions over an established identity.
    final identityStatus = await initializeIdentity();

    await _seedDemoData(identity);

    return identityStatus;
  }
}
