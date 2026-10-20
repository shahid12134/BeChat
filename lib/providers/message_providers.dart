import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/repositories/message_repository.dart';

final messageRepositoryProvider = Provider<MessageRepository>((ref) {
  return MessageRepository();
});

final messageListProvider =
    StateNotifierProvider.family<
      MessageListNotifier,
      AsyncValue<List<Message>>,
      String
    >((ref, chatId) {
      return MessageListNotifier(ref.read(messageRepositoryProvider), chatId);
    });

class MessageListNotifier extends StateNotifier<AsyncValue<List<Message>>> {
  final MessageRepository _repository;
  final String chatId;

  MessageListNotifier(this._repository, this.chatId)
    : super(const AsyncValue.loading()) {
    loadMessages();
  }

  Future<void> loadMessages() async {
    state = const AsyncValue.loading();
    try {
      final messages = await _repository.getMessagesByChatId(chatId);
      state = AsyncValue.data(messages);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refreshMessages() async {
    try {
      final messages = await _repository.getMessagesByChatId(chatId);
      state = AsyncValue.data(messages);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> sendMessage(Message message) async {
    final inserted = await _repository.insertMessageAndUpdateChat(message);
    if (!inserted) {
      throw StateError('Message ${message.messageId} already exists');
    }

    final messages = [...?state.valueOrNull, message]
      ..sort((a, b) {
        final byTimestamp = a.timestamp.compareTo(b.timestamp);
        return byTimestamp != 0
            ? byTimestamp
            : a.messageId.compareTo(b.messageId);
      });
    if (messages.length > AppConstants.defaultPageSize) {
      messages.removeRange(0, messages.length - AppConstants.defaultPageSize);
    }
    state = AsyncValue.data(messages);
  }
}
