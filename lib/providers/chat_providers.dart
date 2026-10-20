import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/data/models/chat.dart';
import 'package:bechat/data/repositories/chat_repository.dart';

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository();
});

final chatListProvider = StateNotifierProvider<ChatListNotifier, AsyncValue<List<Chat>>>((ref) {
  return ChatListNotifier(ref.read(chatRepositoryProvider));
});

class ChatListNotifier extends StateNotifier<AsyncValue<List<Chat>>> {
  final ChatRepository _repository;

  ChatListNotifier(this._repository) : super(const AsyncValue.loading()) {
    loadChats();
  }

  Future<void> loadChats() async {
    state = const AsyncValue.loading();
    try {
      final chats = await _repository.getAllChats();
      state = AsyncValue.data(chats);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refreshChats() async {
    try {
      final chats = await _repository.getAllChats();
      state = AsyncValue.data(chats);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> updateLastMessage(String chatId, String message, DateTime time) async {
    await _repository.updateLastMessage(chatId, message, time);
    await refreshChats();
  }

  Future<void> resetUnreadCount(String chatId) async {
    await _repository.resetUnreadCount(chatId);
    await refreshChats();
  }
}
