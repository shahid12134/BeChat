import 'dart:convert';

import 'package:bechat/core/media/attachment_policy.dart';

enum TransferStatus { pending, transferring, completed, failed }

/// Attachment metadata for a message.
///
/// Bytes never live here: online transfers keep them in Firebase Storage and
/// reference them by [storagePath]; [localPath] is only where this device
/// cached a copy for viewing. The model is serialized into the message row
/// (`messages.attachment_json`), so an attachment always travels with its
/// message and the existing queue/transport code keeps working unchanged.
class Attachment {
  const Attachment({
    this.id,
    required this.attachmentId,
    required this.messageId,
    required this.fileName,
    this.filePath = '',
    this.mimeType,
    this.fileSize,
    this.transferStatus = TransferStatus.pending,
    this.createdAt,
    this.storagePath = '',
    this.localPath,
    this.uploadedAt,
  });

  final String? id;
  final String attachmentId;
  final String messageId;
  final String fileName;

  /// Legacy column value, kept for schema compatibility. New code uses
  /// [localPath] for a cached copy and [storagePath] for the remote object.
  final String filePath;

  final String? mimeType;
  final int? fileSize;
  final TransferStatus transferStatus;
  final DateTime? createdAt;

  /// `attachments/{uploaderUid}/{messageId}` — built by the uploader, checked
  /// against the sender by both Storage rules and Firestore rules.
  final String storagePath;

  /// Downloaded copy on this device, if any.
  final String? localPath;

  final DateTime? uploadedAt;

  AttachmentKind get kind =>
      AttachmentPolicy.kindForMime(mimeType) ?? AttachmentKind.document;

  int get size => fileSize ?? 0;

  String get sizeLabel => AttachmentPolicy.formatBytes(size);

  bool get isImage => kind == AttachmentKind.image;

  bool get isVideo => kind == AttachmentKind.video;

  bool get isComplete => transferStatus == TransferStatus.completed;

  Attachment copyWith({
    String? id,
    String? attachmentId,
    String? messageId,
    String? fileName,
    String? filePath,
    String? mimeType,
    int? fileSize,
    TransferStatus? transferStatus,
    DateTime? createdAt,
    String? storagePath,
    String? localPath,
    DateTime? uploadedAt,
  }) {
    return Attachment(
      id: id ?? this.id,
      attachmentId: attachmentId ?? this.attachmentId,
      messageId: messageId ?? this.messageId,
      fileName: fileName ?? this.fileName,
      filePath: filePath ?? this.filePath,
      mimeType: mimeType ?? this.mimeType,
      fileSize: fileSize ?? this.fileSize,
      transferStatus: transferStatus ?? this.transferStatus,
      createdAt: createdAt ?? this.createdAt,
      storagePath: storagePath ?? this.storagePath,
      localPath: localPath ?? this.localPath,
      uploadedAt: uploadedAt ?? this.uploadedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'attachment_id': attachmentId,
      'message_id': messageId,
      'file_name': fileName,
      'file_path': filePath,
      'mime_type': mimeType,
      'file_size': fileSize,
      'transfer_status': transferStatus.name,
      'created_at': createdAt?.toIso8601String(),
    };
  }

  factory Attachment.fromMap(Map<String, dynamic> map) {
    return Attachment(
      id: map['id'] as String?,
      attachmentId: map['attachment_id'] as String,
      messageId: map['message_id'] as String,
      fileName: map['file_name'] as String,
      filePath: map['file_path'] as String? ?? '',
      mimeType: map['mime_type'] as String?,
      fileSize: map['file_size'] as int?,
      transferStatus: TransferStatus.values.firstWhere(
        (e) => e.name == map['transfer_status'],
        orElse: () => TransferStatus.pending,
      ),
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
    );
  }

  /// JSON form stored in `messages.attachment_json`.
  Map<String, dynamic> toJson() => {
    'attachmentId': attachmentId,
    'messageId': messageId,
    'fileName': fileName,
    'mimeType': mimeType,
    'size': fileSize,
    'storagePath': storagePath,
    'localPath': localPath,
    'status': transferStatus.name,
    'uploadedAt': uploadedAt?.toUtc().toIso8601String(),
  };

  /// Tolerant decode: a corrupt or hostile value must never make a message
  /// unreadable, so anything unusable yields null instead of throwing.
  static Attachment? tryFromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static Attachment? fromJson(Map<String, dynamic> json) {
    final attachmentId = json['attachmentId'];
    final messageId = json['messageId'];
    final fileName = json['fileName'];
    if (attachmentId is! String ||
        messageId is! String ||
        fileName is! String ||
        attachmentId.isEmpty ||
        messageId.isEmpty ||
        fileName.isEmpty) {
      return null;
    }
    final size = json['size'];
    final uploadedAt = json['uploadedAt'];
    return Attachment(
      attachmentId: attachmentId,
      messageId: messageId,
      fileName: AttachmentPolicy.sanitizeFileName(fileName),
      mimeType: json['mimeType'] as String?,
      fileSize: size is int ? size : null,
      storagePath: json['storagePath'] as String? ?? '',
      localPath: json['localPath'] as String?,
      transferStatus: TransferStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => TransferStatus.pending,
      ),
      uploadedAt: uploadedAt is String ? DateTime.tryParse(uploadedAt) : null,
    );
  }

  /// The metadata written to the Firestore message document.
  Map<String, dynamic> toFirestoreFields() => {
    'attachmentId': attachmentId,
    'fileName': fileName,
    'mimeType': mimeType,
    'size': fileSize ?? 0,
    'storagePath': storagePath,
    'kind': kind.name,
  };

  /// Rebuilds attachment metadata from a Firestore message document, after
  /// validating it against the message it arrived on. Returns null for
  /// anything inconsistent, so a forged or broken attachment is simply
  /// ignored rather than trusted.
  static Attachment? fromFirestore({
    required String messageId,
    required String senderDeviceId,
    required Object? data,
  }) {
    if (data is! Map) return null;
    final attachmentId = data['attachmentId'];
    final fileName = data['fileName'];
    final mimeType = data['mimeType'];
    final size = data['size'];
    final storagePath = data['storagePath'];
    if (attachmentId is! String ||
        fileName is! String ||
        mimeType is! String ||
        size is! int ||
        storagePath is! String) {
      return null;
    }
    final resolvedMime = AttachmentPolicy.resolveMimeType(
      fileName: fileName,
      reportedMimeType: mimeType,
    );
    if (resolvedMime != mimeType.toLowerCase()) return null;
    if (AttachmentPolicy.validate(
          fileName: fileName,
          mimeType: mimeType,
          size: size,
        ) !=
        null) {
      return null;
    }
    if (!AttachmentPolicy.isExpectedStoragePath(
      path: storagePath,
      uploaderDeviceId: senderDeviceId,
      messageId: messageId,
    )) {
      return null;
    }
    return Attachment(
      attachmentId: attachmentId,
      messageId: messageId,
      fileName: AttachmentPolicy.sanitizeFileName(fileName),
      mimeType: mimeType,
      fileSize: size,
      storagePath: storagePath,
      transferStatus: TransferStatus.pending,
    );
  }
}
