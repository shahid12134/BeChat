class AppConstants {
  static const String appName = 'BeChat';
  static const String appVersion = '1.0.0';
  static const String databaseName = 'bechat.db';
  static const int databaseVersion = 7;

  // Persistent application settings.
  static const String settingBleEnabled = 'ble_enabled';
  static const String settingAllowNewConnections = 'allow_new_connections';
  static const String settingBackgroundBleEnabled = 'background_ble_enabled';
  static const String settingMessagePreviewsEnabled =
      'message_previews_enabled';

  static const bool defaultBleEnabled = false;
  static const bool defaultAllowNewConnections = true;
  static const bool defaultBackgroundBleEnabled = false;
  static const bool defaultMessagePreviewsEnabled = false;

  static const Duration scanTimeout = Duration(seconds: 15);
  static const Duration candidateExpiration = Duration(seconds: 10);
  static const Duration candidateCleanupInterval = Duration(seconds: 2);
  static const Duration incomingRequestTimeout = Duration(seconds: 30);
  static const Duration declineCooldown = Duration(seconds: 60);
  static const Duration presenceForegroundInterval = Duration(seconds: 20);
  static const Duration presenceBackgroundInterval = Duration(seconds: 60);
  static const Duration presenceProbeTimeout = Duration(seconds: 5);
  static const Duration gattTeardownTimeout = Duration(seconds: 5);
  static const Duration mockResponseDelay = Duration(milliseconds: 800);
  static const Duration messageTtlDefault = Duration(hours: 24);

  static const int maxMessageLength = 4096;
  static const int defaultPageSize = 50;

  // ---------------------------------------------------------------------
  // Media transfer. Every limit lives here so it can be changed in one place;
  // `attachment_policy.dart`, the Firestore rules and the Storage rules all
  // mirror these numbers.
  // ---------------------------------------------------------------------
  static const int maxImageBytes = 10 * 1024 * 1024;
  static const int maxVideoBytes = 50 * 1024 * 1024;
  static const int maxDocumentBytes = 20 * 1024 * 1024;

  /// Hard ceiling used by the Storage rules (the largest per-kind limit).
  static const int maxAttachmentBytes = maxVideoBytes;

  /// Storage prefix; the full path is `attachments/{uploaderUid}/{messageId}`.
  static const String mediaStoragePrefix = 'attachments';

  static const List<String> imageMimeTypes = [
    'image/jpeg',
    'image/png',
    'image/webp',
  ];

  static const List<String> videoMimeTypes = ['video/mp4', 'video/quicktime'];

  static const List<String> documentMimeTypes = [
    'application/pdf',
    'text/plain',
    'text/csv',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/zip',
  ];

  /// Bounded filename length; names are display-only and never used in paths.
  static const int maxFileNameLength = 120;

  /// Noise suite used for the persistent cryptographic identity. Stored with
  /// the public identity metadata so a future algorithm change is detectable;
  /// it is not a secret.
  static const String noiseKeyAlgorithm = 'noise-x25519-chachapoly-sha256';

  static const String defaultDeviceName = 'My BeChat Device';
  static const String defaultAvatarPath = '';

  static const bool demoDataEnabled = bool.fromEnvironment(
    'BECHAT_DEMO_DATA',
    defaultValue: false,
  );

  // Legacy installations used this shared ID before unique identities existed.
  static const String legacyPlaceholderDeviceId = 'local-device-001';
}
