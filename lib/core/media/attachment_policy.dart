import 'package:bechat/core/constants/app_constants.dart';

/// What an attachment is, decided from its MIME type. Media limits, the
/// Storage path and the Firestore metadata validation all key off this.
enum AttachmentKind { image, video, document }

/// Single source of truth for "may this file be attached, and where does it
/// live?". Pure Dart: no plugins, no Firebase, so it is unit-testable and is
/// used by both the picker (before upload) and the receiver (before trusting
/// metadata supplied by another client).
class AttachmentPolicy {
  const AttachmentPolicy._();

  /// Extension → MIME fallback. Pickers on Android frequently report
  /// `application/octet-stream` (or nothing) for a perfectly ordinary file, so
  /// the extension decides in that case. Anything not listed here is refused.
  static const Map<String, String> _mimeByExtension = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'csv': 'text/csv',
    'doc': 'application/msword',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx':
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'zip': 'application/zip',
  };

  /// Every MIME type the app accepts. Mirrors the Firestore/Storage rules.
  static const Set<String> allowedMimeTypes = {
    ...AppConstants.imageMimeTypes,
    ...AppConstants.videoMimeTypes,
    ...AppConstants.documentMimeTypes,
  };

  static String? extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return null;
    final extension = fileName.substring(dot + 1).toLowerCase();
    if (extension.isEmpty || extension.length > 10) return null;
    return extension;
  }

  /// The MIME type to trust for [fileName]: the reported one when it is
  /// allowed, otherwise the one implied by a known extension.
  static String? resolveMimeType({
    required String fileName,
    String? reportedMimeType,
  }) {
    final reported = reportedMimeType?.toLowerCase().trim();
    if (reported != null && allowedMimeTypes.contains(reported)) {
      return reported;
    }
    final extension = extensionOf(fileName);
    if (extension == null) return null;
    return _mimeByExtension[extension];
  }

  static AttachmentKind? kindForMime(String? mimeType) {
    if (mimeType == null) return null;
    final mime = mimeType.toLowerCase();
    if (mime.startsWith('image/')) return AttachmentKind.image;
    if (mime.startsWith('video/')) return AttachmentKind.video;
    if (allowedMimeTypes.contains(mime)) return AttachmentKind.document;
    return null;
  }

  static int maxBytesFor(AttachmentKind kind) => switch (kind) {
    AttachmentKind.image => AppConstants.maxImageBytes,
    AttachmentKind.video => AppConstants.maxVideoBytes,
    AttachmentKind.document => AppConstants.maxDocumentBytes,
  };

  /// Null when the file may be sent, otherwise a user-facing reason.
  /// [mimeType] must already be resolved (see [resolveMimeType]); an unknown
  /// type is refused rather than guessed.
  static String? validate({
    required String fileName,
    required String? mimeType,
    required int size,
  }) {
    if (fileName.trim().isEmpty) return 'That file has no name.';
    if (size <= 0) return 'That file is empty.';
    final mime = mimeType?.toLowerCase();
    if (mime == null || !allowedMimeTypes.contains(mime)) {
      return 'That file type is not supported yet.';
    }
    final kind = kindForMime(mime);
    if (kind == null) return 'That file type is not supported yet.';
    final limit = maxBytesFor(kind);
    if (size > limit) {
      return 'That ${label(kind).toLowerCase()} is too large. '
          'The limit is ${formatBytes(limit)}.';
    }
    return null;
  }

  /// A display-safe name: no directories, no traversal, no control characters,
  /// bounded length. It is never used to build a path.
  static String sanitizeFileName(String name) {
    final base = name
        .replaceAll('\\', '/')
        .split('/')
        .lastWhere((part) => part.isNotEmpty, orElse: () => '')
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
        .trim();
    if (base.isEmpty || base == '.' || base == '..') return 'attachment';
    if (base.length <= AppConstants.maxFileNameLength) return base;
    return base.substring(0, AppConstants.maxFileNameLength);
  }

  /// Storage location derived from the uploader's device id and the message
  /// id — never from the file name, so a hostile name cannot influence the
  /// path. The device id (not the Firebase UID) is used because it is what the
  /// message document and the recipient already know; Storage rules resolve
  /// its owner through `deviceRegistry`.
  static String storagePath({
    required String uploaderDeviceId,
    required String messageId,
  }) => '${AppConstants.mediaStoragePrefix}/$uploaderDeviceId/$messageId';

  /// True when [path] is exactly the path this device may write for
  /// [messageId]. Used to reject metadata that points elsewhere.
  static bool isExpectedStoragePath({
    required String path,
    required String uploaderDeviceId,
    required String messageId,
  }) =>
      uploaderDeviceId.isNotEmpty &&
      messageId.isNotEmpty &&
      path ==
          storagePath(
            uploaderDeviceId: uploaderDeviceId,
            messageId: messageId,
          );

  /// Cheap rejection of anything that could escape the attachment prefix.
  static bool isSafeStoragePath(String path) {
    if (path.isEmpty || path.length > 512) return false;
    if (path.startsWith('/') || path.contains('..') || path.contains('\\')) {
      return false;
    }
    return path.startsWith('${AppConstants.mediaStoragePrefix}/');
  }

  static String label(AttachmentKind kind) => switch (kind) {
    AttachmentKind.image => 'Image',
    AttachmentKind.video => 'Video',
    AttachmentKind.document => 'Document',
  };

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
