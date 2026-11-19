import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/message_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/providers/settings_providers.dart';
import 'package:bechat/services/ble/ble_message_store.dart';
import 'package:bechat/services/online/people_service.dart';
import 'package:bechat/services/online/transport_manager.dart';

final transportManagerProvider =
    StateNotifierProvider<TransportManager, TransportManagerState>((ref) {
      final manager = TransportManager(
        messages: ref.read(messageRepositoryProvider),
        incomingStore: BleMessageStore(),
        peers: ref.read(peerRepositoryProvider),
        localDeviceId: () => ref.read(localDeviceIdProvider),
        isBleActive: () {
          final bleState = ref.read(bleRuntimeProvider);
          return bleState.hasSecureLink || bleState.links.isNotEmpty;
        },
        requestDelivery:
            (peerId) => ref.read(bleRuntimeProvider.notifier).requestDelivery(
              peerId,
            ),
        onChanged: (message) async {
          try {
            await ref.read(chatListProvider.notifier).refreshChats();
            await ref
                .read(messageListProvider(message.chatId).notifier)
                .refreshMessages();
          } catch (_) {}
        },
        onIncomingStored: (chatId) async {
          try {
            await ref.read(chatListProvider.notifier).refreshChats();
            await ref
                .read(messageListProvider(chatId).notifier)
                .refreshMessages();
          } catch (_) {}
        },
      );
      // The preferred transport also depends on BLE link availability, so
      // re-evaluate the mode whenever the BLE runtime state changes.
      ref.listen(bleRuntimeProvider, (_, __) => manager.refreshFromBle());
      // No ref.onDispose(manager.dispose): StateNotifierProvider already
      // disposes its notifier, and a second call trips state_notifier's
      // mounted assertion.
      return manager;
    });

/// Public BeChat IDs and connection requests. Auth and Firestore rules do
/// the real work; this service just reads/writes and formats failures.
final peopleServiceProvider = Provider<PeopleService>((ref) {
  return PeopleService(
    localDeviceId: () => ref.read(localDeviceIdProvider),
    displayName: () =>
        ref.read(identityProvider).valueOrNull?.displayName ?? 'BeChat user',
  );
});
