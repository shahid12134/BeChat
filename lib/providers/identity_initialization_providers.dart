import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/app/app_bootstrap.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/providers/settings_providers.dart';
import 'package:bechat/services/crypto/identity_initialization_coordinator.dart';
import 'package:bechat/services/crypto/native_identity_service.dart';

/// The only production construction point for the native identity gateway.
///
/// Bootstrap, UI and background code must go through
/// [identityInitializationProvider]; none of them may construct a second
/// native identity path.
final nativeIdentityGatewayProvider = Provider<NativeIdentityGateway>((ref) {
  return NativeIdentityService();
});

final identityInitializationCoordinatorProvider =
    Provider<IdentityInitializationCoordinator>((ref) {
      return IdentityInitializationCoordinator(
        repository: ref.watch(identityRepositoryProvider),
        nativeIdentity: ref.watch(nativeIdentityGatewayProvider),
      );
    });

/// Publishes the non-secret cryptographic identity status to the application.
class IdentityInitializationController
    extends StateNotifier<IdentityInitializationStatus> {
  IdentityInitializationController(this._coordinator)
    : super(
        const IdentityInitializationStatus(
          state: IdentityInitializationState.initializing,
        ),
      );

  final IdentityInitializationCoordinator _coordinator;

  /// Runs the shared initialization operation and publishes its outcome.
  ///
  /// Concurrent callers join the coordinator's single flight. Database
  /// failures propagate unchanged so bootstrap can keep treating them as
  /// fatal; cryptographic failures arrive as a degraded status.
  Future<IdentityInitializationStatus> initialize() async {
    if (mounted && state.state != IdentityInitializationState.initializing) {
      state = const IdentityInitializationStatus(
        state: IdentityInitializationState.initializing,
      );
    }

    final result = await _coordinator.initialize();
    if (mounted) state = result;
    return result;
  }
}

final identityInitializationProvider =
    StateNotifierProvider<
      IdentityInitializationController,
      IdentityInitializationStatus
    >((ref) {
      return IdentityInitializationController(
        ref.watch(identityInitializationCoordinatorProvider),
      );
    });

/// The authoritative startup pipeline.
///
/// Database initialization and UUID identity creation happen before the
/// cryptographic coordinator runs, and only this pipeline invokes it. The
/// foreground BLE service has no access to this provider or the native
/// identity channel, so it cannot provision a second identity.
final appBootstrapProvider = Provider<AppBootstrap>((ref) {
  return AppBootstrap(
    identityStore: ref.watch(identityRepositoryProvider),
    initializeIdentity: () =>
        ref.read(identityInitializationProvider.notifier).initialize(),
    openDatabase: () => DatabaseHelper.database,
    resetTransientPresence: () => PeerRepository().resetTransientPresence(),
  );
});
