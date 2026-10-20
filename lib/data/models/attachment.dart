enum TransferStatus { pending, transferring, completed, failed }

class Attachment {
  final String? id;
  final String attachmentId;
  final String messageId;
  final String fileName;
  final String filePath;
  final String? mimeType;
  final int? fileSize;
  final TransferStatus transferStatus;
  final DateTime? createdAt;

  const Attachment({
    this.id,
    required this.attachmentId,
    required this.messageId,
    required this.fileName,
    required this.filePath,
    this.mimeType,
    this.fileSize,
    this.transferStatus = TransferStatus.pending,
    this.createdAt,
  });

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
      filePath: map['file_path'] as String,
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
}
