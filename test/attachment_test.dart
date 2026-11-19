/// Focused media-transfer tests: the pure attachment policy, attachment
/// (de)serialization, and the new `messages.attachment_json` column.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/core/media/attachment_policy.dart';
import 'package:bechat/data/models/attachment.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/repositories/message_repository.dart';

import 'helpers/test_database.dart';

Attachment _attachment({
  String messageId = 'msg-1',
  String senderDeviceId = 'device-a',
  String fileName = 'photo.png',
  String mimeType = 'image/png',
  int size = 1024,
}) => Attachment(
  attachmentId: messageId,
  messageId: messageId,
  fileName: fileName,
  mimeType: mimeType,
  fileSize: size,
  storagePath: AttachmentPolicy.storagePath(
    uploaderDeviceId: senderDeviceId,
    messageId: messageId,
  ),
  transferStatus: TransferStatus.completed,
);

void main() {
  group('AttachmentPolicy.resolveMimeType', () {
    test('accepts a supported reported type', () {
      expect(
        AttachmentPolicy.resolveMimeType(
          fileName: 'photo.bin',
          reportedMimeType: 'image/webp',
        ),
        'image/webp',
      );
    });

    test('falls back to the extension when the picker is vague', () {
      expect(
        AttachmentPolicy.resolveMimeType(
          fileName: 'Report.PDF',
          reportedMimeType: 'application/octet-stream',
        ),
        'application/pdf',
      );
      expect(
        AttachmentPolicy.resolveMimeType(fileName: 'clip.MOV'),
        'video/quicktime',
      );
    });

    test('unknown types stay null so they can be refused', () {
      expect(AttachmentPolicy.resolveMimeType(fileName: 'malware.exe'), isNull);
      expect(
        AttachmentPolicy.resolveMimeType(
          fileName: 'x.gif',
          reportedMimeType: 'image/gif',
        ),
        isNull,
      );
    });
  });

  group('AttachmentPolicy.validate', () {
    test('accepts each kind at its limit', () {
      expect(
        AttachmentPolicy.validate(
          fileName: 'a.jpg',
          mimeType: 'image/jpeg',
          size: AppConstants.maxImageBytes,
        ),
        isNull,
      );
      expect(
        AttachmentPolicy.validate(
          fileName: 'a.mp4',
          mimeType: 'video/mp4',
          size: AppConstants.maxVideoBytes,
        ),
        isNull,
      );
      expect(
        AttachmentPolicy.validate(
          fileName: 'a.pdf',
          mimeType: 'application/pdf',
          size: AppConstants.maxDocumentBytes,
        ),
        isNull,
      );
    });

    test('rejects one byte over, empty files and unknown types', () {
      expect(
        AttachmentPolicy.validate(
          fileName: 'a.jpg',
          mimeType: 'image/jpeg',
          size: AppConstants.maxImageBytes + 1,
        ),
        contains('too large'),
      );
      expect(
        AttachmentPolicy.validate(
          fileName: 'a.pdf',
          mimeType: 'application/pdf',
          size: AppConstants.maxDocumentBytes + 1,
        ),
        contains('too large'),
      );
      expect(
        AttachmentPolicy.validate(
          fileName: 'a.pdf',
          mimeType: 'application/pdf',
          size: 0,
        ),
        contains('empty'),
      );
      expect(
        AttachmentPolicy.validate(
          fileName: 'a.exe',
          mimeType: 'application/x-msdownload',
          size: 10,
        ),
        contains('not supported'),
      );
    });

    test('a video is not allowed the document limit', () {
      expect(
        AttachmentPolicy.validate(
          fileName: 'a.mp4',
          mimeType: 'video/mp4',
          size: AppConstants.maxDocumentBytes + 1,
        ),
        isNull,
        reason: 'the document limit is lower than the video limit',
      );
      expect(
        AttachmentPolicy.validate(
          fileName: 'a.pdf',
          mimeType: 'application/pdf',
          size: AppConstants.maxVideoBytes + 1,
        ),
        contains('too large'),
      );
    });
  });

  group('AttachmentPolicy paths and names', () {
    test('the storage path never contains the file name', () {
      final path = AttachmentPolicy.storagePath(
        uploaderDeviceId: 'device-a',
        messageId: 'msg-1',
      );
      expect(path, 'attachments/device-a/msg-1');
      expect(path, isNot(contains('photo')));
    });

    test('names cannot introduce traversal or control characters', () {
      expect(
        AttachmentPolicy.sanitizeFileName('../../etc/passwd'),
        'passwd',
      );
      expect(
        AttachmentPolicy.sanitizeFileName(r'C:\Users\me\secret.pdf'),
        'secret.pdf',
      );
      expect(AttachmentPolicy.sanitizeFileName('..'), 'attachment');
      expect(AttachmentPolicy.sanitizeFileName('a\u0000b.txt'), 'ab.txt');
      expect(
        AttachmentPolicy.sanitizeFileName('x' * 500).length,
        AppConstants.maxFileNameLength,
      );
    });

    test('path checks reject foreign or escaping locations', () {
      final path = AttachmentPolicy.storagePath(
        uploaderDeviceId: 'device-a',
        messageId: 'msg-1',
      );
      expect(
        AttachmentPolicy.isExpectedStoragePath(
          path: path,
          uploaderDeviceId: 'device-a',
          messageId: 'msg-1',
        ),
        isTrue,
      );
      expect(
        AttachmentPolicy.isExpectedStoragePath(
          path: path,
          uploaderDeviceId: 'device-b',
          messageId: 'msg-1',
        ),
        isFalse,
      );
      expect(AttachmentPolicy.isSafeStoragePath('../secrets'), isFalse);
      expect(AttachmentPolicy.isSafeStoragePath('/attachments/x'), isFalse);
      expect(AttachmentPolicy.isSafeStoragePath('other/x'), isFalse);
    });
  });

  group('attachment metadata round-trip', () {
    test('survives the JSON stored on the message', () {
      final original = _attachment();
      final restored = Attachment.tryFromJsonString(
        jsonEncode(original.toJson()),
      );
      expect(restored, isNotNull);
      expect(restored!.attachmentId, original.attachmentId);
      expect(restored.fileName, original.fileName);
      expect(restored.mimeType, original.mimeType);
      expect(restored.size, original.size);
      expect(restored.storagePath, original.storagePath);
      expect(restored.kind, AttachmentKind.image);
    });

    test('corrupt metadata yields null instead of throwing', () {
      expect(Attachment.tryFromJsonString('not json'), isNull);
      expect(Attachment.tryFromJsonString('{}'), isNull);
      expect(Attachment.tryFromJsonString(null), isNull);
      expect(
        Attachment.tryFromJsonString('{"attachmentId":"","messageId":"m"}'),
        isNull,
      );
    });

    test('Firestore metadata is only trusted when it matches the message', () {
      final valid = _attachment().toFirestoreFields();
      expect(
        Attachment.fromFirestore(
          messageId: 'msg-1',
          senderDeviceId: 'device-a',
          data: valid,
        ),
        isNotNull,
      );
      // Path pointing at another device.
      expect(
        Attachment.fromFirestore(
          messageId: 'msg-1',
          senderDeviceId: 'device-b',
          data: valid,
        ),
        isNull,
      );
      // Oversized for the declared kind.
      final huge = {
        ...valid,
        'size': AppConstants.maxImageBytes + 1,
      };
      expect(
        Attachment.fromFirestore(
          messageId: 'msg-1',
          senderDeviceId: 'device-a',
          data: huge,
        ),
        isNull,
      );
      // Unknown type.
      expect(
        Attachment.fromFirestore(
          messageId: 'msg-1',
          senderDeviceId: 'device-a',
          data: {...valid, 'mimeType': 'image/gif'},
        ),
        isNull,
      );
    });

    test('a message with an attachment survives Message.toMap/fromMap', () {
      final now = DateTime.utc(2026, 1, 1, 12);
      final message = Message(
        messageId: 'msg-1',
        chatId: 'chat-1',
        senderId: 'device-a',
        receiverId: 'device-b',
        content: 'Image: photo.png',
        messageType: MessageType.image,
        timestamp: now,
        createdAt: now,
        updatedAt: now,
        attachment: _attachment(),
      );
      final restored = Message.fromMap(message.toMap());
      expect(restored.hasAttachment, isTrue);
      expect(restored.attachment!.fileName, 'photo.png');
      expect(restored.attachment!.storagePath, 'attachments/device-a/msg-1');
      expect(restored.messageType, MessageType.image);
    });
  });

  group('message repository stores the attachment with its message', () {
    test('Persists and reads back attachment metadata', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      final repository = MessageRepository(database: () async => db);
      final now = DateTime.utc(2026, 1, 1, 12);

      await db.insert('peers', {
        'id': 'peer-1',
        'peer_id': 'device-b',
        'display_name': 'Bob',
        'device_name': 'Bob phone',
        'status': 'offline',
        'is_blocked': 0,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });
      await db.insert('chats', {
        'id': 'chat-row-1',
        'chat_id': 'chat-1',
        'peer_id': 'device-b',
        'unread_count': 0,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });

      await repository.insertMessageAndUpdateChat(
        Message(
          messageId: 'msg-1',
          chatId: 'chat-1',
          senderId: 'device-a',
          receiverId: 'device-b',
          content: 'Image: photo.png',
          messageType: MessageType.image,
          timestamp: now,
          createdAt: now,
          updatedAt: now,
          attachment: _attachment(),
        ),
      );

      final stored = await repository.getMessageByMessageId('msg-1');
      expect(stored, isNotNull);
      expect(stored!.attachment, isNotNull);
      expect(stored.attachment!.fileName, 'photo.png');
      expect(stored.attachment!.size, 1024);
      expect(stored.attachment!.storagePath, 'attachments/device-a/msg-1');

      // A queued attachment is still picked up by the online drain…
      final queued = await repository.getQueuedOutgoingMessages('device-a');
      expect(queued.map((m) => m.messageId), contains('msg-1'));
      // …and skipped by the BLE drain.
      final forBle = await repository.getQueuedOutgoingMessages(
        'device-a',
        excludeAttachments: true,
      );
      expect(forBle.map((m) => m.messageId), isNot(contains('msg-1')));
    });
  });
}
