import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/repositories/message_repository.dart';

final messageRepositoryProvider = Provider<MessageRepository>((ref) {
  return MessageRepository();
});

final messageListProvider =
    StateNotifierProvider.family<MessageListNotifier, AsyncValue<List<Message>>, String>((ref, chatId) {
  return MessageListNotifier(ref.read(messageRepositoryProvider), chatId);
});

class MessageListNotifier extends StateNotifier<AsyncValue<List<Message>>> {
  final MessageRepository _repository;
  final String chatId;

  MessageListNotifier(this._repository, this.chatId) : super(const AsyncValue.loading()) {
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
    await _repository.insertMessage(message);
    await refreshMessages();
  }
}
