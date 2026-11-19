import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:bechat/core/ble/peer_presence.dart';
import 'package:bechat/core/media/attachment_policy.dart';
import 'package:bechat/core/utils/error_formatter.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/features/chats/widgets/attachment_bubble.dart';
import 'package:bechat/providers/media_providers.dart';
import 'package:bechat/services/media/media_storage_service.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/core/widgets/avatar_widget.dart';
import 'package:bechat/core/utils/date_utils.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/message_providers.dart';
import 'package:bechat/providers/online_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/providers/settings_providers.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:bechat/services/online/transport_manager.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;

  const ChatScreen({super.key, required this.chatId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatListProvider.notifier).resetUnreadCount(widget.chatId);
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    if (utf8.encode(text).length > AppConstants.maxMessageLength) {
      _showError('Message is too long for a BLE transfer (4096 UTF-8 bytes).');
      return;
    }

    final identity = ref.read(identityProvider).valueOrNull;
    if (identity == null) {
      _showError('Local identity is unavailable. Messages cannot be saved.');
      return;
    }

    final chatAsync = ref.read(chatListProvider).valueOrNull;
    final chat = chatAsync?.where((c) => c.chatId == widget.chatId).firstOrNull;
    if (chat == null) return;

    final now = DateTime.now();
    final message = Message(
      messageId: 'msg-${_uuid.v4()}',
      chatId: widget.chatId,
      senderId: identity.deviceId,
      receiverId: chat.peerId,
      content: text,
      timestamp: now,
      status: MessageStatus.queued,
      transport: MessageTransport.pending,
      createdAt: now,
      updatedAt: now,
    );

    try {
      await ref
          .read(messageListProvider(widget.chatId).notifier)
          .sendMessage(message);
      _messageController.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      _showError('Failed to save message: $e');
      return;
    }

    try {
      await ref.read(chatListProvider.notifier).refreshChats();
    } catch (e) {
      _showError('Message saved, but the chat list could not be refreshed.');
    }

    unawaited(
      ref
          .read(transportManagerProvider.notifier)
          .onMessageQueued(chat.peerId)
          .catchError((Object _) {
            if (mounted) {
              _showError('Message is queued; delivery could not start.');
            }
          }),
    );
  }

  /// Attachment entry point: Gallery/Images, Videos, Documents.
  Future<void> _showAttachmentMenu() async {
    final kind = await showModalBottomSheet<AttachmentKind>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Gallery / Images'),
              subtitle: Text(
                'JPG, PNG, WebP up to '
                '${AttachmentPolicy.formatBytes(AppConstants.maxImageBytes)}',
              ),
              onTap: () => Navigator.pop(context, AttachmentKind.image),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Videos'),
              subtitle: Text(
                'MP4, MOV up to '
                '${AttachmentPolicy.formatBytes(AppConstants.maxVideoBytes)}',
              ),
              onTap: () => Navigator.pop(context, AttachmentKind.video),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Documents'),
              subtitle: Text(
                'PDF, TXT, DOCX and more up to '
                '${AttachmentPolicy.formatBytes(AppConstants.maxDocumentBytes)}',
              ),
              onTap: () => Navigator.pop(context, AttachmentKind.document),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (kind != null) await _pickAttachment(kind);
  }

  Future<void> _pickAttachment(AttachmentKind kind) async {
    final extensions = switch (kind) {
      AttachmentKind.image => ['jpg', 'jpeg', 'png', 'webp'],
      AttachmentKind.video => ['mp4', 'mov'],
      AttachmentKind.document => [
        'pdf',
        'txt',
        'csv',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'zip',
      ],
    };
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: false,
    );
    final picked = result?.files.singleOrNull;
    final path = picked?.path;
    if (picked == null || path == null) return;

    final file = File(path);
    final mimeType = AttachmentPolicy.resolveMimeType(
      fileName: picked.name,
    );
    final int size;
    try {
      size = await file.length();
    } catch (_) {
      _showError('That file could not be read.');
      return;
    }
    final error = AttachmentPolicy.validate(
      fileName: picked.name,
      mimeType: mimeType,
      size: size,
    );
    if (error != null) {
      _showError(error);
      return;
    }
    if (!mounted) return;

    final confirmed = await _showAttachmentPreview(
      file: file,
      fileName: picked.name,
      mimeType: mimeType!,
      size: size,
    );
    if (confirmed != true || !mounted) return;
    await _sendAttachment(
      file: file,
      fileName: picked.name,
      mimeType: mimeType,
      size: size,
    );
  }

  /// Preview with name, size and (for images) a thumbnail. Returns true when
  /// the user chooses Send.
  Future<bool?> _showAttachmentPreview({
    required File file,
    required String fileName,
    required String mimeType,
    required int size,
  }) {
    final isImage = AttachmentPolicy.kindForMime(mimeType) == AttachmentKind.image;
    return showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Send attachment',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              if (isImage)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    file,
                    height: 160,
                    fit: BoxFit.cover,
                    errorBuilder: (context, _, __) => const SizedBox.shrink(),
                  ),
                ),
              if (isImage) const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    isImage
                        ? Icons.image_outlined
                        : Icons.description_outlined,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                AttachmentPolicy.formatBytes(size),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Remove'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Uploads the bytes first, then saves the message. Doing it in this order is
  /// what keeps a media message from ever looking delivered before its file
  /// exists; a cancelled or failed upload leaves no message behind.
  Future<void> _sendAttachment({
    required File file,
    required String fileName,
    required String mimeType,
    required int size,
  }) async {
    final identity = ref.read(identityProvider).valueOrNull;
    final chat = ref
        .read(chatListProvider)
        .valueOrNull
        ?.where((c) => c.chatId == widget.chatId)
        .firstOrNull;
    if (identity == null || chat == null) {
      _showError('Attachment cannot be sent right now.');
      return;
    }

    // Uploads need Firebase Storage; BLE never carries media bytes, so an
    // offline attempt would only leave an orphan. Say so instead.
    if (ref.read(transportManagerProvider).mode != TransportMode.online) {
      _showError(
        'Attachments need an internet connection. Try again once BeChat is '
        'online.',
      );
      return;
    }

    final messageId = 'msg-${_uuid.v4()}';
    final storagePath = AttachmentPolicy.storagePath(
      uploaderDeviceId: identity.deviceId,
      messageId: messageId,
    );
    final progress = ValueNotifier<double>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    var cancelled = false;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Sending attachment'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: value <= 0 ? null : value,
                ),
                const SizedBox(height: 8),
                Text(
                  '${(value * 100).round()}% of '
                  '${AttachmentPolicy.formatBytes(size)}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                unawaited(
                  ref
                      .read(mediaSendServiceProvider)
                      .cancel(storagePath: storagePath),
                );
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );

    try {
      final attachment = await ref
          .read(mediaSendServiceProvider)
          .upload(
            file: file,
            fileName: fileName,
            mimeType: mimeType,
            size: size,
            messageId: messageId,
            senderDeviceId: identity.deviceId,
            onProgress: (value) => progress.value = value,
          );
      if (cancelled) {
        await ref
            .read(mediaSendServiceProvider)
            .cancel(storagePath: storagePath);
        return;
      }

      final now = DateTime.now();
      final message = Message(
        messageId: messageId,
        chatId: widget.chatId,
        senderId: identity.deviceId,
        receiverId: chat.peerId,
        content:
            '${AttachmentPolicy.label(attachment.kind)}: '
            '${attachment.fileName}',
        messageType: attachment.isImage ? MessageType.image : MessageType.file,
        timestamp: now,
        status: MessageStatus.queued,
        transport: MessageTransport.pending,
        createdAt: now,
        updatedAt: now,
        attachment: attachment,
      );
      await ref
          .read(messageListProvider(widget.chatId).notifier)
          .sendMessage(message);
      await ref.read(chatListProvider.notifier).refreshChats();
      unawaited(
        ref
            .read(transportManagerProvider.notifier)
            .onMessageQueued(chat.peerId),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } on MediaTransferCancelled {
      _showError('Attachment cancelled.');
    } catch (error) {
      _showError(describeErrorForUser(error));
    } finally {
      if (navigator.canPop()) navigator.pop();
      progress.dispose();
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildBleBanner(
    BuildContext context,
    BleRuntimeState bleState,
    String? peerId,
    TransportManagerState transport,
  ) {
    final theme = Theme.of(context);
    late final String message;
    late final Color background;
    late final Color foreground;

    if (AppConstants.demoDataEnabled) {
      message =
          'Demo mode: messages are saved locally and are not sent over BLE.';
      background = theme.colorScheme.secondaryContainer;
      foreground = theme.colorScheme.onSecondaryContainer;
    } else if (peerId != null && bleState.isPeerSecureReady(peerId)) {
      message =
          'Secure BLE link active with this peer. Messages are encrypted '
          'end-to-end while in transit over BLE.';
      background = theme.colorScheme.primaryContainer;
      foreground = theme.colorScheme.onPrimaryContainer;
    } else if (peerId != null && bleState.linkFor(peerId) != null) {
      message =
          'BLE link with this peer is still connecting or securing. '
          'Messages stay queued until it is confirmed.';
      background = theme.colorScheme.primaryContainer;
      foreground = theme.colorScheme.onPrimaryContainer;
    } else if (bleState.hasSecureLink || bleState.links.isNotEmpty) {
      message =
          'BLE is connected to another device. Messages here stay queued until '
          'you connect to this peer.';
      background = theme.colorScheme.tertiaryContainer;
      foreground = theme.colorScheme.onTertiaryContainer;
    } else {
      message =
          'No BLE link. Messages are saved locally and queued for later '
          'delivery.';
      background = theme.colorScheme.surfaceContainerHighest;
      foreground = theme.colorScheme.onSurfaceVariant;
    }

    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            switch (transport.mode) {
              TransportMode.online =>
                'Online (Firebase) — messages send over Firestore.',
              TransportMode.connecting => 'Connecting — checking Firebase…',
              TransportMode.bluetooth =>
                'Bluetooth — messages send over the BLE link.',
              TransportMode.offline =>
                'Offline / Pending — no transport available; messages stay '
                    'queued.',
            },
            style: TextStyle(
              color: foreground,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          // When online, the transport line already describes delivery — the BLE
          // detail below would contradict it (messages are not going over BLE).
          if (transport.mode != TransportMode.online)
            Text(message, style: TextStyle(color: foreground, fontSize: 12)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(messageListProvider(widget.chatId));
    final chatAsync = ref.watch(chatListProvider);
    final peersAsync = ref.watch(peerListProvider);
    final identityAsync = ref.watch(identityProvider);
    final localDeviceId = ref.watch(localDeviceIdProvider);
    final bleState = ref.watch(bleRuntimeProvider);

    final chat = chatAsync.valueOrNull
        ?.where((c) => c.chatId == widget.chatId)
        .firstOrNull;
    final peer = peersAsync.valueOrNull
        ?.where((p) => p.peerId == chat?.peerId)
        .firstOrNull;
    final peerName = peer?.displayName ?? chat?.title ?? 'Unknown';
    final resolvedPeer =
        peer ??
        (chat == null
            ? null
            : Peer(peerId: chat.peerId, displayName: peerName, deviceName: ''));
    final presence = resolvedPeer == null
        ? PeerPresence.offline
        : resolvePeerPresence(resolvedPeer, bleState.presenceContext);
    final isOnline = isPeerPresenceConnected(presence);
    final presenceLabel = presence == PeerPresence.offline
        ? 'Last seen ${AppDateUtils.formatRelativeTime(peer?.lastSeen)}'
        : peerPresenceLabel(presence);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Row(
          children: [
            PeerAvatar(name: peerName, radius: 18, isOnline: isOnline),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peerName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    presenceLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: isOnline
                          ? Colors.green
                          : presence == PeerPresence.blocked
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Tooltip(
            message: isOnline
                ? 'Direct BLE link active'
                : 'No direct BLE link for this peer',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(
                isOnline ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                color: isOnline
                    ? Colors.green
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (identityAsync.hasError)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                'Local identity is unavailable. Messages cannot be saved.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          _buildBleBanner(
            context,
            bleState,
            chat?.peerId,
            ref.watch(transportManagerProvider),
          ),
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.message_outlined,
                          size: 64,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No messages yet',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Send a message to start the conversation',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final msg = messages[index];
                    final isMe =
                        localDeviceId != null && msg.isSentBy(localDeviceId);
                    final showTimestamp =
                        index == 0 ||
                        messages[index].timestamp
                                .difference(messages[index - 1].timestamp)
                                .inMinutes >
                            5;

                    return Column(
                      children: [
                        if (showTimestamp)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              AppDateUtils.formatFullTimestamp(msg.timestamp),
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        MessageBubble(message: msg, isMe: isMe),
                      ],
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
            ),
          ),
          _buildInputBar(context),
        ],
      ),
    );
  }

  Widget _buildInputBar(BuildContext context) {
    final localDeviceId = ref.watch(localDeviceIdProvider);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Attach image, video or document',
              icon: const Icon(Icons.attach_file),
              onPressed: _showAttachmentMenu,
            ),
            Expanded(
              child: TextField(
                controller: _messageController,
                textCapitalization: TextCapitalization.sentences,
                maxLines: 4,
                minLines: 1,
                maxLength: AppConstants.maxMessageLength,
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 4),
            Container(
              decoration: BoxDecoration(
                color: localDeviceId == null
                    ? Theme.of(context).colorScheme.outline
                    : Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.send, color: Colors.white, size: 20),
                onPressed: localDeviceId == null ? null : _sendMessage,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMe;

  const MessageBubble({super.key, required this.message, required this.isMe});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (message.attachment != null)
              AttachmentBubble(
                attachment: message.attachment!,
                isMe: isMe,
              )
            else
              Text(
                message.content,
                style: TextStyle(
                  color: isMe
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurface,
                  fontSize: 15,
                ),
              ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  AppDateUtils.formatMessageTimestamp(message.timestamp),
                  style: TextStyle(
                    fontSize: 11,
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.7)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _statusIcon,
                    size: 14,
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.7)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData get _statusIcon => switch (message.status) {
    MessageStatus.queued => Icons.schedule,
    MessageStatus.sending => Icons.access_time,
    MessageStatus.sent => Icons.done,
    MessageStatus.delivered => Icons.done_all,
    MessageStatus.read => Icons.done_all,
    MessageStatus.failed => Icons.error_outline,
  };
}
