import 'package:bechat/app/app_bootstrap.dart';
import 'package:bechat/app/bootstrap_host.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/providers/identity_initialization_providers.dart';
import 'package:bechat/services/crypto/identity_initialization_coordinator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeIdentityStore implements IdentityMetadataStore {
  @override
  Future<Identity> ensureIdentity() async {
    return const Identity(
      id: 'device-1',
      deviceId: 'device-1',
      displayName: 'Device One',
    );
  }

  @override
  Future<Identity> savePublicIdentityMetadata({
    required String publicKeyHex,
    required String publicKeyFingerprint,
    String? privateKeyReference,
    String keyAlgorithm = AppConstants.noiseKeyAlgorithm,
    DateTime? identityCreatedAt,
  }) {
    throw UnimplementedError();
  }
}

AppBootstrap _bootstrap({
  Future<void> Function()? openDatabase,
  Future<IdentityInitializationStatus> Function()? initializeIdentity,
}) {
  return AppBootstrap(
    identityStore: _FakeIdentityStore(),
    openDatabase: openDatabase ?? () async {},
    resetTransientPresence: () async {},
    initializeIdentity:
        initializeIdentity ??
        () async => const IdentityInitializationStatus(
          state: IdentityInitializationState.ready,
          deviceId: 'device-1',
        ),
    seedDemoData: (_) async {},
  );
}

void main() {
  testWidgets('bootstrap failure shows a recoverable error screen', (
    tester,
  ) async {
    var attempts = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: BootstrapHost(
          bootstrap: () async {
            attempts++;
            throw StateError('database unavailable');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Startup failed'), findsOneWidget);
    expect(find.textContaining('database unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(attempts, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Startup failed'), findsOneWidget);
  });

  testWidgets('bootstrap success builds the app', (tester) async {
    await tester.pumpWidget(
      ProviderScope(child: BootstrapHost(bootstrap: () async {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('BeChat'), findsOneWidget);
  });

  testWidgets('database failure remains a fatal startup failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBootstrapProvider.overrideWithValue(
            _bootstrap(
              openDatabase: () async =>
                  throw StateError('database unavailable'),
            ),
          ),
        ],
        child: const BootstrapHost(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Startup failed'), findsOneWidget);
    expect(find.textContaining('database unavailable'), findsOneWidget);
  });

  testWidgets('cryptographic identity failure does not fail startup', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBootstrapProvider.overrideWithValue(
            _bootstrap(
              initializeIdentity: () async =>
                  const IdentityInitializationStatus(
                    state: IdentityInitializationState.identityLost,
                    deviceId: 'device-1',
                  ),
            ),
          ),
        ],
        child: const BootstrapHost(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('BeChat'), findsOneWidget);
    expect(find.text('Startup failed'), findsNothing);
  });
}
