import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:bechat/core/media/attachment_policy.dart';
import 'package:bechat/data/models/attachment.dart';
import 'package:bechat/services/media/media_storage_service.dart';

final mediaStorageServiceProvider = Provider<MediaStorageService>((ref) {
  return MediaStorageService();
});

/// Uploads one picked file and returns the completed attachment metadata.
///
/// One upload at a time per call site — no queue, no timer, and the message is
/// only created after the bytes are stored, so a message can never appear
/// "sent" with its attachment missing.
class MediaSendService {
  MediaSendService({required this.storage});

  final MediaStorageService storage;

  Future<Attachment> upload({
    required File file,
    required String fileName,
    required String mimeType,
    required int size,
    required String messageId,
    required String senderDeviceId,
    void Function(double progress)? onProgress,
  }) async {
    final policyError = AttachmentPolicy.validate(
      fileName: fileName,
      mimeType: mimeType,
      size: size,
    );
    if (policyError != null) throw StateError(policyError);

    final storagePath = AttachmentPolicy.storagePath(
      uploaderDeviceId: senderDeviceId,
      messageId: messageId,
    );
    await storage.upload(
      file: file,
      storagePath: storagePath,
      contentType: mimeType,
      expectedBytes: size,
      onProgress: onProgress,
    );
    return Attachment(
      attachmentId: messageId,
      messageId: messageId,
      fileName: AttachmentPolicy.sanitizeFileName(fileName),
      mimeType: mimeType,
      fileSize: size,
      storagePath: storagePath,
      localPath: file.path,
      transferStatus: TransferStatus.completed,
      uploadedAt: DateTime.now(),
    );
  }

  /// Cancels the active upload and removes what it may have written.
  Future<void> cancel({String? storagePath}) async {
    await storage.cancelUpload();
    if (storagePath != null) {
      try {
        await storage.delete(storagePath);
      } catch (_) {
        // The object may not exist yet; cleanup is best effort.
      }
    }
  }
}

final mediaSendServiceProvider = Provider<MediaSendService>((ref) {
  return MediaSendService(storage: ref.read(mediaStorageServiceProvider));
});

/// Download state for one attachment, keyed by its Storage path.
class MediaDownloadState {
  const MediaDownloadState({
    this.downloading = false,
    this.progress = 0,
    this.localPath,
    this.error,
  });

  final bool downloading;
  final double progress;
  final String? localPath;
  final String? error;

  bool get isReady => localPath != null;

  MediaDownloadState copyWith({
    bool? downloading,
    double? progress,
    String? localPath,
    String? error,
    bool clearError = false,
  }) => MediaDownloadState(
    downloading: downloading ?? this.downloading,
    progress: progress ?? this.progress,
    localPath: localPath ?? this.localPath,
    error: clearError ? null : (error ?? this.error),
  );
}

final mediaDownloadProvider =
    StateNotifierProvider.family<
      MediaDownloadNotifier,
      MediaDownloadState,
      String
    >((ref, storagePath) {
      return MediaDownloadNotifier(
        ref.read(mediaStorageServiceProvider),
        storagePath,
      );
    });

class MediaDownloadNotifier extends StateNotifier<MediaDownloadState> {
  MediaDownloadNotifier(this._storage, this.storagePath)
    : super(const MediaDownloadState());

  final MediaStorageService _storage;
  final String storagePath;

  /// Downloads once and caches the file in the temporary directory. Returns
  /// the local path, or null when the download failed (state carries the
  /// message the UI shows).
  Future<String?> download(Attachment attachment) async {
    final cached = state.localPath;
    if (cached != null) return cached;
    if (state.downloading) return null;

    state = state.copyWith(
      downloading: true,
      progress: 0,
      clearError: true,
    );
    try {
      final directory = await getTemporaryDirectory();
      final name =
          'bechat_${attachment.attachmentId}_'
          '${AttachmentPolicy.sanitizeFileName(attachment.fileName)}';
      final file = File(p.join(directory.path, name));

      // A previous attempt may have finished; reuse an exact-size copy.
      if (await file.exists() && await file.length() == attachment.size) {
        state = MediaDownloadState(localPath: file.path);
        return file.path;
      }

      await _storage.download(
        storagePath: storagePath,
        expectedBytes: attachment.size,
        target: file,
        onProgress: (value) {
          if (mounted) state = state.copyWith(progress: value);
        },
      );
      state = MediaDownloadState(localPath: file.path, progress: 1);
      return file.path;
    } catch (_) {
      if (mounted) {
        state = state.copyWith(
          downloading: false,
          error: 'Could not download this attachment.',
        );
      }
      return null;
    }
  }
}
