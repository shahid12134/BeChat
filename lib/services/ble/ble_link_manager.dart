import 'dart:async';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_link_phase.dart';
import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/services/ble/ble_gatt_operation_gate.dart';
import 'package:bechat/services/ble/ble_presence_monitor.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Maximum number of simultaneous BLE links this build maintains.
///
/// Deliberately conservative and aligned with the native Noise engine's
/// session capacity (`MAX_SESSIONS = 8` in `native/crypto_core/src/session.rs`)
/// so the Dart link limit and the native session limit always agree: the
/// runtime never accepts a link it could not secure. A link that has not
/// started its Noise handshake (still awaiting approval) occupies a link slot
/// but no native session slot, which is why the two limits only need to match
/// at their maximum.
const int bleMaxLinkCount = 8;

/// One independent BLE link to one peer.
///
/// Bundles everything the runtime needs to manage a single connection in
/// isolation: its own transport, its own serialized GATT operation gate, its
/// own [BleLinkSession] (which owns that link's Noise session), its own
/// presence monitor, its own handshake and HELLO deadlines, and its own
/// pending inbound writes. Every field here is per-link: closing or failing
/// one [BlePeerLink] never mutates another.
class BlePeerLink {
  BlePeerLink({
    required this.linkId,
    required this.role,
    this.peripheral,
    this.central,
    this.transport,
    this.session,
    this.peerId,
    this.remoteDeviceName,
    this.remoteDisplayName,
    this.remoteRssi,
    this.effectiveWriteLength,
    BleGattOperationGate? gate,
    required this.createdAt,
  }) : gate = gate ?? BleGattOperationGate();

  /// Unique per-connection key: the platform BLE device address of the
  /// remote side. Stable from connection setup until teardown, so events
  /// (writes, notifications, disconnects) always route to the right link
  /// even before the peer's BeChat device ID is known.
  final String linkId;

  final BleLinkRole role;

  /// Remote peripheral, present for outgoing (central-role) links.
  final Peripheral? peripheral;

  /// Remote central, present for incoming (peripheral-role) links.
  final Central? central;

  /// This link's own transport, created once the GATT connection exists.
  ///
  /// Mutable because it is attached after the link is registered (capacity is
  /// enforced at registration, before the connection completes).
  BleTransport? transport;

  /// This link's own session, created once the transport is ready.
  BleLinkSession? session;

  /// This link's serialized GATT operation queue. Every link owns its own
  /// gate: one link's slow GATT operation never blocks another link.
  final BleGattOperationGate gate;

  /// Authenticated BeChat peer device ID, bound after the HELLO exchange
  /// (an unauthenticated hint until the Noise handshake authenticates it).
  String? peerId;

  /// The approved peer context bound to this link after the connection
  /// decision (accept or auto-approve), holding the stored identity and
  /// pinned key this link's handshake must validate against. Per link, so
  /// one peer's approval can never be applied to another link.
  Peer? boundPeer;

  /// Best-known remote device name: scan-time or GATT name, a hint only.
  String? remoteDeviceName;

  /// Best-known peer display name: the approved or authenticated name once
  /// the HELLO exchange or the Noise handshake produced one, otherwise the
  /// scan-time hint. Never key material.
  String? remoteDisplayName;

  /// Latest observed signal strength for this link.
  int? remoteRssi;

  /// This link's negotiated effective GATT write limit in bytes.
  int? effectiveWriteLength;

  /// Timer for the runtime-level secure-handshake deadline of this link.
  Timer? handshakeTimer;

  /// Timer for this link's pre-secure HELLO deadline (outgoing links).
  Timer? helloTimer;

  /// Inbound writes received from the remote central before its link session
  /// exists, buffered per link and replayed into the transport on session
  /// creation.
  final List<Uint8List> pendingWrites = [];

  final DateTime createdAt;

  /// Whether the link still holds live resources that cleanup must release.
  bool isClosed = false;

  BlePeerLinkState? toState({required DateTime updatedAt}) {
    final id = peerId;
    if (id == null) return null;
    return BlePeerLinkState(
      peerId: id,
      phase: phase,
      role: role,
      displayName: remoteDisplayName ?? remoteDeviceName,
      deviceName: remoteDeviceName,
      signalStrength: remoteRssi,
      effectiveWriteLength: effectiveWriteLength,
      updatedAt: updatedAt,
    );
  }

  /// Current phase derived from this link's own session and lifecycle flags.
  ///
  /// Mirrors the single-link state machine exactly: only a session whose
  /// Noise handshake finished and whose identity was explicitly confirmed
  /// reports [BleLinkPhase.secureReady]; nothing else ever does.
  BleLinkPhase get phase {
    if (isClosed) return BleLinkPhase.closed;
    final session = this.session;
    if (session == null) return BleLinkPhase.connecting;
    if (session.secure == null) {
      // Legacy v1 session: ready means connected, else still connecting.
      return session.isReady
          ? BleLinkPhase.secureReady
          : BleLinkPhase.connecting;
    }
    return switch (session.secureState) {
      // A null secure state means the secure half has not been created yet,
      // which is still the connecting phase.
      null => BleLinkPhase.connecting,
      BleSecureLinkState.idle => BleLinkPhase.connecting,
      BleSecureLinkState.awaitingAuthorization =>
        BleLinkPhase.awaitingAuthorization,
      BleSecureLinkState.handshaking => BleLinkPhase.handshaking,
      BleSecureLinkState.awaitingConfirmation =>
        BleLinkPhase.awaitingConfirmation,
      BleSecureLinkState.secureReady => BleLinkPhase.secureReady,
      BleSecureLinkState.failed => BleLinkPhase.failed,
      BleSecureLinkState.closed => BleLinkPhase.closed,
    };
  }

  /// Releases this link's own resources: presence monitor, handshake timers
  /// and GATT gate. Never touches any other link. The session close and the
  /// platform disconnect are the caller's responsibility, because they are
  /// role- and platform-specific.
  void release() {
    isClosed = true;
    presenceMonitor?.stop();
    presenceMonitor = null;
    presenceGeneration++;
    handshakeTimer?.cancel();
    handshakeTimer = null;
    helloTimer?.cancel();
    helloTimer = null;
    gate.close();
  }

  /// Per-link presence monitor, one per secure central-role link.
  BlePresenceMonitor? presenceMonitor;

  /// Generation counter guarding late presence callbacks of this link.
  int presenceGeneration = 0;
}

/// Registry of the device's independent BLE links.
///
/// Owns link identity, capacity and lookup only — per-link protocol logic
/// (handshake, approval, secure publication) stays in the session and the
/// runtime controller, keeping this class small. Links are keyed by BLE
/// device address ([BlePeerLink.linkId]); the peer-ID index resolves a link
/// for message delivery. Closing or failing one link never mutates another.
class BleLinkManager {
  BleLinkManager({this.maxLinks = bleMaxLinkCount});

  final int maxLinks;

  final Map<String, BlePeerLink> _links = {};
  final Map<String, String> _linkIdByPeerId = {};

  /// All live links, keyed by BLE device address.
  Map<String, BlePeerLink> get links => Map.unmodifiable(_links);

  int get length => _links.length;

  bool get isFull => _links.length >= maxLinks;

  bool get isEmpty => _links.isEmpty;

  /// Whether any live link has reached the secure-ready phase — the only
  /// phase that counts as connected for delivery and presence.
  bool get hasSecureLink {
    for (final link in _links.values) {
      if (link.phase == BleLinkPhase.secureReady) return true;
    }
    return false;
  }

  BlePeerLink? byLinkId(String linkId) => _links[linkId];

  /// The link bound to [peerId], if one exists.
  BlePeerLink? byPeerId(String peerId) {
    final linkId = _linkIdByPeerId[peerId];
    return linkId == null ? null : _links[linkId];
  }

  bool hasPeer(String peerId) => _linkIdByPeerId.containsKey(peerId);

  /// Registers [link], enforcing the capacity bound.
  ///
  /// Fails (returns false) without side effects when the device already holds
  /// a link to the same peer or the link limit is reached, so the caller can
  /// fail closed — reject the incoming central or abort the outgoing connect
  /// — instead of silently sharing or evicting a live link.
  bool add(BlePeerLink link) {
    if (_links.containsKey(link.linkId)) return false;
    if (isFull) return false;
    final peerId = link.peerId;
    if (peerId != null && _linkIdByPeerId.containsKey(peerId)) return false;
    _links[link.linkId] = link;
    if (peerId != null) _linkIdByPeerId[peerId] = link.linkId;
    return true;
  }

  /// Binds the authenticated-or-hinted peer identity to this link, keeping
  /// the peer index consistent. Refuses to steal a peer already bound to a
  /// different live link, so two links can never claim one peer.
  bool bindPeer(BlePeerLink link, String peerId) {
    if (_links[link.linkId] == null || link.isClosed) return false;
    final existingLinkId = _linkIdByPeerId[peerId];
    if (existingLinkId != null && existingLinkId != link.linkId) return false;
    link.peerId = peerId;
    _linkIdByPeerId[peerId] = link.linkId;
    return true;
  }

  /// Removes [link] and releases its resources. Returns the removed link, or
  /// null when it was already gone. Other links are untouched.
  BlePeerLink? remove(BlePeerLink link) {
    final removed = _links.remove(link.linkId);
    if (removed == null) return null;
    final peerId = removed.peerId;
    if (peerId != null && _linkIdByPeerId[peerId] == link.linkId) {
      _linkIdByPeerId.remove(peerId);
    }
    removed.release();
    return removed;
  }

  /// Removes every link, releasing each one's resources independently.
  List<BlePeerLink> removeAll() {
    final removed = _links.values.toList();
    _links.clear();
    _linkIdByPeerId.clear();
    for (final link in removed) {
      link.release();
    }
    return removed;
  }

  /// Snapshots of every link whose peer identity is known, newest first.
  List<BlePeerLinkState> states({required DateTime now}) {
    final states = <BlePeerLinkState>[];
    for (final link in _links.values) {
      final snapshot = link.toState(updatedAt: now);
      if (snapshot != null) states.add(snapshot);
    }
    states.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return states;
  }
}
