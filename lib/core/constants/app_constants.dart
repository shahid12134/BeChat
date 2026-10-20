class AppConstants {
  static const String appName = 'BeChat';
  static const String appVersion = '1.0.0';
  static const String databaseName = 'bechat.db';
  static const int databaseVersion = 2;

  static const Duration scanTimeout = Duration(seconds: 15);
  static const Duration mockResponseDelay = Duration(milliseconds: 800);
  static const Duration messageTtlDefault = Duration(hours: 24);

  static const int maxMessageLength = 4096;
  static const int defaultPageSize = 50;

  static const String defaultDeviceName = 'My BeChat Device';
  static const String defaultAvatarPath = '';

  static const bool demoDataEnabled = bool.fromEnvironment(
    'BECHAT_DEMO_DATA',
    defaultValue: false,
  );

  // Legacy installations used this shared ID before unique identities existed.
  static const String legacyPlaceholderDeviceId = 'local-device-001';
}
