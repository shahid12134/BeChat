import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:bechat/core/widgets/ble_availability_button.dart';
import 'package:bechat/features/chats/widgets/chat_list_item.dart';
import 'package:bechat/core/widgets/empty_state.dart';
import 'package:bechat/providers/chat_providers.dart';

class ChatListScreen extends ConsumerStatefulWidget {
  final VoidCallback? onDiscoverPeers;

  const ChatListScreen({super.key, this.onDiscoverPeers});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  final _searchController = TextEditingController();
  bool _isSearching = false;
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chatListAsync = ref.watch(chatListProvider);

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search conversations...',
                  border: InputBorder.none,
                  fillColor: Colors.transparent,
                  filled: false,
                ),
                onChanged: (value) => setState(() => _searchQuery = value),
              )
            : const Text('BeChat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt),
            tooltip: 'Add people',
            onPressed: () => context.push('/people'),
          ),
          const BleAvailabilityButton(),
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchController.clear();
                  _searchQuery = '';
                }
              });
            },
          ),
        ],
      ),
      body: chatListAsync.when(
        data: (chats) {
          final filtered = _searchQuery.isEmpty
              ? chats
              : chats
                    .where(
                      (c) =>
                          (c.title ?? '').toLowerCase().contains(
                            _searchQuery.toLowerCase(),
                          ) ||
                          (c.lastMessage ?? '').toLowerCase().contains(
                            _searchQuery.toLowerCase(),
                          ),
                    )
                    .toList();

          if (filtered.isEmpty) {
            if (_searchQuery.isNotEmpty) {
              return const EmptyState(type: EmptyStateType.noSearchResults);
            }
            return EmptyState(
              type: EmptyStateType.noChats,
              onAction: widget.onDiscoverPeers,
            );
          }

          return RefreshIndicator(
            onRefresh: () => ref.read(chatListProvider.notifier).refreshChats(),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 80),
              itemBuilder: (context, index) {
                return ChatListItem(chat: filtered[index]);
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
