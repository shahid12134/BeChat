import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/features/chats/screens/chat_list_screen.dart';
import 'package:bechat/features/peers/screens/peer_discovery_screen.dart';
import 'package:bechat/features/settings/screens/settings_screen.dart';
import 'package:bechat/providers/chat_providers.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final screens = [
      ChatListScreen(onDiscoverPeers: () => setState(() => _currentIndex = 1)),
      const PeerDiscoveryScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
          if (index == 0) {
            ref.read(chatListProvider.notifier).refreshChats();
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_outlined),
            selectedIcon: Icon(Icons.chat),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.bluetooth_searching_outlined),
            selectedIcon: Icon(Icons.bluetooth_searching),
            label: 'Nearby',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
