class AppConstants {
  static const String appName = 'BeChat';
  static const String appVersion = '1.0.0';
  static const String databaseName = 'bechat.db';
  static const int databaseVersion = 1;

  static const Duration scanTimeout = Duration(seconds: 15);
  static const Duration mockResponseDelay = Duration(milliseconds: 800);
  static const Duration messageTtlDefault = Duration(hours: 24);

  static const int maxMessageLength = 4096;
  static const int defaultPageSize = 50;

  static const String defaultDeviceName = 'My BeChat Device';
  static const String defaultAvatarPath = '';

  // Future Phase 3: will hold actual device identity
  static const String placeholderDeviceId = 'local-device-001';
}
