import 'package:go_router/go_router.dart';
import 'package:bechat/features/home/screens/home_screen.dart';
import 'package:bechat/features/chats/screens/chat_screen.dart';
import 'package:bechat/features/people/screens/add_people_screen.dart';
import 'package:bechat/features/peers/screens/peer_details_screen.dart';

final goRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/chat/:chatId',
      builder: (context, state) {
        final chatId = state.pathParameters['chatId']!;
        return ChatScreen(chatId: chatId);
      },
    ),
    GoRoute(
      path: '/peer/:peerId',
      builder: (context, state) {
        final peerId = state.pathParameters['peerId']!;
        return PeerDetailsScreen(peerId: peerId);
      },
    ),
    GoRoute(
      path: '/people',
      builder: (context, state) => const AddPeopleScreen(),
    ),
  ],
);
