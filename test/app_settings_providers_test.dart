import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/repositories/app_settings_repository.dart';
import 'package:bechat/providers/app_settings_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

void main() {
  late Database db;
  late AppSettingsRepository repository;
  late ProviderContainer container;

  setUp(() async {
    db = await openTestDatabase();
    repository = AppSettingsRepository(database: () async => db);
    container = ProviderContainer(
      overrides: [appSettingsRepositoryProvider.overrideWithValue(repository)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('provider loads default settings', () async {
    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.loadSettings();

    final settings = container.read(appSettingsProvider).valueOrNull;
    expect(settings, isNotNull);
    expect(settings!.bleEnabled, AppConstants.defaultBleEnabled);
    expect(
      settings.allowNewConnections,
      AppConstants.defaultAllowNewConnections,
    );
    expect(
      settings.backgroundBleEnabled,
      AppConstants.defaultBackgroundBleEnabled,
    );
    expect(
      settings.messagePreviewsEnabled,
      AppConstants.defaultMessagePreviewsEnabled,
    );
  });

  test('provider persists an update before exposing new state', () async {
    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.loadSettings();

    await notifier.setBleEnabled(true);

    expect(container.read(appSettingsProvider).valueOrNull?.bleEnabled, isTrue);
    expect(await repository.getBleEnabled(), isTrue);
  });
}
