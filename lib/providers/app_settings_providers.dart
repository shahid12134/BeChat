import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/data/models/app_settings.dart';
import 'package:bechat/data/repositories/app_settings_repository.dart';

final appSettingsRepositoryProvider = Provider<AppSettingsRepository>((ref) {
  return AppSettingsRepository();
});

final appSettingsProvider =
    StateNotifierProvider<AppSettingsNotifier, AsyncValue<AppSettings>>((ref) {
      return AppSettingsNotifier(ref.read(appSettingsRepositoryProvider));
    });

class AppSettingsNotifier extends StateNotifier<AsyncValue<AppSettings>> {
  AppSettingsNotifier(this._repository) : super(const AsyncValue.loading()) {
    loadSettings();
  }

  final AppSettingsRepository _repository;

  Future<void> loadSettings() async {
    state = const AsyncValue.loading();
    try {
      final settings = await _repository.loadSettings();
      state = AsyncValue.data(settings);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> setBleEnabled(bool value) async {
    await _repository.setBleEnabled(value);
    await _update((settings) => settings.copyWith(bleEnabled: value));
  }

  Future<void> setAllowNewConnections(bool value) async {
    await _repository.setAllowNewConnections(value);
    await _update((settings) => settings.copyWith(allowNewConnections: value));
  }

  Future<void> setBackgroundBleEnabled(bool value) async {
    await _repository.setBackgroundBleEnabled(value);
    await _update((settings) => settings.copyWith(backgroundBleEnabled: value));
  }

  Future<void> setMessagePreviewsEnabled(bool value) async {
    await _repository.setMessagePreviewsEnabled(value);
    await _update(
      (settings) => settings.copyWith(messagePreviewsEnabled: value),
    );
  }

  Future<void> _update(AppSettings Function(AppSettings) transform) async {
    final current = state.valueOrNull;
    if (current == null) {
      await loadSettings();
      return;
    }
    state = AsyncValue.data(transform(current));
  }
}
