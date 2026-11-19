import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import 'package:bechat/core/media/attachment_policy.dart';
import 'package:bechat/data/models/attachment.dart';
import 'package:bechat/providers/media_providers.dart';

/// Attachment inside a chat bubble.
///
/// Sender: the file is already on this device, so images render immediately.
/// Recipient: tapping downloads the bytes (with progress) and then opens them —
/// an image fullscreen, a video/document in the platform viewer.
class AttachmentBubble extends ConsumerWidget {
  const AttachmentBubble({
    super.key,
    required this.attachment,
    required this.isMe,
  });

  final Attachment attachment;
  final bool isMe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mediaDownloadProvider(attachment.storagePath));
    final foreground = isMe
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;

    if (attachment.isImage && state.localPath != null) {
      return GestureDetector(
        onTap: () => _openFullscreen(context, state.localPath!),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(state.localPath!),
            height: 200,
            fit: BoxFit.cover,
            errorBuilder: (context, _, __) =>
                _tile(context, ref, state, foreground),
          ),
        ),
      );
    }

    return _tile(context, ref, state, foreground);
  }

  Widget _tile(
    BuildContext context,
    WidgetRef ref,
    MediaDownloadState state,
    Color foreground,
  ) {
    final icon = switch (attachment.kind) {
      AttachmentKind.image => Icons.image_outlined,
      AttachmentKind.video => Icons.play_circle_outline,
      AttachmentKind.document => Icons.description_outlined,
    };
    final subtitle = state.downloading
        ? 'Downloading ${(state.progress * 100).round()}%'
        : '${AttachmentPolicy.label(attachment.kind)} · ${attachment.sizeLabel}';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _downloadAndOpen(context, ref, state),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: foreground.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foreground, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attachment.fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: foreground.withValues(alpha: 0.7),
                      fontSize: 11,
                    ),
                  ),
                  if (state.downloading) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: state.progress <= 0 ? null : state.progress,
                      minHeight: 3,
                    ),
                  ],
                  if (state.error != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      state.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              state.downloading
                  ? Icons.downloading
                  : state.localPath != null
                  ? Icons.open_in_new
                  : Icons.download,
              size: 18,
              color: foreground.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadAndOpen(
    BuildContext context,
    WidgetRef ref,
    MediaDownloadState state,
  ) async {
    final path =
        state.localPath ??
        await ref
            .read(mediaDownloadProvider(attachment.storagePath).notifier)
            .download(attachment);
    if (path == null || !context.mounted) return;

    if (attachment.isImage) {
      await _openFullscreen(context, path);
      return;
    }
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No app on this device can open that file type.'),
        ),
      );
    }
  }

  Future<void> _openFullscreen(BuildContext context, String path) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (context, _, __) => GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            color: Colors.black87,
            alignment: Alignment.center,
            child: InteractiveViewer(
              child: Image.file(File(path), fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }
}
