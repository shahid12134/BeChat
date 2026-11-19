import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/core/media/attachment_policy.dart';
import 'package:bechat/services/online/firebase_bootstrap.dart';

/// The user cancelled a transfer; distinct from a failure so the UI can stay
/// quiet about it.
class MediaTransferCancelled implements Exception {
  const MediaTransferCancelled();
  @override
  String toString() => 'Transfer cancelled';
}

/// Firebase Storage access for attachment bytes.
///
/// Uploads are the sender's own; downloads go through an authenticated request
/// so the Storage rules decide who may read the object (the uploader or an
/// accepted contact). No public or permanent download URL is used.
class MediaStorageService {
  MediaStorageService({FirebaseStorage? storage, FirebaseAuth? auth})
    : _storageOverride = storage,
      _authOverride = auth;

  final FirebaseStorage? _storageOverride;
  final FirebaseAuth? _authOverride;

  UploadTask? _activeUpload;
  bool _cancelled = false;

  FirebaseStorage get _storage => _storageOverride ?? FirebaseStorage.instance;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  /// Uploads [file] to [storagePath], reporting 0..1 progress.
  ///
  /// The path must live under the attachment prefix (never derived from the
  /// file name), and the declared size must match the per-kind limits.
  Future<void> upload({
    required File file,
    required String storagePath,
    required String contentType,
    required int expectedBytes,
    void Function(double progress)? onProgress,
  }) async {
    await FirebaseBootstrap.ensureInitialized();
    if (_auth.currentUser == null) {
      throw StateError('Not signed in to Firebase');
    }
    if (!AttachmentPolicy.isSafeStoragePath(storagePath)) {
      throw ArgumentError('Refusing to upload outside the attachment prefix');
    }
    if (expectedBytes <= 0 || expectedBytes > AppConstants.maxAttachmentBytes) {
      throw ArgumentError('Attachment size is outside the allowed range');
    }

    _cancelled = false;
    final task = _storage
        .ref(storagePath)
        .putFile(file, SettableMetadata(contentType: contentType));
    _activeUpload = task;

    final completer = Completer<void>();
    late final StreamSubscription<TaskSnapshot> subscription;
    subscription = task.snapshotEvents.listen(
      (snapshot) {
        if (snapshot.totalBytes > 0) {
          onProgress?.call(
            (snapshot.bytesTransferred / snapshot.totalBytes).clamp(0.0, 1.0),
          );
        }
        if (snapshot.state == TaskState.success && !completer.isCompleted) {
          onProgress?.call(1);
          completer.complete();
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
      cancelOnError: true,
    );

    try {
      await completer.future;
    } catch (error) {
      if (_cancelled) throw const MediaTransferCancelled();
      rethrow;
    } finally {
      await subscription.cancel();
      if (identical(_activeUpload, task)) _activeUpload = null;
    }
  }

  /// Cancels the upload in flight, if any. Partial objects are removed by the
  /// caller (see [delete]) so an abandoned transfer leaves nothing behind.
  Future<void> cancelUpload() async {
    _cancelled = true;
    final task = _activeUpload;
    _activeUpload = null;
    try {
      await task?.cancel();
    } catch (_) {
      // The task may already be finished; nothing to cancel.
    }
  }

  /// Removes an attachment object (abandoned upload or user cleanup).
  Future<void> delete(String storagePath) async {
    if (!AttachmentPolicy.isSafeStoragePath(storagePath)) return;
    try {
      await _storage.ref(storagePath).delete();
    } on FirebaseException catch (error) {
      if (error.code != 'object-not-found') rethrow;
    }
  }

  /// Downloads [storagePath] to [target], reporting byte progress.
  ///
  /// Uses the authenticated Storage REST endpoint (so progress is real) and
  /// falls back to the SDK when the bucket/endpoint is unavailable. Either way
  /// the size is verified, so a truncated download is a failure rather than a
  /// corrupt file.
  Future<void> download({
    required String storagePath,
    required int expectedBytes,
    required File target,
    void Function(double progress)? onProgress,
  }) async {
    await FirebaseBootstrap.ensureInitialized();
    final user = _auth.currentUser;
    if (user == null) throw StateError('Not signed in to Firebase');
    if (!AttachmentPolicy.isSafeStoragePath(storagePath)) {
      throw ArgumentError('Refusing to download outside the attachment prefix');
    }
    if (expectedBytes <= 0 || expectedBytes > AppConstants.maxAttachmentBytes) {
      throw ArgumentError('Attachment size is outside the allowed range');
    }

    final bucket = _storage.app.options.storageBucket;
    if (bucket == null || bucket.isEmpty) {
      await _downloadViaSdk(storagePath, expectedBytes, target, onProgress);
      return;
    }

    final token = await user.getIdToken();
    final client = HttpClient();
    final sink = target.openWrite();
    var received = 0;
    var completed = false;
    try {
      final uri = Uri.parse(
        'https://firebasestorage.googleapis.com/v0/b/$bucket/o/'
        '${Uri.encodeComponent(storagePath)}?alt=media',
      );
      final request = await client.getUrl(uri);
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
          'Download was refused (HTTP ${response.statusCode}).',
        );
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : expectedBytes;
      await for (final chunk in response) {
        received += chunk.length;
        if (received > expectedBytes) {
          throw StateError('Download exceeded the expected size.');
        }
        sink.add(chunk);
        onProgress?.call((received / total).clamp(0.0, 1.0));
      }
      await sink.close();
      completed = true;
      if (received != expectedBytes) {
        throw StateError('Download size did not match.');
      }
      onProgress?.call(1);
    } finally {
      client.close(force: true);
      if (!completed) {
        try {
          await sink.close();
        } catch (_) {
          // The sink may already be closed by the failure path.
        }
        try {
          if (await target.exists()) await target.delete();
        } catch (_) {
          // Best-effort cleanup of a partial file.
        }
      }
    }
  }

  Future<void> _downloadViaSdk(
    String storagePath,
    int expectedBytes,
    File target,
    void Function(double progress)? onProgress,
  ) async {
    onProgress?.call(0);
    final bytes = await _storage.ref(storagePath).getData(expectedBytes);
    if (bytes == null || bytes.lengthInBytes != expectedBytes) {
      throw StateError('Download size did not match.');
    }
    await target.writeAsBytes(bytes, flush: true);
    onProgress?.call(1);
  }
}
