import 'package:bechat/app/theme/app_theme.dart';
import 'package:bechat/data/models/chat.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/chat_repository.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/data/repositories/message_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/features/chats/screens/chat_screen.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/message_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/providers/settings_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const peer = Peer(
  peerId: 'peer-alice-001',
  displayName: 'Alice',
  deviceName: 'Alice Phone',
  status: PeerStatus.online,
);

final identity = Identity(
  id: 'device-local',
  deviceId: 'device-local',
  displayName: 'Me',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

final chat = Chat(
  id: 'chat-row',
  chatId: 'chat-1',
  peerId: peer.peerId,
  title: 'Alice',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  testWidgets('sending persists a queued message with the real identity', (
    tester,
  ) async {
    final messageRepository = _FakeMessageRepository();
    await _pumpChat(tester, messageRepository);

    await tester.enterText(find.byType(TextField), 'Hello Phase 1');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.text('Hello Phase 1'), findsOneWidget);
    expect(messageRepository.messages, hasLength(1));

    final message = messageRepository.messages.single;
    expect(message.senderId, identity.deviceId);
    expect(message.content, 'Hello Phase 1');
    expect(message.status, MessageStatus.queued);
    expect(message.transport, MessageTransport.pending);

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, isEmpty);

    await tester.pump(const Duration(seconds: 2));
    expect(messageRepository.messages.single.status, MessageStatus.queued);
  });

  testWidgets('failed persistence keeps the input and shows an error', (
    tester,
  ) async {
    final messageRepository = _FakeMessageRepository()..failWrites = true;
    await _pumpChat(tester, messageRepository);

    await tester.enterText(find.byType(TextField), 'Do not lose me');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Failed to save message'), findsOneWidget);
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, 'Do not lose me');
    expect(messageRepository.messages, isEmpty);
  });
}

Future<void> _pumpChat(
  WidgetTester tester,
  _FakeMessageRepository messageRepository,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        identityRepositoryProvider.overrideWithValue(_FakeIdentityRepository()),
        chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
        peerRepositoryProvider.overrideWithValue(_FakePeerRepository()),
        messageRepositoryProvider.overrideWithValue(messageRepository),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme(),
        home: ChatScreen(chatId: chat.chatId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeIdentityRepository extends IdentityRepository {
  @override
  Future<Identity> ensureIdentity() async => identity;

  @override
  Future<Identity?> getIdentity() async => identity;

  @override
  Future<void> updateIdentity(Identity identity) async {}
}

class _FakePeerRepository extends PeerRepository {
  @override
  Future<List<Peer>> getAllPeers() async => const [peer];
}

class _FakeChatRepository extends ChatRepository {
  @override
  Future<List<Chat>> getAllChats() async => [chat];

  @override
  Future<void> resetUnreadCount(String chatId) async {}

  @override
  Future<void> updateLastMessage(
    String chatId,
    String message,
    DateTime time,
  ) async {}
}

class _FakeMessageRepository extends MessageRepository {
  final messages = <Message>[];
  bool failWrites = false;

  @override
  Future<List<Message>> getMessagesByChatId(
    String chatId, {
    int limit = 50,
    int offset = 0,
  }) async {
    return List<Message>.from(messages);
  }

  @override
  Future<bool> insertMessageAndUpdateChat(Message message) async {
    if (failWrites) throw StateError('write blocked');
    messages.add(message);
    return true;
  }
}
