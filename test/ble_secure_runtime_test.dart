// Stage 6, Phase 2H — production BLE runtime secure-activation suite.
//
// These tests run the REAL BleRuntimeController against a real in-memory
// application database and a real BleLinkSession on the peer side. Only the
// platform BLE managers and the native Noise gateway are faked. They prove
// the Dart integration: Noise role mapping, approval and pin policy,
// fail-closed error handling, secure message/ACK transport, outbox gating
// and state publication.
//
// What they do NOT prove: real BLE encryption on physical hardware. The fake
// Noise gateway is a call-contract stand-in and no radio is involved, so a
// passing run is not evidence that encrypted messaging works end-to-end on
// a device. Physical-device validation (OnePlus Nord 5G, Samsung Galaxy
// A22 5G) remains outstanding.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_routing_envelope.dart';
import 'package:bechat/core/ble/ble_secure_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/core/ble/peer_presence.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/models/app_settings.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/data/models/relay_queue_entry.dart';
import 'package:bechat/data/repositories/app_settings_repository.dart';
import 'package:bechat/data/repositories/chat_repository.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/data/repositories/message_repository.dart';
import 'package:bechat/data/repositories/peer_repository.dart';
import 'package:bechat/providers/app_settings_providers.dart';
import 'package:bechat/providers/background_service_provider.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/identity_initialization_providers.dart';
import 'package:bechat/providers/message_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/providers/secure_session_providers.dart';
import 'package:bechat/providers/settings_providers.dart';
import 'package:bechat/services/background/background_ble_service.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:bechat/services/ble/ble_status_probe.dart';
import 'package:bechat/services/crypto/identity_initialization_coordinator.dart';
import 'package:bechat/services/crypto/native_identity_service.dart';
import 'package:bechat/services/crypto/native_secure_session_service.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/ble_secure_fixtures.dart';
import 'helpers/test_database.dart';

// Fixed identities for the simulated peer. Both device IDs are UUIDs because
// the runtime requires authenticated device IDs to be UUID-formatted.
const _peerUuid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const _otherUuid = '11111111-2222-4333-8444-555555555555';

final _localKeyBytes = Uint8List.fromList(List.filled(32, 0x7a));
final _peerKeyBytes = Uint8List.fromList(List.filled(32, 0xbb));
final _rogueKeyBytes = Uint8List.fromList(List.filled(32, 0xcc));
final _localKeyHex = hexOf(_localKeyBytes);
final _peerKeyHex = hexOf(_peerKeyBytes);
final _fingerprintHex = hexOf(Uint8List.fromList(List.filled(32, 0xdd)));

// The peer's HELLO advertises an untrusted hint name; the authenticated
// identity presents a different one so tests can prove name authority.
const _helloName = 'Peer Phone';
const _authenticatedName = 'Peer Authenticated Name';

const _queuedContent = 'quarterly payload review at seventeen hundred';

void main() {
  group('secure connection activation', () {
    test('peripheral role starts the Noise handshake and publishes a confirmed '
        'secure link', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      await h.controller.ensureStarted();
      expect(h.controller.state.status, BleRuntimeStatus.ready);
      expect(h.controller.state.activeRole, isNull);
      expect(h.controller.state.isSecureReady, isFalse);

      h.createPeerSession(role: BleSecureRole.responder);
      h.peerSession!.startFireAndForget();
      h.announcePeripheralLink();
      await h.pumpUntil(
        () => h.runtimeFrames.isNotEmpty,
        reason: 'the runtime never wrote its HELLO',
      );
      await h.pumpUntil(
        () => h.gateway.countFor(h.localDevice.deviceId, 'createSession') == 1,
        reason: 'the runtime never started its Noise session',
      );
      await h.finishSecureHandshake(peerIsInitiator: false);

      final state = h.controller.state;
      expect(state.status, BleRuntimeStatus.connected);
      expect(state.isSecureReady, isTrue);
      expect(state.activePeerId, _peerUuid);
      // The display name comes from the authenticated identity, never the
      // HELLO hint.
      expect(state.activePeerName, _authenticatedName);
      expect(state.activeRole, BleLinkRole.peripheral);
      expect(state.error, isNull);

      // BLE peripheral maps to the Noise initiator; the peer is responder.
      expect(
        h.gateway.calls.first,
        'createSession(${h.localDevice.deviceId}, initiator=true)',
      );
      expect(
        h.peerGateway.calls.first,
        'createSession($_peerUuid, initiator=false)',
      );

      final row = await h.peerRepository.getPeerByPeerId(_peerUuid);
      expect(row, isNotNull);
      // A pinned peer keeps its stored metadata: the authenticated name
      // governs the live link (asserted above) but never rewrites the row.
      expect(row!.displayName, 'Stored Name');
      expect(row.publicKey, _peerKeyHex);
      expect(row.keyVerificationState, PeerKeyVerificationState.unverified);
      expect(row.status, PeerStatus.online);

      // The stored pin was forwarded to the engine's createSession.
      expect(
        h.gateway.pinsForwarded[h.localDevice.deviceId],
        orderedEquals(_peerKeyBytes),
      );

      // Presence comes from the live link, not an RSSI poll.
      expect(
        resolvePeerPresence(row, state.presenceContext),
        PeerPresence.connected,
      );
      verifyNever(h.central.readRSSI(any));

      // The chat exists only after the authenticated link was published.
      expect(await h.chatRepository.getChatByPeerId(_peerUuid), isNotNull);
    });

    test('central role acts as the Noise responder and persists first-contact '
        'metadata from the authenticated identity', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      // A saved peer with no key: auto-approved reconnect, first contact
      // for key purposes.
      await h.seedPeer(publicKeyHex: null);

      h.createPeerSession(role: BleSecureRole.initiator);
      await h.connectAsCentral();

      // BLE central maps to the Noise responder.
      await h.pumpUntil(
        () => h.gateway.countFor(h.localDevice.deviceId, 'createSession') == 1,
        reason: 'the runtime never started its Noise session',
      );
      expect(
        h.gateway.calls.first,
        'createSession(${h.localDevice.deviceId}, initiator=false)',
      );

      await h.finishSecureHandshake(peerIsInitiator: true);
      expect(
        h.peerGateway.calls.first,
        'createSession($_peerUuid, initiator=true)',
      );

      final state = h.controller.state;
      expect(state.isSecureReady, isTrue);
      expect(state.activeRole, BleLinkRole.central);
      expect(state.activePeerName, _authenticatedName);

      final row = await h.peerRepository.getPeerByPeerId(_peerUuid);
      expect(row, isNotNull);
      expect(row!.displayName, _authenticatedName);
      expect(row.publicKey, _peerKeyHex);
      expect(row.keyVerificationState, PeerKeyVerificationState.unverified);

      // Central-role links resolve presence from the live link without
      // polling RSSI.
      expect(
        resolvePeerPresence(row, state.presenceContext),
        PeerPresence.connected,
      );
      verifyNever(h.central.readRSSI(any));
    });

    test('an uninitialized cryptographic identity fails closed with a '
        'user-visible secure-unavailable error', () async {
      final h = await _SecureRuntimeHarness.create(initializeIdentity: false);
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      await h.controller.ensureStarted();
      h.createPeerSession(role: BleSecureRole.responder);
      h.announcePeripheralLink();

      await h.pumpUntil(
        () => h.controller.state.error != null,
        reason: 'the runtime never reported the identity failure',
      );
      expect(
        h.controller.state.error,
        contains('Secure messaging is unavailable'),
      );
      expect(h.controller.state.isSecureReady, isFalse);
      expect(h.controller.state.incomingRequest, isNull);
      expect(
        h.gateway.calls.where((c) => c.startsWith('createSession')),
        isEmpty,
      );
      expect(h.runtimeFrameLog, isEmpty);
    });

    test('a stored identity key that disagrees with the native identity fails '
        'closed', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);
      // Corrupt the stored copy: the native status keeps the real key.
      await h.db.update('identity', {'public_key': _peerKeyHex});
      await h.container.read(identityProvider.notifier).loadIdentity();

      await h.controller.ensureStarted();
      h.createPeerSession(role: BleSecureRole.responder);
      h.announcePeripheralLink();

      await h.pumpUntil(
        () => h.controller.state.error != null,
        reason: 'the runtime never reported the key mismatch',
      );
      expect(
        h.controller.state.error,
        contains('does not match the stored identity'),
      );
      expect(h.controller.state.isSecureReady, isFalse);
      expect(
        h.gateway.calls.where((c) => c.startsWith('createSession')),
        isEmpty,
      );
      expect(h.runtimeFrameLog, isEmpty);
    });

    test(
      'a native identity that belongs to a different device fails closed',
      () async {
        final h = await _SecureRuntimeHarness.create();
        addTearDown(h.dispose);
        await h.seedPeer(publicKeyHex: _peerKeyHex);
        await h.db.update('identity', {'device_id': _otherUuid});
        await h.container.read(identityProvider.notifier).loadIdentity();

        await h.controller.ensureStarted();
        h.createPeerSession(role: BleSecureRole.responder);
        h.announcePeripheralLink();

        await h.pumpUntil(
          () => h.controller.state.error != null,
          reason: 'the runtime never reported the device mismatch',
        );
        expect(
          h.controller.state.error,
          contains('does not belong to this device'),
        );
        expect(h.controller.state.isSecureReady, isFalse);
        expect(
          h.gateway.calls.where((c) => c.startsWith('createSession')),
          isEmpty,
        );
      },
    );
  });

  group('approval and first contact', () {
    test('a first-contact peer must be approved before any handshake and is '
        'persisted unverified under its authenticated name', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.controller.ensureStarted();

      h.createPeerSession(role: BleSecureRole.responder);
      h.peerSession!.startFireAndForget();
      h.announcePeripheralLink();
      await h.pumpUntil(
        () => h.controller.state.incomingRequest != null,
        reason: 'no approval request appeared for the unknown peer',
      );

      final request = h.controller.state.incomingRequest!;
      expect(request.peerId, _peerUuid);
      // The approval UI shows the untrusted HELLO hint before the peer is
      // authenticated.
      expect(request.displayName, _helloName);

      // Approval alone persists nothing and starts no secure session.
      expect(await h.peerRepository.getPeerByPeerId(_peerUuid), isNull);
      expect(
        h.gateway.calls.where((c) => c.startsWith('createSession')),
        isEmpty,
      );
      expect(h.controller.state.isSecureReady, isFalse);

      await h.controller.acceptIncomingRequest(request.requestId);
      await h.pumpUntil(
        () => h.gateway.countFor(h.localDevice.deviceId, 'createSession') == 1,
        reason: 'the runtime never started its Noise session after approval',
      );
      await h.finishSecureHandshake(peerIsInitiator: false);

      expect(h.controller.state.isSecureReady, isTrue);
      final row = await h.peerRepository.getPeerByPeerId(_peerUuid);
      expect(row, isNotNull);
      // The authenticated identity — not the HELLO hint — names the peer.
      expect(row!.displayName, _authenticatedName);
      expect(row.publicKey, _peerKeyHex);
      expect(row.keyVerificationState, PeerKeyVerificationState.unverified);
      // First contact has no stored pin yet: the engine received no pin at
      // createSession time, and the authenticated key was recorded only
      // after the handshake confirmed it (trust on first use).
      expect(h.gateway.pinsForwarded[h.localDevice.deviceId], isNull);
    });

    test('the HELLO hint never overwrites a stored peer name or key', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(displayName: 'Stored Name', publicKeyHex: _peerKeyHex);

      await h.controller.ensureStarted();
      h.createPeerSession(role: BleSecureRole.responder);
      h.peerSession!.startFireAndForget();
      h.announcePeripheralLink();
      await h.pumpUntil(
        () => h.gateway.countFor(h.localDevice.deviceId, 'createSession') == 1,
        reason: 'the link never reached the handshake',
      );
      await h.finishSecureHandshake(peerIsInitiator: false);

      final row = await h.peerRepository.getPeerByPeerId(_peerUuid);
      expect(row!.displayName, 'Stored Name');
      expect(row.publicKey, _peerKeyHex);
      expect(row.keyVerificationState, PeerKeyVerificationState.unverified);
      // The live link still presents the authenticated name to the UI.
      expect(h.controller.state.activePeerName, _authenticatedName);
    });
  });

  group('pinned-key security', () {
    test('a changed key fails closed and records the conflict while preserving '
        'the pin', () async {
      // The peer now authenticates with a different static key than the
      // one pinned in the database.
      final h = await _SecureRuntimeHarness.create(peerKey: _rogueKeyBytes);
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      await h.controller.ensureStarted();
      h.createPeerSession(role: BleSecureRole.responder);
      h.peerSession!.startFireAndForget();
      h.announcePeripheralLink();
      // Drive the handshake: the fake engine compares the peer's static key
      // against the forwarded pin when the handshake finishes, and fails the
      // session on the mismatch.
      await h.pumpUntil(
        () =>
            h.peerSession!.secureState ==
            BleSecureLinkState.awaitingAuthorization,
        reason: 'the peer session never finished its HELLO exchange',
      );
      unawaited(h.peerSession!.startSecureHandshake());
      await h.pumpUntil(
        () => h.controller.state.error != null,
        reason: 'the pin conflict never failed the link',
      );

      expect(
        h.controller.state.error,
        contains('does not match the pinned key'),
      );
      final state = h.controller.state;
      expect(state.isSecureReady, isFalse);
      expect(state.activePeerId, isNull);
      expect(state.status, isNot(BleRuntimeStatus.connected));

      final row = await h.peerRepository.getPeerByPeerId(_peerUuid);
      expect(row!.publicKey, _peerKeyHex, reason: 'the original pin stays');
      expect(row.keyVerificationState, PeerKeyVerificationState.changed);
      expect(row.keyChangedAt, isNotNull);

      // No application frame ever crossed the link.
      expect(
        secureTransfersOf(
          h.runtimeFrameLog,
        ).where((t) => t.kind != BleSecureTransferKind.secureHandshake),
        isEmpty,
      );
    });
  });

  group('legacy and unsupported peers', () {
    test('a legacy peer without the Noise capability fails closed with an '
        'update-required error', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.controller.ensureStarted();

      h.createPeerSession(role: BleSecureRole.responder, secure: false);
      h.peerSession!.startFireAndForget();
      h.announcePeripheralLink();

      await h.pumpUntil(
        () => h.controller.state.error != null,
        reason: 'the legacy peer never failed the link',
      );
      expect(h.controller.state.error, contains('update BeChat'));
      expect(h.controller.state.isSecureReady, isFalse);
      expect(h.controller.state.incomingRequest, isNull);
      expect(
        h.gateway.calls.where((c) => c.startsWith('createSession')),
        isEmpty,
      );
      // The peer was never persisted and no v2 frame was ever written.
      expect(await h.peerRepository.getPeerByPeerId(_peerUuid), isNull);
      expect(h.runtimeFrameLog.every((f) => !_isSecureFrame(f)), isTrue);
    });

    test('an authenticated identity with an unsupported protocol version fails '
        'closed', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);
      h.remoteIdentityOverride = (localId) => RemoteAuthenticatedIdentity(
        publicKeyHex: _peerKeyHex,
        deviceId: _peerUuid,
        displayName: _authenticatedName,
        protocolVersion: 99,
        capabilities: BleSecureProtocol.capabilitySecureText,
      );

      await h.controller.ensureStarted();
      h.createPeerSession(role: BleSecureRole.responder);
      h.peerSession!.startFireAndForget();
      h.announcePeripheralLink();
      // The handshake must run to completion before the runtime validates
      // the authenticated identity; the override applies at that point.
      await h.pumpUntil(
        () =>
            h.peerSession!.secureState ==
            BleSecureLinkState.awaitingAuthorization,
        reason: 'the peer session never finished its HELLO exchange',
      );
      unawaited(h.peerSession!.startSecureHandshake());
      await h.pumpUntil(
        () => h.controller.state.error != null,
        reason: 'the version mismatch never failed the link',
      );

      expect(
        h.controller.state.error,
        contains('unsupported secure protocol version'),
      );
      expect(h.controller.state.isSecureReady, isFalse);
      expect(
        secureTransfersOf(
          h.runtimeFrameLog,
        ).where((t) => t.kind != BleSecureTransferKind.secureHandshake),
        isEmpty,
      );
    });

    test('an authenticated identity without the secure-text capability fails '
        'closed', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);
      h.remoteIdentityOverride = (localId) => RemoteAuthenticatedIdentity(
        publicKeyHex: _peerKeyHex,
        deviceId: _peerUuid,
        displayName: _authenticatedName,
        protocolVersion: BleSecureProtocol.identityFormatVersion,
        capabilities: 0,
      );

      await h.controller.ensureStarted();
      h.createPeerSession(role: BleSecureRole.responder);
      h.peerSession!.startFireAndForget();
      h.announcePeripheralLink();
      // The handshake must run to completion before the runtime validates
      // the authenticated identity; the override applies at that point.
      await h.pumpUntil(
        () =>
            h.peerSession!.secureState ==
            BleSecureLinkState.awaitingAuthorization,
        reason: 'the peer session never finished its HELLO exchange',
      );
      unawaited(h.peerSession!.startSecureHandshake());
      await h.pumpUntil(
        () => h.controller.state.error != null,
        reason: 'the missing capability never failed the link',
      );

      expect(
        h.controller.state.error,
        contains('does not support secure messaging'),
      );
      expect(h.controller.state.isSecureReady, isFalse);
    });
  });

  group('reliability and lifecycle', () {
    test('a stalled handshake is closed by the runtime deadline without any '
        'plaintext fallback', () async {
      final h = await _SecureRuntimeHarness.create(
        linkHandshakeTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      await h.controller.ensureStarted();
      h.createPeerSession(role: BleSecureRole.responder);
      h.peerSession!.startFireAndForget();
      h.announcePeripheralLink();
      // The peer session never answers the handshake, so message 1 is
      // never responded to.
      await h.pumpUntil(
        () => h.controller.state.error != null,
        reason: 'the stalled handshake never timed out',
      );

      final error = h.controller.state.error!;
      expect(
        error.contains('timed out') ||
            error.contains('could not be established in time'),
        isTrue,
        reason: 'unexpected timeout error: $error',
      );
      expect(h.controller.state.isSecureReady, isFalse);
      expect(h.controller.state.activePeerId, isNull);
      // The peer only ever saw the plaintext HELLO — nothing else was
      // written while the handshake stalled.
      expect(h.peerFrameLog.where(_isSecureFrame), isEmpty);
    });

    test('a disconnect tears the secure state down and late events cannot '
        'resurrect it', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      h.createPeerSession(role: BleSecureRole.initiator);
      await h.connectAsCentral();
      await h.pumpUntil(
        () => h.gateway.countFor(h.localDevice.deviceId, 'createSession') == 1,
        reason: 'the link never became secure',
      );
      await h.finishSecureHandshake(peerIsInitiator: true);
      expect(h.controller.state.isSecureReady, isTrue);

      await h.controller.disconnect();
      await h.pumpUntil(
        () => h.controller.state.activePeerId == null,
        reason: 'the link was never torn down',
      );
      expect(h.controller.state.isSecureReady, isFalse);
      expect(h.controller.state.status, isNot(BleRuntimeStatus.connected));

      // A late notification from the dead connection must be ignored.
      final decryptCalls = h.gateway.decryptHandles.length;
      final lateFrames = List<Uint8List>.from(h.peerFrameLog);
      for (final frame in lateFrames) {
        h.notified.add(
          GATTCharacteristicNotifiedEventArgs(
            h.peerPeripheral,
            txCharacteristic,
            frame,
          ),
        );
      }
      await h.pump();
      expect(h.controller.state.isSecureReady, isFalse);
      expect(h.controller.state.activePeerId, isNull);
      expect(h.gateway.decryptHandles.length, decryptCalls);
    });

    test('direct messages still work when the local routing identity is '
        'unavailable', () async {
      // The runtime's incoming message store opens DatabaseHelper's app
      // database through sqflite's global factory, which plain flutter test
      // never registers (sqfliteFfiInit only loads the Windows sqlite3 DLL).
      databaseFactory = databaseFactoryFfi;
      final h = await _SecureRuntimeHarness.create(
        nullLocalRoutingIdentity: true,
      );
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      h.createPeerSession(role: BleSecureRole.initiator);
      await h.connectAsCentral();
      await h.pumpUntil(
        () => h.gateway.countFor(h.localDevice.deviceId, 'createSession') == 1,
        reason: 'the link never became secure',
      );
      await h.finishSecureHandshake(peerIsInitiator: true);
      expect(h.controller.state.isSecureReady, isTrue);

      // The routing handler is constructed only for routing envelopes, so
      // plain direct payloads must neither require nor notice the local
      // routing identity.
      expect(h.container.read(localDeviceIdProvider), isNull);

      // Unique per run: the runtime's incoming pipeline persists through
      // DatabaseHelper (the app database the store opens by default), whose
      // file outlives the test run — unlike this harness's test database.
      final messageId =
          'in-direct-no-routing-id-${DateTime.now().microsecondsSinceEpoch}';
      BleAckResult? ackResult;
      Object? sendError;
      unawaited(
        h.peerSession!
            .sendMessage(
              Message(
                messageId: messageId,
                chatId: 'chat-direct',
                senderId: h.peerDevice.deviceId,
                receiverId: h.localDevice.deviceId,
                content: 'direct without a routing identity',
                timestamp: DateTime.now(),
              ),
            )
            .then(
              (result) {
                ackResult = result;
              },
              onError: (Object error) {
                sendError = error;
              },
            ),
      );
      await h.pumpUntil(
        () => ackResult != null || sendError != null,
        reason: 'the direct message never got an ACK',
      );
      expect(sendError, isNull);
      expect(ackResult, BleAckResult.stored);

      // The ACK is written only after durable storage, so the row must exist
      // in the database the runtime's message store actually uses.
      final rows = await (await DatabaseHelper.database).query(
        'messages',
        where: 'message_id = ?',
        whereArgs: [messageId],
        limit: 1,
      );
      expect(rows, hasLength(1));
    });

    test('the local cryptographic identity is initialized exactly once and '
        'never re-provisioned', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      h.createPeerSession(role: BleSecureRole.responder);
      h.peerSession!.startFireAndForget();
      await h.connectAsPeripheralSecureLink();

      expect(h.nativeIdentity.initializeCalls, 1);
      // Re-running the published initialization flow reuses the settled
      // coordinator; the native layer is never asked for a second identity.
      final again = await h.initializeIdentity();
      expect(again.state, IdentityInitializationState.ready);
      expect(h.nativeIdentity.initializeCalls, 1);
      final rows = await h.db.query('identity');
      expect(rows, hasLength(1));
    });

    test('background pause closes the secure link and resume does not restore '
        'secure readiness', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      h.createPeerSession(role: BleSecureRole.responder);
      h.peerSession!.startFireAndForget();
      await h.connectAsPeripheralSecureLink();
      expect(h.controller.state.isSecureReady, isTrue);

      await h.controller.pauseForBackground();
      expect(h.controller.state.isSecureReady, isFalse);
      expect(h.controller.state.activePeerId, isNull);
      expect(h.controller.state.status, BleRuntimeStatus.idle);

      await h.controller.resumeFromBackground();
      expect(h.controller.state.status, BleRuntimeStatus.ready);
      // Resuming recovers advertising only; the secure link is gone until
      // a new authenticated handshake completes.
      expect(h.controller.state.isSecureReady, isFalse);
    });

    test('queued messages stay unsent until the link is secure, then drain '
        'with encrypted payloads and secure acknowledgements', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);
      await h.seedQueuedMessage(content: _queuedContent);

      await h.controller.ensureStarted();
      h.createPeerSession(role: BleSecureRole.responder);
      h.peerSession!.startFireAndForget();
      h.announcePeripheralLink();
      await h.pumpUntil(
        () => h.gateway.countFor(h.localDevice.deviceId, 'createSession') == 1,
        reason: 'the link never reached the handshake',
      );

      // Park the peer's Noise step so the link stalls mid-handshake.
      h.peerGateway.parkProcessHandshakeFor = _peerUuid;
      await h.pumpUntil(
        () =>
            h.peerSession!.secureState ==
            BleSecureLinkState.awaitingAuthorization,
        reason: 'the peer session never finished its HELLO exchange',
      );
      await h.peerSession!.startSecureHandshake();
      await h.pumpUntil(
        () => h.peerGateway.countFor(_peerUuid, 'processHandshake') >= 1,
        reason: 'the peer never entered its handshake',
      );

      // Mid-handshake: the outbox must not send anything.
      await h.controller.requestDelivery(_peerUuid);
      await h.pump();
      expect(await h.messageStatus('out-1'), MessageStatus.queued);
      expect(h.gateway.countFor(h.localDevice.deviceId, 'encrypt'), 0);
      expect(
        secureTransfersOf(
          h.runtimeFrameLog,
        ).where((t) => t.kind == BleSecureTransferKind.secureMessage),
        isEmpty,
      );

      // Release the parked step; the handshake completes and both sides
      // confirm the authenticated identity.
      final release = h.peerGateway.releaseParked!;
      h.peerGateway.parkProcessHandshakeFor = null;
      release(
        HandshakeStepResult(
          outgoing: secureMsg2,
          finished: false,
          confirmationRequired: false,
        ),
      );
      await h.pumpUntil(
        () => h.controller.state.isSecureReady,
        reason: 'the link never became secure-ready',
      );
      await h.pumpUntil(
        () =>
            h.peerSession!.secureState ==
            BleSecureLinkState.awaitingConfirmation,
        reason: 'the peer session never finished its handshake',
      );
      await h.peerSession!.confirmSecurePeerIdentity();

      // The outbox drains over the secure link; the peer's stored ACK
      // completes the delivery.
      await h.controller.requestDelivery(_peerUuid);
      await h.pumpUntil(
        () async => await h.messageStatus('out-1') == MessageStatus.delivered,
        reason: 'the message was never delivered',
      );

      // Exactly one Noise encryption for the one send.
      expect(h.gateway.countFor(h.localDevice.deviceId, 'encrypt'), 1);
      // The encrypted message travelled runtime -> peer; the encrypted
      // acknowledgement travelled peer -> runtime.
      expect(
        secureTransfersOf(h.runtimeFrameLog).map((t) => t.kind),
        containsAll(<BleSecureTransferKind>{
          BleSecureTransferKind.secureHandshake,
          BleSecureTransferKind.secureMessage,
        }),
      );
      expect(
        secureTransfersOf(h.peerFrameLog).map((t) => t.kind),
        containsAll(<BleSecureTransferKind>{
          BleSecureTransferKind.secureHandshake,
          BleSecureTransferKind.secureAck,
        }),
      );

      // No plaintext application traffic anywhere: only the v1 HELLO
      // (which carries no message content) used the legacy framing.
      expect(v1KindsOf(h.runtimeFrameLog), [BleTransferKind.hello]);
      final contentBytes = utf8.encode(_queuedContent);
      for (final frame in [...h.runtimeFrameLog, ...h.peerFrameLog]) {
        expect(
          _containsBytes(frame, contentBytes),
          isFalse,
          reason: 'message plaintext appeared on the wire',
        );
      }
    });

    test('a parked queued envelope is retried when a secure-ready link '
        'becomes available', () async {
      final envelopeId =
          'retry-on-link-${DateTime.now().microsecondsSinceEpoch}';
      final db = await _seedRelayQueue([
        _parkedEntry(
          envelopeId: envelopeId,
          origin: _otherUuid,
          destination: _retryDestinationUuid,
          incomingPeer: _retryRelayUuid,
        ),
      ]);
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      final received = <BleRoutingEnvelope>[];
      h.createPeerSession(
        role: BleSecureRole.initiator,
        onRoutingEnvelope: (envelope) async {
          received.add(envelope);
          return BleAckResult.stored;
        },
      );
      await h.connectAsCentral();
      await h.pumpUntil(
        () => h.gateway.countFor(h.localDevice.deviceId, 'createSession') >= 1,
        reason: 'the link never reached the handshake',
      );
      await h.finishSecureHandshake(peerIsInitiator: true);
      expect(h.controller.state.isSecureReady, isTrue);

      // No explicit retry call: the secure-ready publish itself triggers the
      // sweep, exactly as a relay reconnecting unblocks parked envelopes.
      await h.pumpUntil(
        () async {
          final rows = await db.query(
            'relay_queue',
            where: 'envelope_id = ?',
            whereArgs: [envelopeId],
            limit: 1,
          );
          return rows.isNotEmpty && rows.first['state'] == 'sent';
        },
        reason: 'the parked envelope was never retried after link-up',
      );
      expect(received, hasLength(1));
      expect(received.single.envelopeId, envelopeId);
    });

    test('retry never bounces an envelope to the incoming peer or the origin',
        () async {
      final db = await _seedRelayQueue([
        _parkedEntry(
          envelopeId: 'retry-excl-incoming',
          origin: _otherUuid,
          destination: _retryDestinationUuid,
          incomingPeer: _peerUuid, // the only link this test ever opens
        ),
        _parkedEntry(
          envelopeId: 'retry-excl-origin',
          origin: _peerUuid, // the origin IS the link's peer
          destination: _retryDestinationUuid,
          incomingPeer: _retryRelayUuid,
        ),
      ]);
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      final received = <BleRoutingEnvelope>[];
      h.createPeerSession(
        role: BleSecureRole.initiator,
        onRoutingEnvelope: (envelope) async {
          received.add(envelope);
          return BleAckResult.stored;
        },
      );
      await h.connectAsCentral();
      await h.pumpUntil(
        () => h.gateway.countFor(h.localDevice.deviceId, 'createSession') >= 1,
        reason: 'the link never reached the handshake',
      );
      await h.finishSecureHandshake(peerIsInitiator: true);

      // Explicit sweep over a secure-ready link: both entries are backoff-
      // eligible, so any send would have to happen now.
      await h.controller.retryRelayQueue();
      for (var i = 0; i < 5; i++) {
        await h.pump();
      }

      expect(
        received,
        isEmpty,
        reason: 'the link is both the incoming peer and an origin — excluded',
      );
      final rows = await db.query('relay_queue', orderBy: 'envelope_id');
      expect(rows, hasLength(2));
      for (final row in rows) {
        // No eligible hop means no attempt was burned and nothing changed.
        expect(row['state'], 'queued', reason: '${row['envelope_id']}');
        expect(row['attempts'], 0, reason: '${row['envelope_id']}');
      }
    });

    test('a retry sends the stored envelope bytes without incrementing '
        'hopCount', () async {
      final envelopeId =
          'retry-no-hopcount-${DateTime.now().microsecondsSinceEpoch}';
      final db = await _seedRelayQueue([
        _parkedEntry(
          envelopeId: envelopeId,
          origin: _otherUuid,
          destination: _retryDestinationUuid,
          incomingPeer: _retryRelayUuid,
          hopCount: 2, // already forwarded twice upstream
        ),
      ]);
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: _peerKeyHex);

      final received = <BleRoutingEnvelope>[];
      h.createPeerSession(
        role: BleSecureRole.initiator,
        onRoutingEnvelope: (envelope) async {
          received.add(envelope);
          return BleAckResult.stored;
        },
      );
      await h.connectAsCentral();
      await h.pumpUntil(
        () => h.gateway.countFor(h.localDevice.deviceId, 'createSession') >= 1,
        reason: 'the link never reached the handshake',
      );
      await h.finishSecureHandshake(peerIsInitiator: true);

      final retry = h.controller.retryRelayQueue();
      await h.pumpUntil(
        () async {
          final rows = await db.query(
            'relay_queue',
            where: 'envelope_id = ?',
            whereArgs: [envelopeId],
            limit: 1,
          );
          return rows.isNotEmpty && rows.first['state'] == 'sent';
        },
        reason: 'the retry never completed',
      );
      await retry;

      expect(received, hasLength(1));
      expect(
        received.single.hopCount,
        2,
        reason: 'retry must send stored bytes as-is, never forward() again',
      );
      final rows = await db.query(
        'relay_queue',
        where: 'envelope_id = ?',
        whereArgs: [envelopeId],
        limit: 1,
      );
      expect(rows.first['hop_count'], 2);
    });

    test('a reconnect waits for the previous teardown of the same device '
        'before touching the GATT layer again', () async {
      final h = await _SecureRuntimeHarness.create();
      addTearDown(h.dispose);
      await h.seedPeer(publicKeyHex: null);

      // Count connects directly: mockito verify() consumes matched calls,
      // so it cannot observe the same call twice.
      var connectCalls = 0;
      when(h.central.connect(any)).thenAnswer((invocation) async {
        connectCalls++;
        if (connectCalls > 1) {
          throw Exception('reconnect probe');
        }
        final p = invocation.positionalArguments.first as Peripheral;
        h.connections.add(
          PeripheralConnectionStateChangedEventArgs(p, ConnectionState.connected),
        );
      });

      h.createPeerSession(role: BleSecureRole.initiator);
      await h.connectAsCentral();
      expect(connectCalls, 1);

      // Hold the disconnect open so the previous GATT instance for this
      // address is still tearing down when the user retries.
      var disconnectStarted = false;
      final release = Completer<void>();
      when(h.central.disconnect(any)).thenAnswer((_) {
        disconnectStarted = true;
        return release.future;
      });
      final closing = h.controller.disconnect();
      await h.pumpUntil(
        () => disconnectStarted,
        reason: 'the disconnect never started',
      );

      // A fresh scan repopulates the candidate map that the successful link
      // had dropped (the user scans again after a link goes away), while the
      // previous teardown for this address is still in flight.
      await h.controller.startScan();
      h.discovered.add(
        DiscoveredEventArgs(
          h.peerPeripheral,
          -60,
          Advertisement(
            name: _helloName,
            serviceUUIDs: [UUID.fromString(BleProtocol.serviceUuid)],
          ),
        ),
      );
      await h.pumpUntil(
        () => h.controller.state.candidates.isNotEmpty,
        reason: 'the candidate never returned',
      );

      // The retry must queue behind the teardown instead of overwriting the
      // plugin's address-keyed GATT state (the status-1 descriptor failure).
      final reconnect = h.controller.connectToCandidate(_peerUuid);
      for (var i = 0; i < 5; i++) {
        await h.pump();
      }
      expect(connectCalls, 1, reason: 'reconnect started during teardown');

      release.complete();
      await closing;
      expect(await reconnect, isNull);
      expect(
        connectCalls,
        2,
        reason:
            'reconnect never ran after teardown; '
            'error=${h.controller.state.error} '
            'candidates=${h.controller.state.candidates.map((c) => c.id)} '
            'links=${h.controller.state.links}',
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Fixed GATT objects shared by every harness.
// ---------------------------------------------------------------------------

final GATTCharacteristic rxCharacteristic = GATTCharacteristic.mutable(
  uuid: UUID.fromString(BleProtocol.rxCharacteristicUuid),
  properties: [
    GATTCharacteristicProperty.write,
    GATTCharacteristicProperty.writeWithoutResponse,
  ],
  permissions: [GATTCharacteristicPermission.write],
  descriptors: const [],
);

final GATTCharacteristic txCharacteristic = GATTCharacteristic.mutable(
  uuid: UUID.fromString(BleProtocol.txCharacteristicUuid),
  properties: [GATTCharacteristicProperty.notify],
  permissions: [GATTCharacteristicPermission.read],
  descriptors: const [],
);

final GATTService _beChatService = GATTService(
  uuid: UUID.fromString(BleProtocol.serviceUuid),
  isPrimary: true,
  includedServices: const [],
  characteristics: [rxCharacteristic, txCharacteristic],
);

BlePlatformStatus _grantedBleStatus() {
  return BlePlatformStatus(
    sdkInt: 31,
    scan: true,
    connect: true,
    advertise: true,
    location: false,
    permissionsGranted: true,
    bluetoothEnabled: true,
    leSupported: true,
    advertisingSupported: true,
  );
}

bool _isSecureFrame(Uint8List frame) =>
    frame.length > 1 && frame[1] == BleSecureProtocol.version;

bool _containsBytes(List<int> hay, List<int> needle) {
  if (needle.isEmpty || needle.length > hay.length) return false;
  for (var i = 0; i <= hay.length - needle.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Relay-queue seeding for retry tests (Phase 3D.2B).
// ---------------------------------------------------------------------------

// Parked envelopes are addressed to/from devices this harness never links;
// only the incoming/origin ids are chosen per test (UUID-formatted, like
// every authenticated id in this suite).
const _retryRelayUuid = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';
const _retryDestinationUuid = 'cccccccc-dddd-4eee-8fff-000000000000';

/// Builds a queue row as a completed background forward leaves it: stored
/// bytes from an already-forwarded envelope, an authenticated incoming peer,
/// and an `updated_at` old enough that any backoff window has elapsed.
RelayQueueEntry _parkedEntry({
  required String envelopeId,
  required String origin,
  required String destination,
  required String incomingPeer,
  int hopCount = 1,
}) {
  final created = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
  const content = 'retry';
  final envelope = BleRoutingEnvelope(
    envelopeId: envelopeId,
    originDeviceId: origin,
    destinationDeviceId: destination,
    createdAt: created,
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    hopLimit: 5,
    hopCount: hopCount,
    payload: BleMessagePayload(
      metadata: BleMessageMetadata(
        messageId: 'msg-$envelopeId',
        senderId: origin,
        receiverId: destination,
        messageType: MessageType.text.name,
        timestamp: DateTime.utc(2026, 4, 5, 6, 7),
        ttl: 3600,
        contentLength: content.length,
        isEncrypted: false,
      ),
      content: content,
    ).encode(),
  );
  return RelayQueueEntry(
    envelopeId: envelopeId,
    envelope: envelope.encode(),
    originDeviceId: origin,
    destinationDeviceId: destination,
    incomingPeerDeviceId: incomingPeer,
    expiresAt: envelope.expiresAt,
    hopLimit: 5,
    hopCount: hopCount,
    createdAt: created,
    updatedAt: created,
  );
}

/// Clears and seeds the relay queue in the app database the routing handler
/// actually reads (DatabaseHelper — a file that outlives each test run) and
/// returns it for assertions.
Future<Database> _seedRelayQueue(List<RelayQueueEntry> entries) async {
  // plain flutter test never registers sqflite's global factory.
  databaseFactory = databaseFactoryFfi;
  final db = await DatabaseHelper.database;
  await db.delete('relay_queue');
  for (final entry in entries) {
    await db.insert('relay_queue', entry.toMap());
  }
  return db;
}

// ---------------------------------------------------------------------------
// Harness: one real runtime + real database, faked platform layer.
// ---------------------------------------------------------------------------

class _SecureRuntimeHarness {
  _SecureRuntimeHarness._();

  static Future<_SecureRuntimeHarness> create({
    bool initializeIdentity = true,
    Uint8List? peerKey,
    Duration linkHandshakeTimeout = const Duration(seconds: 2),
    bool nullLocalRoutingIdentity = false,
  }) async {
    final h = _SecureRuntimeHarness._();
    h.db = await openTestDatabase();
    h.identityRepository = IdentityRepository(database: () async => h.db);
    h.peerRepository = PeerRepository(database: () async => h.db);
    h.chatRepository = ChatRepository(database: () async => h.db);
    h.messageRepository = MessageRepository(database: () async => h.db);

    final identity = await h.identityRepository.ensureIdentity();
    h.localIdentity = identity;
    h.localDevice = FakeDevice(
      identity.deviceId,
      'This Device',
      _localKeyBytes,
    );
    h.peerDevice = FakeDevice(
      _peerUuid,
      _authenticatedName,
      peerKey ?? _peerKeyBytes,
    );

    h.gateway = FakeSecureGateway(
      devices: [h.localDevice, h.peerDevice],
      remoteIdentityOverride: (localId) =>
          h.remoteIdentityOverride?.call(localId),
    );
    h.peerGateway = FakeSecureGateway(devices: [h.peerDevice, h.localDevice]);
    h.nativeIdentity = _FakeNativeIdentityGateway(
      publicKeyHex: _localKeyHex,
      fingerprintHex: _fingerprintHex,
    );

    h._stubManagers();
    final overrides = <Override>[
      identityRepositoryProvider.overrideWithValue(h.identityRepository),
      peerRepositoryProvider.overrideWithValue(h.peerRepository),
      chatRepositoryProvider.overrideWithValue(h.chatRepository),
      messageRepositoryProvider.overrideWithValue(h.messageRepository),
      appSettingsRepositoryProvider.overrideWithValue(h.settings),
      backgroundBleServiceProvider.overrideWithValue(h.background),
      secureSessionGatewayProvider.overrideWithValue(h.gateway),
      identityInitializationCoordinatorProvider.overrideWithValue(
        IdentityInitializationCoordinator(
          repository: h.identityRepository,
          nativeIdentity: h.nativeIdentity,
          ensureDatabase: () async {},
          isSupportedPlatform: () => true,
        ),
      ),
      bleRuntimeProvider.overrideWith(
        (ref) => BleRuntimeController(
          ref,
          centralManager: h.central,
          peripheralManager: h.peripheral,
          statusProbe: _FakeStatusProbe(_grantedBleStatus()),
          isAndroidOverride: true,
          availabilityEnabled: true,
          candidateExpiration: const Duration(seconds: 60),
          candidateCleanupInterval: const Duration(seconds: 60),
          linkHandshakeTimeout: linkHandshakeTimeout,
          backgroundBleService: h.background,
        ),
      ),
    ];
    // A test can flip the local routing identity off before the container is
    // built (riverpod forbids adding overrides to a live container).
    if (nullLocalRoutingIdentity) {
      overrides.add(localDeviceIdProvider.overrideWithValue(null));
    }
    h.container = ProviderContainer(overrides: overrides);
    h.controller = h.container.read(bleRuntimeProvider.notifier);
    if (initializeIdentity) await h.initializeIdentity();
    return h;
  }

  late final Database db;
  late final IdentityRepository identityRepository;
  late final PeerRepository peerRepository;
  late final ChatRepository chatRepository;
  late final MessageRepository messageRepository;
  late final Identity localIdentity;
  late final FakeDevice localDevice;
  late final FakeDevice peerDevice;
  late final FakeSecureGateway gateway;
  late final FakeSecureGateway peerGateway;
  late final _FakeNativeIdentityGateway nativeIdentity;
  late final ProviderContainer container;
  late final BleRuntimeController controller;

  final _FakeAppSettingsRepository settings = _FakeAppSettingsRepository();
  final _FakeBackgroundBleService background = _FakeBackgroundBleService();

  final _MockCentralManager central = _MockCentralManager();
  final _MockPeripheralManager peripheral = _MockPeripheralManager();
  final _TestCentral peerCentral = _TestCentral(UUID.fromString(_peerUuid));
  final _TestPeripheral peerPeripheral = _TestPeripheral(
    UUID.fromString(_peerUuid),
  );

  final StreamController<BluetoothLowEnergyStateChangedEventArgs>
  centralStates =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();
  final StreamController<BluetoothLowEnergyStateChangedEventArgs>
  peripheralStates =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();
  final StreamController<DiscoveredEventArgs> discovered =
      StreamController<DiscoveredEventArgs>.broadcast();
  final StreamController<PeripheralConnectionStateChangedEventArgs>
  connections =
      StreamController<PeripheralConnectionStateChangedEventArgs>.broadcast();
  final StreamController<GATTCharacteristicNotifiedEventArgs> notified =
      StreamController<GATTCharacteristicNotifiedEventArgs>.broadcast();
  final StreamController<GATTCharacteristicWriteRequestedEventArgs>
  writeRequests =
      StreamController<GATTCharacteristicWriteRequestedEventArgs>.broadcast();
  final StreamController<GATTCharacteristicNotifyStateChangedEventArgs>
  notifyStates =
      StreamController<
        GATTCharacteristicNotifyStateChangedEventArgs
      >.broadcast();

  /// Frames the runtime wrote toward the peer but has not delivered yet.
  final List<Uint8List> runtimeFrames = [];

  /// Every frame the runtime ever wrote, for whole-test wire assertions.
  final List<Uint8List> runtimeFrameLog = [];

  /// Secure transfer kinds keyed by transfer id, learned from v2 start
  /// frames; unknown kinds are held (fail closed), never misdelivered.
  final Map<int, BleSecureTransferKind> _kindsByTransfer =
      <int, BleSecureTransferKind>{};

  /// Scripts the authenticated identity the runtime-side engine reports
  /// (protocol version / capabilities), for unsupported-peer tests.
  RemoteAuthenticatedIdentity? Function(String localDeviceId)?
  remoteIdentityOverride;

  final _PeerTransport peerTransport = _PeerTransport();
  BleLinkSession? peerSession;

  /// The BLE role of the runtime link the bridge is emulating. Needed
  /// because the runtime publishes `state.activeRole` only at approval or
  /// secure-ready, long after the first peer frames must be routed.
  BleLinkRole? bridgeRole;

  List<Uint8List> get peerFrameLog => peerTransport.frameLog;

  Future<IdentityInitializationStatus> initializeIdentity() async {
    final status = await container
        .read(identityInitializationProvider.notifier)
        .initialize();
    await container.read(identityProvider.notifier).loadIdentity();
    return status;
  }

  void _stubManagers() {
    when(central.state).thenReturn(BluetoothLowEnergyState.poweredOn);
    when(peripheral.state).thenReturn(BluetoothLowEnergyState.poweredOn);
    when(central.stateChanged).thenAnswer((_) => centralStates.stream);
    when(peripheral.stateChanged).thenAnswer((_) => peripheralStates.stream);
    when(central.discovered).thenAnswer((_) => discovered.stream);
    when(central.connectionStateChanged).thenAnswer((_) => connections.stream);
    when(central.characteristicNotified).thenAnswer((_) => notified.stream);
    when(
      peripheral.characteristicWriteRequested,
    ).thenAnswer((_) => writeRequests.stream);
    when(
      peripheral.characteristicNotifyStateChanged,
    ).thenAnswer((_) => notifyStates.stream);
    when(peripheral.connectionStateChanged).thenAnswer(
      (_) => const Stream<CentralConnectionStateChangedEventArgs>.empty(),
    );

    when(central.authorize()).thenAnswer((_) async => true);
    when(peripheral.authorize()).thenAnswer((_) async => true);
    when(
      central.startDiscovery(serviceUUIDs: anyNamed('serviceUUIDs')),
    ).thenAnswer((_) async {});
    when(central.stopDiscovery()).thenAnswer((_) async {});
    when(peripheral.removeAllServices()).thenAnswer((_) async {});
    when(peripheral.addService(any)).thenAnswer((_) async {});
    when(peripheral.startAdvertising(any)).thenAnswer((_) async {});
    when(peripheral.stopAdvertising()).thenAnswer((_) async {});

    when(central.connect(any)).thenAnswer((invocation) async {
      final p = invocation.positionalArguments.first as Peripheral;
      connections.add(
        PeripheralConnectionStateChangedEventArgs(p, ConnectionState.connected),
      );
    });
    when(central.disconnect(any)).thenAnswer((_) async {});
    when(central.discoverGATT(any)).thenAnswer((_) async => [_beChatService]);
    when(
      central.getMaximumWriteLength(any, type: anyNamed('type')),
    ).thenAnswer((_) async => 180);
    when(
      central.setCharacteristicNotifyState(any, any, state: anyNamed('state')),
    ).thenAnswer((_) async {});
    when(central.readRSSI(any)).thenAnswer((_) async => -55);
    when(
      central.writeCharacteristic(
        any,
        any,
        value: anyNamed('value'),
        type: anyNamed('type'),
      ),
    ).thenAnswer((invocation) async {
      _captureRuntimeFrame(invocation.namedArguments[#value] as Uint8List);
    });

    when(peripheral.getMaximumNotifyLength(any)).thenAnswer((_) async => 180);
    when(
      peripheral.notifyCharacteristic(any, any, value: anyNamed('value')),
    ).thenAnswer((invocation) async {
      _captureRuntimeFrame(invocation.namedArguments[#value] as Uint8List);
    });
    when(peripheral.disconnect(any)).thenAnswer((_) async {});
    when(peripheral.respondWriteRequest(any)).thenAnswer((_) async {});
    when(
      peripheral.respondWriteRequestWithError(any, error: anyNamed('error')),
    ).thenAnswer((_) async {});
  }

  void _captureRuntimeFrame(Uint8List value) {
    final frame = Uint8List.fromList(value);
    runtimeFrameLog.add(frame);
    runtimeFrames.add(Uint8List.fromList(frame));
  }

  // -- link choreography ----------------------------------------------------

  /// Creates the peer-side session. Its HELLO advertises the untrusted hint
  /// name; its authenticated identity (as seen by the runtime-side engine)
  /// carries the harness peer device's name and static key.
  BleLinkSession createPeerSession({
    required BleSecureRole role,
    bool secure = true,
    Uint8List? pinnedRemotePublicKey,
    Duration handshakeTimeout = const Duration(seconds: 5),
    Future<BleAckResult> Function(BleRoutingEnvelope envelope)?
    onRoutingEnvelope,
  }) {
    final identity = Identity(
      deviceId: peerDevice.deviceId,
      displayName: _helloName,
      publicKey: hexOf(peerDevice.staticKey),
    );
    final session = BleLinkSession(
      transport: peerTransport,
      identity: identity,
      onHello: (_) async {},
      onMessage: (message) async => BleAckResult.stored,
      onRoutingEnvelope: onRoutingEnvelope,
      handshakeTimeout: handshakeTimeout,
      secure: secure
          ? BleSecureSessionConfig(
              gateway: peerGateway,
              role: role,
              pinnedRemotePublicKey: pinnedRemotePublicKey,
            )
          : null,
    );
    peerSession = session;
    return session;
  }

  /// The peripheral runtime subscribed its TX characteristic: the peer's
  /// central just enabled notifications.
  void announcePeripheralLink() {
    bridgeRole = BleLinkRole.peripheral;
    notifyStates.add(
      GATTCharacteristicNotifyStateChangedEventArgs(
        peerCentral,
        txCharacteristic,
        true,
      ),
    );
  }

  /// Runs the central-role connect flow up to the exchanged HELLO: scan,
  /// discover, connect and the runtime's own session start.
  Future<void> connectAsCentral() async {
    bridgeRole = BleLinkRole.central;
    await controller.ensureStarted();
    await controller.startScan();
    expect(controller.state.status, BleRuntimeStatus.scanning);
    discovered.add(
      DiscoveredEventArgs(
        peerPeripheral,
        -60,
        Advertisement(
          name: _helloName,
          serviceUUIDs: [UUID.fromString(BleProtocol.serviceUuid)],
        ),
      ),
    );
    await pumpUntil(
      () => controller.state.candidates.isNotEmpty,
      reason: 'the candidate never appeared',
    );
    final connecting = controller.connectToCandidate(_peerUuid);
    await pumpUntil(
      () => runtimeFrames.isNotEmpty,
      reason: 'the runtime never wrote its HELLO',
    );
    peerSession!.startFireAndForget();
    await pumpUntil(
      () => gateway.countFor(localDevice.deviceId, 'createSession') >= 1,
      reason: 'the link never reached the handshake',
    );
    final peerId = await connecting;
    expect(peerId, _peerUuid);
    flush();
  }

  /// Auto-approved peripheral link up to the point where the runtime started
  /// its Noise session (requires a saved peer row).
  Future<void> connectAsPeripheralSecureLink() async {
    await controller.ensureStarted();
    announcePeripheralLink();
    await pumpUntil(
      () => runtimeFrames.isNotEmpty,
      reason: 'the runtime never wrote its HELLO',
    );
    await pumpUntil(
      () => gateway.countFor(localDevice.deviceId, 'createSession') >= 1,
      reason: 'the link never reached the handshake',
    );
    await finishSecureHandshake(peerIsInitiator: false);
  }

  /// Drives both sides to secure-ready, then has the test peer confirm its
  /// authenticated identity.
  Future<void> finishSecureHandshake({required bool peerIsInitiator}) async {
    // The peer session can only start the Noise handshake once its own HELLO
    // exchange finished and the secure context is bound (awaitingAuthorization).
    await pumpUntil(
      () =>
          peerSession!.secureState == BleSecureLinkState.awaitingAuthorization,
      reason: 'the peer session never finished its HELLO exchange',
    );
    if (peerIsInitiator) {
      await peerSession!.startSecureHandshake();
    } else {
      unawaited(peerSession!.startSecureHandshake());
    }
    await pumpUntil(
      () => controller.state.isSecureReady,
      reason: 'the link never became secure-ready',
    );
    await pumpUntil(
      () => peerSession!.secureState == BleSecureLinkState.awaitingConfirmation,
      reason: 'the peer session never finished its handshake',
    );
    await peerSession!.confirmSecurePeerIdentity();
    await pumpUntil(() => peerSession!.isSecureReady);
  }

  // -- frame bridge ---------------------------------------------------------

  /// Moves buffered frames across the simulated GATT bridge in both
  /// directions. The secure gate holds frames that the receiving session
  /// cannot lawfully process yet: v1 frames flow freely, v2 handshake frames
  /// flow once the receiver is handshaking, and v2 application frames only
  /// between secure-ready sessions. Held frames are re-evaluated on every
  /// flush.
  void flush() {
    while (runtimeFrames.isNotEmpty) {
      final frame = runtimeFrames.removeAt(0);
      if (!_mayDeliverToPeer(frame)) {
        runtimeFrames.insert(0, frame);
        break;
      }
      peerTransport.deliver(frame);
    }

    final role = bridgeRole ?? controller.state.activeRole;
    for (final frame in peerTransport.takeWrites()) {
      if (role == null) {
        // The runtime has no link yet: hold instead of dropping.
        peerTransport.requeue(frame);
        break;
      }
      if (role == BleLinkRole.peripheral) {
        writeRequests.add(
          GATTCharacteristicWriteRequestedEventArgs(
            peerCentral,
            rxCharacteristic,
            _TestWriteRequest(frame),
          ),
        );
      } else {
        notified.add(
          GATTCharacteristicNotifiedEventArgs(
            peerPeripheral,
            txCharacteristic,
            frame,
          ),
        );
      }
    }
  }

  bool _mayDeliverToPeer(Uint8List frame) {
    if (!_isSecureFrame(frame)) return true;
    final session = peerSession;
    if (session == null) return false;
    final BleSecureTransferKind kind;
    try {
      final decoded = BleSecureFrame.decode(frame);
      if (decoded.type == BleFrameType.start) {
        final start = BleSecureStartPayload.decode(decoded.payload);
        _kindsByTransfer[decoded.transferId] = start.kind;
        kind = start.kind;
      } else {
        final known = _kindsByTransfer[decoded.transferId];
        if (known == null) return false;
        kind = known;
      }
    } on BleProtocolException {
      return false;
    }
    final state = session.secureState;
    switch (kind) {
      case BleSecureTransferKind.secureHandshake:
        return state == BleSecureLinkState.handshaking ||
            state == BleSecureLinkState.awaitingConfirmation ||
            state == BleSecureLinkState.secureReady;
      case BleSecureTransferKind.secureMessage:
      case BleSecureTransferKind.secureAck:
        return state == BleSecureLinkState.secureReady;
    }
  }

  // -- pumping --------------------------------------------------------------

  Future<void> pump() async {
    flush();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    flush();
  }

  Future<void> pumpUntil(
    FutureOr<bool> Function() condition, {
    String? reason,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!(await condition())) {
      flush();
      if (DateTime.now().isAfter(deadline)) {
        fail(
          '${reason ?? 'condition was not met within the deadline'}\n'
          'status=${controller.state.status} '
          'error=${controller.state.error} '
          'role=${controller.state.activeRole} '
          'incoming=${controller.state.incomingRequest?.peerId} '
          'gateway=${gateway.calls} peerCalls=${peerGateway.calls} '
          'runtimeQueued=${runtimeFrames.length} '
          'peerState=${peerSession?.secureState} '
          'peerLink=${peerSession?.state}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    flush();
  }

  // -- database helpers -----------------------------------------------------

  Future<Peer> seedPeer({
    String displayName = 'Stored Name',
    String? publicKeyHex,
  }) async {
    final peer = Peer(
      peerId: _peerUuid,
      displayName: displayName,
      deviceName: displayName,
      status: PeerStatus.offline,
      publicKey: publicKeyHex,
    );
    await peerRepository.upsertPeer(peer);
    return peer;
  }

  Future<void> seedQueuedMessage({required String content}) async {
    final peer = await peerRepository.getPeerByPeerId(_peerUuid);
    final chat = await chatRepository.getOrCreateChatForPeer(peer!);
    final now = DateTime.now();
    await messageRepository.insertMessage(
      Message(
        messageId: 'out-1',
        chatId: chat.chatId,
        senderId: localIdentity.deviceId,
        receiverId: _peerUuid,
        content: content,
        timestamp: now,
        status: MessageStatus.queued,
        transport: MessageTransport.pending,
        // The messages table requires non-null timestamps; insertMessage
        // ignores constraint violations, so a null would vanish silently.
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  MessageStatus? messageStatusSync;
  Future<MessageStatus?> messageStatus(String messageId) async {
    final rows = await db.query(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    final status = rows.isEmpty
        ? null
        : MessageStatus.values.firstWhere(
            (s) => s.name == rows.first['status'],
          );
    messageStatusSync = status;
    return status;
  }

  Future<void> dispose() async {
    // Close everything while the controller is still mounted: the session's
    // close callback runs asynchronously and must not touch a disposed
    // controller.
    final session = peerSession;
    if (session != null && session.state != BleSessionState.idle) {
      // A never-started session has no listener on its HELLO completer;
      // closing it would complete that completer with an unhandled error.
      try {
        await session.close().timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );
      } catch (_) {}
    }
    try {
      await controller.disconnect().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
      await pump();
    } catch (_) {}
    container.dispose();
    await peerTransport.close();
    await centralStates.close();
    await peripheralStates.close();
    await discovered.close();
    await connections.close();
    await notified.close();
    await writeRequests.close();
    await notifyStates.close();
    await db.close();
  }
}

// ---------------------------------------------------------------------------
// Peer-side transport, platform fakes and repositories.
// ---------------------------------------------------------------------------

/// The peer side's GATT transport: writes are captured for the bridge to
/// deliver to the runtime; incoming frames are delivered by the bridge.
class _PeerTransport implements BleTransport {
  _PeerTransport();

  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final List<Uint8List> _writes = [];
  final List<Uint8List> _held = [];

  /// Every frame the peer side ever wrote, for whole-test wire assertions.
  final List<Uint8List> frameLog = [];

  @override
  int get maximumWriteLength => 180;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  void deliver(Uint8List value) {
    if (!_incoming.isClosed) _incoming.add(Uint8List.fromList(value));
  }

  @override
  Future<void> write(Uint8List value) async {
    final frame = Uint8List.fromList(value);
    frameLog.add(frame);
    _writes.add(Uint8List.fromList(frame));
  }

  List<Uint8List> takeWrites() {
    final out = <Uint8List>[..._held, ..._writes];
    _held.clear();
    _writes.clear();
    return out;
  }

  void requeue(Uint8List frame) => _held.insert(0, frame);

  @override
  Future<void> close() async {
    // A never-subscribed single-subscription stream never delivers its done
    // event, so closing it would hang forever.
    if (!_incoming.hasListener) return;
    await _incoming.close();
  }
}

class _TestWriteRequest implements GATTWriteRequest {
  _TestWriteRequest(this.value);

  @override
  final Uint8List value;

  @override
  int get offset => 0;
}

class _TestCentral extends Mock implements Central {
  _TestCentral(this.uuid);

  @override
  final UUID uuid;
}

class _TestPeripheral extends Mock implements Peripheral {
  _TestPeripheral(this.uuid);

  @override
  final UUID uuid;
}

class _MockCentralManager extends Mock implements CentralManager {
  @override
  BluetoothLowEnergyState get state =>
      super.noSuchMethod(
            Invocation.getter(#state),
            returnValue: BluetoothLowEnergyState.unknown,
          )
          as BluetoothLowEnergyState;

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      super.noSuchMethod(
            Invocation.getter(#stateChanged),
            returnValue:
                const Stream<BluetoothLowEnergyStateChangedEventArgs>.empty(),
          )
          as Stream<BluetoothLowEnergyStateChangedEventArgs>;

  @override
  Stream<DiscoveredEventArgs> get discovered =>
      super.noSuchMethod(
            Invocation.getter(#discovered),
            returnValue: const Stream<DiscoveredEventArgs>.empty(),
          )
          as Stream<DiscoveredEventArgs>;

  @override
  Stream<PeripheralConnectionStateChangedEventArgs>
  get connectionStateChanged =>
      super.noSuchMethod(
            Invocation.getter(#connectionStateChanged),
            returnValue:
                const Stream<PeripheralConnectionStateChangedEventArgs>.empty(),
          )
          as Stream<PeripheralConnectionStateChangedEventArgs>;

  @override
  Stream<GATTCharacteristicNotifiedEventArgs> get characteristicNotified =>
      super.noSuchMethod(
            Invocation.getter(#characteristicNotified),
            returnValue:
                const Stream<GATTCharacteristicNotifiedEventArgs>.empty(),
          )
          as Stream<GATTCharacteristicNotifiedEventArgs>;

  @override
  Future<bool> authorize() =>
      super.noSuchMethod(
            Invocation.method(#authorize, []),
            returnValue: Future<bool>.value(false),
          )
          as Future<bool>;

  @override
  Future<void> startDiscovery({List<UUID>? serviceUUIDs}) =>
      super.noSuchMethod(
            Invocation.method(#startDiscovery, [], {
              #serviceUUIDs: serviceUUIDs,
            }),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> stopDiscovery() =>
      super.noSuchMethod(
            Invocation.method(#stopDiscovery, []),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> connect(Peripheral? peripheral) =>
      super.noSuchMethod(
            Invocation.method(#connect, [peripheral]),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> disconnect(Peripheral? peripheral) =>
      super.noSuchMethod(
            Invocation.method(#disconnect, [peripheral]),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<List<GATTService>> discoverGATT(Peripheral? peripheral) =>
      super.noSuchMethod(
            Invocation.method(#discoverGATT, [peripheral]),
            returnValue: Future<List<GATTService>>.value(const <GATTService>[]),
          )
          as Future<List<GATTService>>;

  @override
  Future<int> getMaximumWriteLength(
    Peripheral? peripheral, {
    required GATTCharacteristicWriteType? type,
  }) =>
      super.noSuchMethod(
            Invocation.method(
              #getMaximumWriteLength,
              [peripheral],
              {#type: type},
            ),
            returnValue: Future<int>.value(180),
          )
          as Future<int>;

  @override
  Future<int> readRSSI(Peripheral? peripheral) =>
      super.noSuchMethod(
            Invocation.method(#readRSSI, [peripheral]),
            returnValue: Future<int>.value(-55),
          )
          as Future<int>;

  @override
  Future<void> setCharacteristicNotifyState(
    Peripheral? peripheral,
    GATTCharacteristic? characteristic, {
    required bool? state,
  }) =>
      super.noSuchMethod(
            Invocation.method(
              #setCharacteristicNotifyState,
              [peripheral, characteristic],
              {#state: state},
            ),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> writeCharacteristic(
    Peripheral? peripheral,
    GATTCharacteristic? characteristic, {
    required Uint8List? value,
    required GATTCharacteristicWriteType? type,
  }) =>
      super.noSuchMethod(
            Invocation.method(
              #writeCharacteristic,
              [peripheral, characteristic],
              {#value: value, #type: type},
            ),
            returnValue: Future<void>.value(),
          )
          as Future<void>;
}

class _MockPeripheralManager extends Mock implements PeripheralManager {
  @override
  BluetoothLowEnergyState get state =>
      super.noSuchMethod(
            Invocation.getter(#state),
            returnValue: BluetoothLowEnergyState.unknown,
          )
          as BluetoothLowEnergyState;

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      super.noSuchMethod(
            Invocation.getter(#stateChanged),
            returnValue:
                const Stream<BluetoothLowEnergyStateChangedEventArgs>.empty(),
          )
          as Stream<BluetoothLowEnergyStateChangedEventArgs>;

  @override
  Stream<GATTCharacteristicWriteRequestedEventArgs>
  get characteristicWriteRequested =>
      super.noSuchMethod(
            Invocation.getter(#characteristicWriteRequested),
            returnValue:
                const Stream<GATTCharacteristicWriteRequestedEventArgs>.empty(),
          )
          as Stream<GATTCharacteristicWriteRequestedEventArgs>;

  @override
  Stream<GATTCharacteristicNotifyStateChangedEventArgs>
  get characteristicNotifyStateChanged =>
      super.noSuchMethod(
            Invocation.getter(#characteristicNotifyStateChanged),
            returnValue:
                const Stream<
                  GATTCharacteristicNotifyStateChangedEventArgs
                >.empty(),
          )
          as Stream<GATTCharacteristicNotifyStateChangedEventArgs>;

  @override
  Stream<CentralConnectionStateChangedEventArgs> get connectionStateChanged =>
      super.noSuchMethod(
            Invocation.getter(#connectionStateChanged),
            returnValue:
                const Stream<CentralConnectionStateChangedEventArgs>.empty(),
          )
          as Stream<CentralConnectionStateChangedEventArgs>;

  @override
  Future<bool> authorize() =>
      super.noSuchMethod(
            Invocation.method(#authorize, []),
            returnValue: Future<bool>.value(false),
          )
          as Future<bool>;

  @override
  Future<void> removeAllServices() =>
      super.noSuchMethod(
            Invocation.method(#removeAllServices, []),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> addService(GATTService? service) =>
      super.noSuchMethod(
            Invocation.method(#addService, [service]),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> startAdvertising(Advertisement? advertisement) =>
      super.noSuchMethod(
            Invocation.method(#startAdvertising, [advertisement]),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> stopAdvertising() =>
      super.noSuchMethod(
            Invocation.method(#stopAdvertising, []),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> disconnect(Central? central) =>
      super.noSuchMethod(
            Invocation.method(#disconnect, [central]),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<int> getMaximumNotifyLength(Central? central) =>
      super.noSuchMethod(
            Invocation.method(#getMaximumNotifyLength, [central]),
            returnValue: Future<int>.value(180),
          )
          as Future<int>;

  @override
  Future<void> notifyCharacteristic(
    Central? central,
    GATTCharacteristic? characteristic, {
    required Uint8List? value,
  }) =>
      super.noSuchMethod(
            Invocation.method(
              #notifyCharacteristic,
              [central, characteristic],
              {#value: value},
            ),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> respondWriteRequest(GATTWriteRequest? request) =>
      super.noSuchMethod(
            Invocation.method(#respondWriteRequest, [request]),
            returnValue: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> respondWriteRequestWithError(
    GATTWriteRequest? request, {
    required GATTError? error,
  }) =>
      super.noSuchMethod(
            Invocation.method(
              #respondWriteRequestWithError,
              [request],
              {#error: error},
            ),
            returnValue: Future<void>.value(),
          )
          as Future<void>;
}

class _FakeStatusProbe implements BleStatusProbe {
  _FakeStatusProbe(this.status);

  BlePlatformStatus status;
  Object? error;
  int calls = 0;

  @override
  Future<BlePlatformStatus> getStatus() async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return status;
  }
}

/// Stands in for the native identity backend: a fresh install that
/// provisions once and then reports a stable ready identity.
class _FakeNativeIdentityGateway implements NativeIdentityGateway {
  _FakeNativeIdentityGateway({
    required this.publicKeyHex,
    required this.fingerprintHex,
  });

  final String publicKeyHex;
  final String fingerprintHex;

  int initializeCalls = 0;
  bool ready = false;

  NativeIdentityStatus get _readyStatus => NativeIdentityStatus(
    state: NativeIdentityState.ready,
    publicKeyHex: publicKeyHex,
    fingerprintHex: fingerprintHex,
  );

  @override
  Future<NativeIdentityStatus> initialize() async {
    initializeCalls++;
    ready = true;
    return _readyStatus;
  }

  @override
  Future<NativeIdentityStatus> status() async {
    if (!ready) {
      return const NativeIdentityStatus(
        state: NativeIdentityState.uninitialized,
      );
    }
    return _readyStatus;
  }
}

class _FakeAppSettingsRepository extends AppSettingsRepository {
  bool bleEnabled = true;
  bool backgroundBleEnabled = false;
  bool messagePreviewsEnabled = false;

  @override
  Future<AppSettings> loadSettings() async {
    return AppSettings(
      bleEnabled: bleEnabled,
      backgroundBleEnabled: backgroundBleEnabled,
      messagePreviewsEnabled: messagePreviewsEnabled,
    );
  }

  @override
  Future<bool> getBleEnabled() async => bleEnabled;

  @override
  Future<bool> getAllowNewConnections() async => true;

  @override
  Future<bool> getBackgroundBleEnabled() async => backgroundBleEnabled;

  @override
  Future<bool> getMessagePreviewsEnabled() async => messagePreviewsEnabled;

  @override
  Future<void> setBleEnabled(bool value) async {
    bleEnabled = value;
  }

  @override
  Future<void> setBackgroundBleEnabled(bool value) async {
    backgroundBleEnabled = value;
  }

  @override
  Future<void> setMessagePreviewsEnabled(bool value) async {
    messagePreviewsEnabled = value;
  }
}

class _FakeBackgroundBleService implements BackgroundBleService {
  final StreamController<BackgroundBleEvent> _events =
      StreamController<BackgroundBleEvent>.broadcast();

  bool supported = true;
  bool notificationsAllowed = true;
  bool serviceRunning = false;

  @override
  Stream<BackgroundBleEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<BackgroundBlePlatformStatus> getStatus() async {
    return BackgroundBlePlatformStatus(
      supported: supported,
      notificationsAllowed: notificationsAllowed,
      serviceRunning: serviceRunning,
    );
  }

  @override
  Future<bool> requestNotificationPermission() async => notificationsAllowed;

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Future<void> startService({required String statusText}) async {
    serviceRunning = true;
  }

  @override
  Future<void> updateService({required String statusText}) async {}

  @override
  Future<void> stopService() async {
    serviceRunning = false;
  }

  @override
  Future<void> showMessageNotification({
    required String messageId,
    required String chatId,
    required String senderName,
    required String body,
  }) async {}

  @override
  Future<void> showConnectionRequestNotification({
    required String requestId,
    required String peerName,
  }) async {}

  @override
  Future<void> cancelConnectionRequestNotification(String requestId) async {}
}

extension on BleLinkSession {
  /// Starts the HELLO exchange without awaiting it, absorbing the expected
  /// fail-closed errors so no unhandled async error escapes the test.
  void startFireAndForget() {
    unawaited(() async {
      try {
        await start();
      } catch (_) {
        // Fail-closed paths close the session; the test asserts the runtime
        // state instead.
      }
    }());
  }
}
