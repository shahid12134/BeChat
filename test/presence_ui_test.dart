import 'package:bechat/core/widgets/avatar_widget.dart';
import 'package:bechat/data/models/chat.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/features/chats/widgets/chat_list_item.dart';
import 'package:bechat/features/peers/screens/peer_details_screen.dart';
import 'package:bechat/features/peers/widgets/peer_list_item.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _peer = Peer(
  peerId: 'peer-alice',
  displayName: 'Alice',
  deviceName: 'Alice phone',
  status: PeerStatus.online,
);

const _chat = Chat(
  chatId: 'chat-alice',
  peerId: 'peer-alice',
  title: 'Alice',
  lastMessage: 'Hello',
);

void main() {
  testWidgets('a persisted online peer is offline while the runtime is idle', (
    tester,
  ) async {
    await _pump(
      tester,
      const BleRuntimeState(),
      const PeerListItem(peer: _peer),
    );

    expect(find.text('Offline'), findsOneWidget);
    expect(
      tester.widget<PeerAvatar>(find.byType(PeerAvatar)).isOnline,
      isFalse,
    );
  });

  testWidgets('a matching active peer is shown as connected', (tester) async {
    await _pump(
      tester,
      const BleRuntimeState(
        status: BleRuntimeStatus.connected,
        activePeerId: 'peer-alice',
        activePeerName: 'Alice',
        activeRole: BleLinkRole.central,
        activeSignalStrength: -44,
      ),
      const PeerListItem(peer: _peer),
    );

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('-44 dBm'), findsOneWidget);
    expect(tester.widget<PeerAvatar>(find.byType(PeerAvatar)).isOnline, isTrue);
  });

  testWidgets('blocked takes precedence over an active connection', (
    tester,
  ) async {
    await _pump(
      tester,
      const BleRuntimeState(
        status: BleRuntimeStatus.connected,
        activePeerId: 'peer-alice',
        activePeerName: 'Alice',
        activeRole: BleLinkRole.central,
      ),
      PeerListItem(peer: _peer.copyWith(status: PeerStatus.blocked)),
    );

    expect(find.text('Blocked'), findsOneWidget);
    expect(
      tester.widget<PeerAvatar>(find.byType(PeerAvatar)).isOnline,
      isFalse,
    );
  });

  testWidgets('chat list ignores a stale persisted online status', (
    tester,
  ) async {
    await _pump(
      tester,
      const BleRuntimeState(),
      const ChatListItem(chat: _chat),
    );

    expect(
      tester.widget<PeerAvatar>(find.byType(PeerAvatar)).isOnline,
      isFalse,
    );
    expect(find.textContaining('Connected'), findsNothing);
  });

  testWidgets('chat list shows live presence for the active peer', (
    tester,
  ) async {
    await _pump(
      tester,
      const BleRuntimeState(
        status: BleRuntimeStatus.connected,
        activePeerId: 'peer-alice',
        activePeerName: 'Alice',
        activeRole: BleLinkRole.central,
      ),
      const ChatListItem(chat: _chat),
    );

    expect(tester.widget<PeerAvatar>(find.byType(PeerAvatar)).isOnline, isTrue);
    expect(find.textContaining('Connected'), findsOneWidget);
  });

  testWidgets('blocking an active peer closes the BLE link', (tester) async {
    final repository = _BlockingPeerRepository();
    late _RecordingBleRuntimeController runtime;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/peer/:peerId',
          builder: (context, state) =>
              PeerDetailsScreen(peerId: state.pathParameters['peerId']!),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peerRepositoryProvider.overrideWithValue(repository),
          bleRuntimeProvider.overrideWith((ref) {
            runtime = _RecordingBleRuntimeController(ref);
            return runtime;
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    router.push('/peer/${_peer.peerId}');
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Block Peer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block Peer'));
    await tester.pumpAndSettle();

    expect(repository.blockedPeerIds, [_peer.peerId]);
    expect(runtime.disconnectedPeerIds, [_peer.peerId]);
    expect(find.text('home'), findsOneWidget);
  });
}

Future<void> _pump(
  WidgetTester tester,
  BleRuntimeState runtimeState,
  Widget child,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        peerRepositoryProvider.overrideWithValue(_PeerRepository()),
        bleRuntimeProvider.overrideWith(
          (ref) => _FakeBleRuntimeController(ref, runtimeState),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}

class _PeerRepository extends PeerRepository {
  @override
  Future<List<Peer>> getAllPeers() async => const [_peer];
}

class _BlockingPeerRepository extends _PeerRepository {
  final blockedPeerIds = <String>[];

  @override
  Future<void> blockPeer(
    String peerId, {
    String? displayName,
    String? deviceName,
    int? signalStrength,
  }) async {
    blockedPeerIds.add(peerId);
  }
}

class _FakeBleRuntimeController extends BleRuntimeController {
  _FakeBleRuntimeController(super.ref, BleRuntimeState initialState) {
    state = initialState;
  }
}

class _RecordingBleRuntimeController extends BleRuntimeController {
  _RecordingBleRuntimeController(super.ref) {
    state = const BleRuntimeState(
      status: BleRuntimeStatus.connected,
      activePeerId: 'peer-alice',
      activePeerName: 'Alice',
      activeRole: BleLinkRole.central,
    );
  }

  final disconnectedPeerIds = <String>[];

  @override
  Future<void> disconnectPeer(String peerId) async {
    disconnectedPeerIds.add(peerId);
  }
}
