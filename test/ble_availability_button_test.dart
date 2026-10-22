import 'package:bechat/core/widgets/ble_availability_button.dart';
import 'package:bechat/data/models/app_settings.dart';
import 'package:bechat/data/repositories/app_settings_repository.dart';
import 'package:bechat/providers/app_settings_providers.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offline control persists intent before starting', (
    tester,
  ) async {
    final settings = _FakeAppSettingsRepository();
    late _FakeBleRuntimeController runtime;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(settings),
          bleRuntimeProvider.overrideWith((ref) {
            runtime = _FakeBleRuntimeController(ref);
            return runtime;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(appBar: AppBar(actions: [BleAvailabilityButton()])),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byTooltip('BeChat is offline. Tap to turn on.'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('BeChat is offline. Tap to turn on.'));
    await tester.pump();
    await tester.pump();

    expect(settings.bleEnabled, isTrue);
    expect(runtime.calls, [true]);
    expect(
      find.byTooltip('BeChat is starting. Tap to turn off.'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('connected control confirms before turning off', (tester) async {
    final settings = _FakeAppSettingsRepository(bleEnabled: true);
    late _FakeBleRuntimeController runtime;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(settings),
          bleRuntimeProvider.overrideWith((ref) {
            runtime = _FakeBleRuntimeController(
              ref,
              const BleRuntimeState(
                status: BleRuntimeStatus.connected,
                activePeerId: 'device-b',
                activePeerName: 'Bob',
              ),
            );
            return runtime;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(appBar: AppBar(actions: [BleAvailabilityButton()])),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byTooltip('BeChat is online and connected. Tap to turn off.'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Turn off BeChat?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(settings.bleEnabled, isTrue);
    expect(runtime.calls, isEmpty);

    await tester.tap(
      find.byTooltip('BeChat is online and connected. Tap to turn off.'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn Off'));
    await tester.pumpAndSettle();

    expect(settings.bleEnabled, isFalse);
    expect(runtime.calls, [false]);
  });
}

class _FakeAppSettingsRepository extends AppSettingsRepository {
  _FakeAppSettingsRepository({this.bleEnabled = false});

  bool bleEnabled;

  @override
  Future<AppSettings> loadSettings() async {
    return AppSettings(bleEnabled: bleEnabled);
  }

  @override
  Future<bool> getBleEnabled() async => bleEnabled;

  @override
  Future<void> setBleEnabled(bool value) async {
    bleEnabled = value;
  }
}

class _FakeBleRuntimeController extends BleRuntimeController {
  _FakeBleRuntimeController(
    super.ref, [
    BleRuntimeState initialState = const BleRuntimeState(),
  ]) {
    state = initialState;
  }

  final List<bool> calls = [];

  @override
  Future<void> setAvailabilityEnabled(bool enabled) async {
    calls.add(enabled);
    state = BleRuntimeState(
      status: enabled ? BleRuntimeStatus.starting : BleRuntimeStatus.idle,
    );
  }
}
