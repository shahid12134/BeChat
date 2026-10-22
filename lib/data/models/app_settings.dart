import 'package:bechat/core/constants/app_constants.dart';

class AppSettings {
  const AppSettings({
    this.bleEnabled = AppConstants.defaultBleEnabled,
    this.allowNewConnections = AppConstants.defaultAllowNewConnections,
    this.backgroundBleEnabled = AppConstants.defaultBackgroundBleEnabled,
    this.messagePreviewsEnabled = AppConstants.defaultMessagePreviewsEnabled,
  });

  final bool bleEnabled;
  final bool allowNewConnections;
  final bool backgroundBleEnabled;
  final bool messagePreviewsEnabled;

  AppSettings copyWith({
    bool? bleEnabled,
    bool? allowNewConnections,
    bool? backgroundBleEnabled,
    bool? messagePreviewsEnabled,
  }) {
    return AppSettings(
      bleEnabled: bleEnabled ?? this.bleEnabled,
      allowNewConnections: allowNewConnections ?? this.allowNewConnections,
      backgroundBleEnabled: backgroundBleEnabled ?? this.backgroundBleEnabled,
      messagePreviewsEnabled:
          messagePreviewsEnabled ?? this.messagePreviewsEnabled,
    );
  }
}
