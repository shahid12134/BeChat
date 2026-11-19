import 'dart:async';
import 'dart:io';

import 'package:bechat/core/ble/ble_link_phase.dart';
import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_routing_envelope.dart';
import 'package:bechat/core/ble/ble_secure_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/core/ble/peer_presence.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/core/utils/error_formatter.dart';
import 'package:bechat/core/utils/key_format.dart';
import 'package:bechat/data/models/ble_candidate.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/providers/app_settings_providers.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/identity_initialization_providers.dart';
import 'package:bechat/providers/message_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/providers/secure_session_providers.dart';
import 'package:bechat/providers/settings_providers.dart';
import 'package:bechat/providers/background_service_provider.dart';
import 'package:bechat/services/background/background_ble_service.dart';
import 'package:bechat/services/crypto/identity_initialization_coordinator.dart';
import 'package:bechat/services/crypto/native_secure_session_service.dart';
import 'package:bechat/core/ble/ble_routing_handler.dart';
import 'package:bechat/data/repositories/routing_repository.dart';
import 'package:bechat/services/ble/ble_gatt_operation_gate.dart';
import 'package:bechat/services/ble/ble_link_manager.dart';
import 'package:bechat/services/ble/ble_message_store.dart';
import 'package:bechat/services/ble/ble_outbox.dart';
import 'package:bechat/services/ble/ble_presence_monitor.dart';
import 'package:bechat/services/ble/ble_status_probe.dart';
import 'package:bechat/services/ble/incoming_connection_policy.dart';
import 'package:bechat/services/ble/incoming_connection_request.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

/// The BLE link role is defined at core level so the link manager can use it
/// without importing the runtime; re-exported here so existing imports of
/// this file keep working unchanged.
export 'package:bechat/core/ble/ble_link_phase.dart' show BleLinkRole;

enum BleRuntimeStatus {
  idle,
  unsupported,
  unauthorized,
  bluetoothOff,
  starting,
  ready,
  scanning,
  connecting,
  connected,
  error,
}

/// The BLE link role is defined at core level so the link manager can use it
/// without importing the runtime; re-exported here so existing imports of
/// this file keep working unchanged.
enum BackgroundBleRuntimeStatus {
  disabled,
  starting,
  active,
  paused,
  permissionDenied,
  error,
}

class BackgroundBleToggleResult {
  const BackgroundBleToggleResult.success({this.message})
    : succeeded = true,
      permissionDenied = false;

  const BackgroundBleToggleResult.failure({
    required this.message,
    this.permissionDenied = false,
  }) : succeeded = false;

  final bool succeeded;
  final bool permissionDenied;
  final String? message;
}

/// Runs [operation] again after a transient failure, up to [maxAttempts].
///
/// Re-throws the last error with its original stack trace when every attempt
/// fails, so callers can still surface the underlying platform message.
Future<T> retryBleOperation<T>(
  Future<T> Function() operation, {
  int maxAttempts = 3,
  Duration Function(int attempt)? delay,
}) async {
  Object? lastError;
  StackTrace? lastStackTrace;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await operation();
    } catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
      if (attempt == maxAttempts) break;
      if (delay != null) {
        await Future<void>.delayed(delay(attempt));
      }
    }
  }
  Error.throwWithStackTrace(lastError!, lastStackTrace!);
}

class BleRuntimeState {
  const BleRuntimeState({
    this.status = BleRuntimeStatus.idle,
    this.candidates = const [],
    this.activePeerId,
    this.activePeerName,
    this.activeRole,
    this.error,
    this.canOpenSettings = false,
    this.isAdvertising = false,
    this.incomingRequest,
    this.isForeground = true,
    this.backgroundStatus = BackgroundBleRuntimeStatus.disabled,
    this.backgroundError,
    this.availabilityEnabled = true,
    this.activeSignalStrength,
    this.isSecureReady = false,
    this.links = const [],
    this.incomingRequests = const [],
  });

  final BleRuntimeStatus status;
  final List<BleCandidate> candidates;
  final String? activePeerId;
  final String? activePeerName;
  final BleLinkRole? activeRole;
  final String? error;
  final bool canOpenSettings;
  final bool isAdvertising;

  /// The most recent pending incoming connection request, kept as the
  /// compatibility view for the single-request UI. The authoritative
  /// collection is [incomingRequests], which may hold several simultaneous
  /// requests from different peers.
  final IncomingConnectionRequest? incomingRequest;
  final bool isForeground;
  final BackgroundBleRuntimeStatus backgroundStatus;
  final String? backgroundError;
  final bool availabilityEnabled;
  final int? activeSignalStrength;

  /// True only when the active link's Noise session finished its handshake,
  /// passed the peer-key policy and was explicitly confirmed by the native
  /// engine — the single condition under which the peer may be shown as a
  /// secure connection, marked online, or served from the outbox. Always
  /// false while an approval request, handshake or reconnect is outstanding,
  /// and cleared whenever the active link is torn down. Legacy v1 links never
  /// set it. Compatibility view over [links]; per-peer truth is each link's
  /// own phase.
  final bool isSecureReady;

  /// Snapshot of every managed link, one entry per peer, so the UI can show
  /// all connections with their independent phases at once. A peer missing
  /// from this list has no managed link. Only entries whose phase is
  /// [BleLinkPhase.secureReady] are connected for delivery and presence.
  final List<BlePeerLinkState> links;

  /// Every pending incoming connection request, each independently
  /// acceptable, deniable, blockable or expiring. [incomingRequest] is the
  /// most recent of these for compatibility.
  final List<IncomingConnectionRequest> incomingRequests;

  bool get isConnected =>
      status == BleRuntimeStatus.connected && activePeerId != null;

  /// Whether at least one managed link is secure-ready.
  bool get hasSecureLink => links.any((link) => link.isSecureReady);

  /// The link state for [peerId], or null when this device holds no link to
  /// that peer.
  BlePeerLinkState? linkFor(String peerId) {
    for (final link in links) {
      if (link.peerId == peerId) return link;
    }
    return null;
  }

  /// Whether [peerId]'s link is secure-ready — the only state in which that
  /// peer may be treated as connected for secure message delivery.
  bool isPeerSecureReady(String peerId) =>
      linkFor(peerId)?.isSecureReady ?? false;

  bool get isBackgroundServiceActive =>
      backgroundStatus == BackgroundBleRuntimeStatus.active;

  /// Presence facts for every saved peer, derived from each peer's own link.
  ///
  /// A peer is online only when its own link is secure-ready; a peer with a
  /// pending approval request shows "approval needed"; every other live link
  /// phase (connecting, handshaking, awaiting confirmation) reads as
  /// "connecting". Peers without a link are offline regardless of how many
  /// other links this device holds. The single-active-peer fields are still
  /// published for the legacy single-link path.
  PeerPresenceContext get presenceContext {
    final approvalPeerIds = <String>{};
    for (final request in incomingRequests) {
      approvalPeerIds.add(request.peerId);
    }
    final securePeerIds = <String>{};
    final handshakingPeerIds = <String>{};
    for (final link in links) {
      final id = link.peerId;
      if (id == null) continue;
      switch (link.phase) {
        case BleLinkPhase.secureReady:
          securePeerIds.add(id);
        case BleLinkPhase.connecting:
        case BleLinkPhase.handshaking:
        case BleLinkPhase.awaitingConfirmation:
          handshakingPeerIds.add(id);
        case BleLinkPhase.awaitingAuthorization:
          // A link awaiting this device's approval is covered by its pending
          // request; any other awaiting link (an outgoing link waiting for
          // the remote's approval) still reads as connecting.
          if (!approvalPeerIds.contains(id)) handshakingPeerIds.add(id);
        case BleLinkPhase.disconnecting:
        case BleLinkPhase.failed:
        case BleLinkPhase.closed:
          break;
      }
    }
    return PeerPresenceContext(
      availabilityEnabled: availabilityEnabled,
      localUnavailable:
          status == BleRuntimeStatus.unsupported ||
          status == BleRuntimeStatus.unauthorized ||
          status == BleRuntimeStatus.bluetoothOff,
      connected: isConnected,
      connecting: status == BleRuntimeStatus.connecting,
      activePeerId: activePeerId,
      awaitingApprovalPeerId: incomingRequest?.peerId,
      securePeerIds: securePeerIds,
      awaitingApprovalPeerIds: approvalPeerIds,
      handshakingPeerIds: handshakingPeerIds,
    );
  }

  BleRuntimeState copyWith({
    BleRuntimeStatus? status,
    List<BleCandidate>? candidates,
    String? activePeerId,
    String? activePeerName,
    BleLinkRole? activeRole,
    String? error,
    bool? canOpenSettings,
    bool? isAdvertising,
    IncomingConnectionRequest? incomingRequest,
    bool? isForeground,
    BackgroundBleRuntimeStatus? backgroundStatus,
    String? backgroundError,
    bool? availabilityEnabled,
    int? activeSignalStrength,
    bool? isSecureReady,
    List<BlePeerLinkState>? links,
    List<IncomingConnectionRequest>? incomingRequests,
    bool clearActiveLink = false,
    bool clearError = false,
    bool clearIncomingRequest = false,
    bool clearBackgroundError = false,
    bool clearActiveSignal = false,
  }) {
    final explicitRequests = incomingRequests;
    final resolvedIncomingRequests = explicitRequests ?? this.incomingRequests;
    return BleRuntimeState(
      status: status ?? this.status,
      candidates: candidates ?? this.candidates,
      activePeerId: clearActiveLink ? null : activePeerId ?? this.activePeerId,
      activePeerName: clearActiveLink
          ? null
          : activePeerName ?? this.activePeerName,
      activeRole: clearActiveLink ? null : activeRole ?? this.activeRole,
      error: clearError ? null : error ?? this.error,
      canOpenSettings: canOpenSettings ?? this.canOpenSettings,
      isAdvertising: isAdvertising ?? this.isAdvertising,
      // The single-request compatibility view always tracks the authoritative
      // collection: whenever the collection is updated, the view is the
      // newest pending request, or none.
      incomingRequest: clearIncomingRequest
          ? null
          : incomingRequest ??
                (explicitRequests != null
                    ? resolvedIncomingRequests.lastOrNull
                    : this.incomingRequest),
      incomingRequests: clearIncomingRequest
          ? const []
          : resolvedIncomingRequests,
      isForeground: isForeground ?? this.isForeground,
      backgroundStatus: backgroundStatus ?? this.backgroundStatus,
      backgroundError: clearBackgroundError
          ? null
          : backgroundError ?? this.backgroundError,
      availabilityEnabled: availabilityEnabled ?? this.availabilityEnabled,
      activeSignalStrength: clearActiveLink || clearActiveSignal
          ? null
          : activeSignalStrength ?? this.activeSignalStrength,
      // Tearing the link down always drops secure readiness with it, so a
      // replacement connection can never inherit a previous session's
      // secure-ready publication.
      isSecureReady: clearActiveLink
          ? false
          : isSecureReady ?? this.isSecureReady,
      links: links ?? this.links,
    );
  }
}

/// One pending incoming connection request together with the link it belongs
/// to.
///
/// Each pending request owns its session, its peer identity hint and its own
/// expiry timer, so several peers can await approval simultaneously and one
/// decision (accept, deny, block, timeout) can never act on another peer's
/// request.
class _PendingIncomingRequest {
  _PendingIncomingRequest({
    required this.request,
    required this.linkId,
    required this.session,
    required this.timer,
  });

  final IncomingConnectionRequest request;
  final String linkId;
  final BleLinkSession session;
  final Timer timer;
}

class BleRuntimeController extends StateNotifier<BleRuntimeState> {
  BleRuntimeController(
    this._ref, {
    CentralManager? centralManager,
    PeripheralManager? peripheralManager,
    BleStatusProbe? statusProbe,
    Duration permissionTimeout = const Duration(seconds: 20),
    bool? isAndroidOverride,
    bool availabilityEnabled = AppConstants.defaultBleEnabled,
    Duration candidateExpiration = AppConstants.candidateExpiration,
    Duration candidateCleanupInterval = AppConstants.candidateCleanupInterval,
    DateTime Function()? clock,
    BackgroundBleService? backgroundBleService,
    Duration linkHandshakeTimeout = const Duration(seconds: 15),
  }) : _centralOverride = centralManager,
       _peripheralOverride = peripheralManager,
       _statusProbe = statusProbe ?? MethodChannelBleStatusProbe(),
       _backgroundOverride = backgroundBleService,
       _permissionTimeout = permissionTimeout,
       _isAndroidOverride = isAndroidOverride,
       _availabilityEnabled = availabilityEnabled,
       _candidateExpiration = candidateExpiration,
       _candidateCleanupInterval = candidateCleanupInterval,
       _clock = clock ?? DateTime.now,
       _linkHandshakeTimeout = linkHandshakeTimeout,
       super(BleRuntimeState(availabilityEnabled: availabilityEnabled)) {
    _outbox = BleOutbox(
      repository: _ref.read(messageRepositoryProvider),
      send: _sendOverLink,
      isLinkUsable: _isLinkUsable,
      onChanged: _refreshMessageStatus,
      retryDelay: (attempt) =>
          Duration(milliseconds: 750 * (1 << (attempt - 1).clamp(0, 3))),
    );
  }

  final Ref _ref;
  final CentralManager? _centralOverride;
  final PeripheralManager? _peripheralOverride;
  final BleStatusProbe _statusProbe;
  final Duration _permissionTimeout;

  /// Upper bound on the whole secure handshake started by this runtime.
  ///
  /// The link session arms its own internal handshake timer; this deadline is
  /// the runtime-level backstop that also covers the approval-to-handshake
  /// window on the accepting side. Short values are injected by tests instead
  /// of waiting production intervals.
  final Duration _linkHandshakeTimeout;
  final bool? _isAndroidOverride;
  final Duration _candidateExpiration;
  final Duration _candidateCleanupInterval;
  final DateTime Function() _clock;
  final BackgroundBleService? _backgroundOverride;
  CentralManager? _centralInstance;
  PeripheralManager? _peripheralInstance;
  late final BleOutbox _outbox;

  CentralManager get _central =>
      _centralInstance ??= _centralOverride ?? CentralManager();
  PeripheralManager get _peripheral =>
      _peripheralInstance ??= _peripheralOverride ?? PeripheralManager();

  BackgroundBleService get _backgroundService =>
      _backgroundOverride ?? _ref.read(backgroundBleServiceProvider);

  bool get _backgroundRuntimeActive =>
      _availabilityEnabled &&
      _backgroundBleEnabled &&
      _backgroundServiceRunning &&
      state.backgroundStatus == BackgroundBleRuntimeStatus.active;

  bool get _canContinueBle =>
      _foreground || (_backgroundRuntimeActive && _initialized);

  final UUID _serviceUuid = UUID.fromString(BleProtocol.serviceUuid);
  final UUID _rxUuid = UUID.fromString(BleProtocol.rxCharacteristicUuid);
  final UUID _txUuid = UUID.fromString(BleProtocol.txCharacteristicUuid);

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, Peripheral> _candidatesById = {};
  final Map<String, Completer<void>> _connectionWaiters = {};

  Timer? _scanTimer;
  Timer? _candidateCleanupTimer;

  /// Periodic safety net for parked relay envelopes whose retry needs no new
  /// link event (Phase 3D.2B). Half the 60s backoff cap, so an eligible
  /// envelope waits at most ~90s for a tick.
  static const Duration _relayRetryInterval = Duration(seconds: 30);
  Timer? _relayRetryTimer;

  /// Every managed link, keyed by BLE device address. All per-link state
  /// (session, gate, presence, timers, pending writes, peer binding) lives
  /// on the [BlePeerLink] itself, so one peer's lifecycle never mutates
  /// another's.
  final BleLinkManager _links = BleLinkManager(maxLinks: bleMaxLinkCount);

  /// Runtime-level secure-handshake deadlines per link, kept out of the link
  /// object so teardown can cancel them through the manager's own release.
  final Map<String, Timer> _handshakeDeadlines = {};

  /// Pending incoming approval requests, keyed by request ID. Each request
  /// owns its session, its peer and its expiry independently, so several
  /// peers can wait for approval at once without cross-talk.
  final Map<String, _PendingIncomingRequest> _incomingRequests = {};

  /// Inbound writes that arrived from a central before any link for it exists
  /// (a central that wrote before the notify-enabled link setup ran). Bounded
  /// per central and replayed into that central's link transport on session
  /// creation. A write that belongs to a known link is buffered on the link
  /// itself, never here.
  final Map<String, List<Uint8List>> _pendingCentralWrites = {};

  final Map<String, DateTime> _declinedUntil = {};

  /// Device IDs this device is currently establishing an outgoing link to.
  final Set<String> _pendingLinkIds = {};

  /// Links whose outgoing connection attempt is still in flight, so a scan or
  /// a second connect attempt cannot race a link that is not established yet.
  final Set<String> _linkEstablishing = {};

  /// Central disconnects in flight, keyed by device address. The Android
  /// plugin keys every GATT callback map by address and `connectGatt`
  /// overwrites the previous instance without closing it, so a connect issued
  /// before the previous teardown finishes receives the obsolete connection's
  /// callbacks — surfacing as "Write descriptor failed with status: 1" on
  /// reconnect. Every connect waits for its device's teardown first.
  /// shortcut: a native disconnect that never reports back is bounded by
  /// gattTeardownTimeout only; if Android wedges deeper than that, the
  /// upgrade path is patching the plugin's address-keyed callback maps.
  final Map<String, Future<void>> _centralTeardowns = {};

  Future<void>? _startFuture;
  Future<void>? _availabilityOperation;
  int _availabilityRevision = 0;
  bool _availabilityEnabled;
  bool _backgroundBleEnabled = false;
  bool _backgroundNotificationsAllowed = false;
  bool _backgroundServiceRunning = false;
  bool _backgroundStartInFlight = false;
  bool _startAttempted = false;
  bool _permissionCheckInFlight = false;
  bool _listenersAttached = false;
  bool _initialized = false;
  bool _foreground = true;
  bool _discovering = false;
  bool _serviceAdded = false;
  bool _advertising = false;
  bool _disposed = false;
  final Map<String, String?> _teardownPendingByDevice = {};

  /// The link currently driving the derived single-active-peer compatibility
  /// views: the most recently established link. Purely a publication choice —
  /// real per-peer truth lives in [_links] and [state.links].
  String? _primaryLinkId;

  /// Routing handler for multi-hop envelope processing.
  ///
  /// Initialized lazily on first use to avoid database dependency during
  /// construction. The forward callback selects an eligible next-hop peer and
  /// sends the envelope over their link.
  BleRoutingHandler? _routingHandler;

  /// Gets or creates the routing handler with the forward callback bound to
  /// this runtime.
  BleRoutingHandler _getRoutingHandler() {
    if (_routingHandler != null) return _routingHandler!;
    final localDeviceId = _ref.read(localDeviceIdProvider);
    if (localDeviceId == null) {
      throw const BleLinkException('Local device ID not available');
    }
    final repository = RoutingRepository();
    _routingHandler = BleRoutingHandler(
      routingRepository: repository,
      localDeviceId: localDeviceId,
      forward: _forwardEnvelope,
    );
    return _routingHandler!;
  }

  /// Forward callback for the routing handler: selects the next hop and
  /// sends the envelope over their link, returning (outcome, next hop).
  ///
  /// Queue and dedup persistence live in [BleRoutingHandler]; this method is
  /// deliberately storage-free so every queue write happens in the one class
  /// that owns the repository. Never routes back to the origin or to the peer
  /// the envelope arrived from, and only over secure-ready links.
  Future<(BleRoutingResult, String?)> _forwardEnvelope(
    BleRoutingEnvelope envelope,
    String incomingPeerId,
  ) async {
    final originId = envelope.originDeviceId;
    BlePeerLink? nextHopLink;

    for (final link in _links.links.values) {
      if (!isForwardCandidate(
        link.peerId,
        originId: originId,
        incomingPeerId: incomingPeerId,
      )) {
        continue;
      }
      if (link.phase != BleLinkPhase.secureReady) continue;
      if (link.session == null || !link.session!.isReady) continue;

      nextHopLink = link;
      break;
    }

    if (nextHopLink == null) {
      // No eligible hop right now: reported as failure so the handler parks
      // the envelope (state=failed, bytes intact) for the future retry loop.
      return (BleRoutingResult.rejected, null);
    }

    // Send the envelope over the next hop's link as a Noise-encrypted
    // secureMessage carrying the routing envelope (Phase 3D.1). A rejected
    // ACK or a transport error is never reported as successful forwarding.
    try {
      final ackResult = await _sendRawOverSecureLink(nextHopLink, envelope);
      if (ackResult == BleAckResult.rejected) {
        return (BleRoutingResult.rejected, nextHopLink.peerId);
      }
    } catch (_) {
      return (BleRoutingResult.rejected, nextHopLink.peerId);
    }
    return (BleRoutingResult.queuedForForward, nextHopLink.peerId);
  }

  /// Pure next-hop identity exclusion: a link bound to [peerId] may carry a
  /// forward only when that peer is neither the envelope's origin nor the
  /// peer the envelope arrived from — the two identities that would bounce
  /// the envelope straight back. Readiness (secure-ready phase, live
  /// session) is checked separately by the caller.
  static bool isForwardCandidate(
    String? peerId, {
    required String originId,
    required String incomingPeerId,
  }) {
    if (peerId == null) return false;
    if (peerId == originId) return false;
    if (peerId == incomingPeerId) return false;
    return true;
  }

  /// Sends a routing envelope over a secure link's session.
  ///
  /// Requires a confirmed secure session (no plaintext fallback) and returns
  /// the next hop's actual ACK result, so a rejected envelope is visible to
  /// the caller instead of looking like a successful forward.
  Future<BleAckResult> _sendRawOverSecureLink(
    BlePeerLink link,
    BleRoutingEnvelope envelope,
  ) async {
    final session = link.session;
    if (session == null || session.secure == null || !session.isSecureReady) {
      throw const BleLinkException('Secure link not ready');
    }
    return session.sendEnvelope(envelope);
  }

  /// One persistent-retry sweep over the relay queue (Phase 3D.2B).
  ///
  /// Triggered after runtime/database init, whenever a link becomes
  /// secure-ready, and periodically while active — callers fire and forget
  /// it. Never throws, and without a local routing identity there is nothing
  /// to retry yet.
  Future<void> retryRelayQueue() async {
    if (_disposed) return;
    if (_ref.read(localDeviceIdProvider) == null) return;
    try {
      await _getRoutingHandler().retryPending(now: _clock());
    } catch (_) {
      // The next trigger (init, a secure link, or the periodic timer) retries.
    }
  }

  /// The link bound to [peerId], if this device currently holds one.
  BlePeerLink? _linkFor(String peerId) => _links.byPeerId(peerId);

  /// Whether [peerId]'s own link is ready to carry application traffic.
  ///
  /// A secure link counts only once its Noise handshake finished, passed the
  /// key policy and was explicitly confirmed (published as secure-ready);
  /// legacy links count when their session is ready. Another peer's link
  /// state never influences this answer.
  bool _isLinkUsable(String peerId) {
    final link = _linkFor(peerId);
    final session = link?.session;
    if (link == null || session == null || !session.isReady) return false;
    if (session.secure != null && link.phase != BleLinkPhase.secureReady) {
      return false;
    }
    return true;
  }

  /// Publishes the current per-link snapshots and the derived single-link
  /// compatibility fields into [state].
  ///
  /// Alias of [_setState]: link-derived fields are recomputed from the
  /// registry on every publication, so callers only pass non-link facts.
  /// Called after every link mutation.
  void _publishLinks({
    BleRuntimeStatus? status,
    List<BleCandidate>? candidates,
    String? error,
    bool clearError = false,
    bool? isAdvertising,
  }) {
    _setState(
      status: status,
      candidates: candidates,
      error: error,
      clearError: clearError,
      isAdvertising: isAdvertising,
    );
  }

  /// The link backing the derived single-active-peer views: the most recent
  /// link with a known peer identity, preferring one that is secure-ready.
  BlePeerLink? get _primaryLink {
    BlePeerLink? newest;
    for (final link in _links.links.values) {
      if (link.peerId == null) continue;
      if (newest == null || link.createdAt.isAfter(newest.createdAt)) {
        newest = link;
      }
    }
    return newest;
  }

  List<IncomingConnectionRequest> _pendingRequestList() {
    final requests =
        _incomingRequests.values.map((pending) => pending.request).toList()
          ..sort((a, b) => a.requestedAt.compareTo(b.requestedAt));
    return requests;
  }

  /// Whether [session] may still take part in the incoming-approval flow.
  ///
  /// A secure session sits at [BleSecureLinkState.awaitingAuthorization]
  /// between the HELLO exchange and the Noise handshake, while a legacy
  /// session is simply [BleLinkSession.isReady]. Approval must remain
  /// possible in exactly those two states — never once a link has failed or
  /// closed.
  bool _isSessionUsableForApproval(BleLinkSession session) {
    if (session.isReady) return true;
    return session.secure != null &&
        session.secureState == BleSecureLinkState.awaitingAuthorization;
  }

  /// Sends one message over the link belonging to its receiver.
  ///
  /// The receiving peer's own link session carries the message; when that
  /// specific peer has no usable link the send fails, without affecting any
  /// other peer's link or delivery.
  Future<BleAckResult> _sendOverLink(
    String peerId,
    Message message, {
    Future<void> Function()? onTransmitted,
  }) {
    final session = _linkFor(peerId)?.session;
    if (session == null ||
        !session.isReady ||
        session.linkInfo?.deviceId != message.receiverId) {
      throw const BleLinkClosedException('No usable BLE link for this peer');
    }
    return session.sendMessage(message, onTransmitted: onTransmitted);
  }

  /// Drains queued messages for [peerId] over that peer's own link.
  Future<void> requestDelivery(String peerId) async {
    final localDeviceId = _ref.read(localDeviceIdProvider);
    if (localDeviceId == null || !_isLinkUsable(peerId)) return;
    await _outbox.drain(localDeviceId: localDeviceId, peerId: peerId);
  }

  Future<void> reconcileAvailability() async {
    if (_disposed || AppConstants.demoDataEnabled) return;
    final revision = _availabilityRevision;
    bool enabled;
    try {
      enabled = await _ref.read(appSettingsRepositoryProvider).getBleEnabled();
    } catch (error) {
      if (_disposed || revision != _availabilityRevision) return;
      _availabilityEnabled = false;
      _setState(
        status: BleRuntimeStatus.error,
        error:
            'Could not load the BeChat availability setting: '
            '${_describeError(error)}',
        candidates: const [],
        isAdvertising: false,
        availabilityEnabled: false,
      );
      return;
    }
    if (_disposed || revision != _availabilityRevision) return;
    await setAvailabilityEnabled(enabled);
  }

  Future<BackgroundBleToggleResult> enableBackgroundBle() async {
    if (_disposed || AppConstants.demoDataEnabled) {
      return const BackgroundBleToggleResult.failure(
        message: 'Background mode is not available in this build.',
      );
    }
    BackgroundBlePlatformStatus platformStatus;
    try {
      platformStatus = await _backgroundService.getStatus();
    } catch (error) {
      final message = 'Could not check Android background support: $error';
      _setBackgroundStatus(BackgroundBleRuntimeStatus.error, message);
      return BackgroundBleToggleResult.failure(message: message);
    }
    if (!platformStatus.supported) {
      const message =
          'Android background BLE operation is not available on this device.';
      _setBackgroundStatus(BackgroundBleRuntimeStatus.error, message);
      return const BackgroundBleToggleResult.failure(message: message);
    }

    var notificationsAllowed = platformStatus.notificationsAllowed;
    if (!notificationsAllowed) {
      notificationsAllowed = await _backgroundService
          .requestNotificationPermission();
    }
    if (!notificationsAllowed) {
      const message =
          'Notification permission is required for background messaging. '
          'Enable notifications for BeChat in Android settings.';
      _setBackgroundStatus(
        BackgroundBleRuntimeStatus.permissionDenied,
        message,
      );
      return const BackgroundBleToggleResult.failure(
        message: message,
        permissionDenied: true,
      );
    }

    if (_availabilityEnabled) {
      await ensureStarted();
      if (!_isBackgroundOperational(state.status)) {
        const message =
            'Background mode needs BeChat to be online. Turn on Bluetooth and '
            'BeChat availability, then try again.';
        _setBackgroundStatus(BackgroundBleRuntimeStatus.paused, message);
        return const BackgroundBleToggleResult.failure(message: message);
      }
    }

    try {
      if (_availabilityEnabled) {
        await _startBackgroundService();
      }
      await _ref
          .read(appSettingsProvider.notifier)
          .setBackgroundBleEnabled(true);
    } catch (error) {
      if (_backgroundServiceRunning) {
        await _stopBackgroundService();
      }
      final message =
          error is BackgroundBleServiceException &&
              state.backgroundError != null
          ? state.backgroundError!
          : 'Could not enable background mode: $error';
      _setBackgroundStatus(BackgroundBleRuntimeStatus.error, message);
      return BackgroundBleToggleResult.failure(message: message);
    }

    _backgroundBleEnabled = true;
    _backgroundNotificationsAllowed = true;
    _setBackgroundStatus(
      _availabilityEnabled
          ? BackgroundBleRuntimeStatus.active
          : BackgroundBleRuntimeStatus.paused,
      _availabilityEnabled ? null : 'Background mode starts when BeChat is on.',
    );
    await _updateBackgroundServiceNotification();
    return BackgroundBleToggleResult.success(
      message: _availabilityEnabled
          ? null
          : 'Background mode enabled. It starts when BeChat is turned on.',
    );
  }

  Future<BackgroundBleToggleResult> disableBackgroundBle() async {
    if (_disposed) {
      return const BackgroundBleToggleResult.failure(
        message: 'BeChat is shutting down.',
      );
    }
    try {
      await _ref
          .read(appSettingsProvider.notifier)
          .setBackgroundBleEnabled(false);
    } catch (error) {
      final message = 'Could not disable background mode: $error';
      _setBackgroundStatus(BackgroundBleRuntimeStatus.error, message);
      return BackgroundBleToggleResult.failure(message: message);
    }
    _backgroundBleEnabled = false;
    _backgroundNotificationsAllowed = false;
    await _cancelConnectionRequestNotification();
    await _stopBackgroundService(force: true);
    _setBackgroundStatus(BackgroundBleRuntimeStatus.disabled, null);
    return const BackgroundBleToggleResult.success();
  }

  Future<void> reconcileBackgroundBle() async {
    if (_disposed || AppConstants.demoDataEnabled) return;
    bool enabled;
    try {
      enabled = await _ref
          .read(appSettingsRepositoryProvider)
          .getBackgroundBleEnabled();
    } catch (error) {
      final message = 'Could not load background mode: $error';
      _setBackgroundStatus(BackgroundBleRuntimeStatus.error, message);
      return;
    }
    _backgroundBleEnabled = enabled;
    if (!enabled) {
      await _stopBackgroundService(force: true);
      _setBackgroundStatus(BackgroundBleRuntimeStatus.disabled, null);
      return;
    }
    if (!_availabilityEnabled) {
      await _stopBackgroundService(force: true);
      _setBackgroundStatus(
        BackgroundBleRuntimeStatus.paused,
        'Background mode starts when BeChat is on.',
      );
      return;
    }

    BackgroundBlePlatformStatus platformStatus;
    try {
      platformStatus = await _backgroundService.getStatus();
    } catch (error) {
      final message = 'Could not check background mode: $error';
      _setBackgroundStatus(BackgroundBleRuntimeStatus.error, message);
      return;
    }
    if (!platformStatus.supported) {
      await _stopBackgroundService(force: true);
      _setBackgroundStatus(
        BackgroundBleRuntimeStatus.error,
        'Android background BLE operation is not available on this device.',
      );
      return;
    }
    _backgroundNotificationsAllowed = platformStatus.notificationsAllowed;
    if (!platformStatus.notificationsAllowed) {
      await _stopBackgroundService(force: true);
      _setBackgroundStatus(
        BackgroundBleRuntimeStatus.permissionDenied,
        'Notification permission is required for background messaging.',
      );
      return;
    }

    if (platformStatus.serviceRunning) {
      _backgroundServiceRunning = true;
      await _refreshBackgroundServiceState();
      return;
    }

    if (!_foreground || !_isBackgroundOperational(state.status)) {
      _backgroundServiceRunning = false;
      _setBackgroundStatus(
        BackgroundBleRuntimeStatus.paused,
        _foreground
            ? 'Background mode waits for BeChat to be online.'
            : 'Background service is not running.',
      );
      return;
    }

    try {
      await _startBackgroundService();
      _setBackgroundStatus(BackgroundBleRuntimeStatus.active, null);
    } catch (error) {
      final message = 'Could not start background mode: $error';
      _setBackgroundStatus(BackgroundBleRuntimeStatus.error, message);
    }
  }

  Future<void> openNotificationSettings() =>
      _backgroundService.openNotificationSettings();

  void markBackgroundServiceFailed(String message) {
    if (_disposed ||
        (!_backgroundBleEnabled &&
            !_backgroundStartInFlight &&
            !_backgroundServiceRunning)) {
      return;
    }
    _backgroundServiceRunning = false;
    _setBackgroundStatus(BackgroundBleRuntimeStatus.error, message);
    if (!_foreground) {
      unawaited(_pauseUnavailableBackground());
    }
  }

  Future<void> _pauseUnavailableBackground() async {
    await _cancelConnectionRequestNotification();
    await _stopDiscoveryOnly();
    _resetCandidateTracking();
    await _closeAllLinks();
    if (_advertising) {
      try {
        await _peripheral.stopAdvertising();
      } catch (_) {}
      _advertising = false;
    }
    _setState(status: BleRuntimeStatus.idle, isAdvertising: false);
  }

  Future<void> setAvailabilityEnabled(bool enabled) {
    if (_disposed || AppConstants.demoDataEnabled) {
      return Future<void>.value();
    }
    _availabilityEnabled = enabled;
    _setState(availabilityEnabled: enabled);
    final revision = ++_availabilityRevision;
    final previous = _availabilityOperation ?? Future<void>.value();
    final operation = previous.catchError((Object _) {}).then((_) async {
      if (_disposed || revision != _availabilityRevision) return;
      if (enabled) {
        await ensureStarted();
        await _syncBackgroundServiceForState(startIfNeeded: true);
      } else {
        await _shutdownAvailability();
      }
    });
    _availabilityOperation = operation;
    return operation.whenComplete(() {
      if (identical(_availabilityOperation, operation)) {
        _availabilityOperation = null;
      }
    });
  }

  Future<void> _shutdownAvailability() async {
    _startAttempted = false;
    _clearAllIncomingRequests();
    final inFlight = _startFuture;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
    }
    if (_disposed) return;

    _initialized = false;
    for (final waiter in _connectionWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(
          const BleLinkException('BeChat availability was turned off'),
        );
      }
    }
    _connectionWaiters.clear();
    _declinedUntil.clear();
    // Shutting availability down closes every link and disconnects every
    // remote device, releasing each link's own resources independently.
    await _closeAllLinks();
    await _stopAdvertising();
    await _stopDiscoveryOnly();
    await _stopBackgroundService();
    _resetBleAfterLoss();
    _resetCandidateTracking(updateState: false);
    _setState(
      status: BleRuntimeStatus.idle,
      candidates: const [],
      isAdvertising: false,
      clearError: true,
    );
    _setBackgroundStatus(
      _backgroundBleEnabled
          ? BackgroundBleRuntimeStatus.paused
          : BackgroundBleRuntimeStatus.disabled,
      _backgroundBleEnabled
          ? 'Background mode starts when BeChat is on.'
          : null,
    );
    await _resetOutbox();
  }

  Future<void> ensureStarted() {
    if (_disposed || AppConstants.demoDataEnabled || !_availabilityEnabled) {
      return Future<void>.value();
    }
    final inFlight = _startFuture;
    if (inFlight != null) return inFlight;
    if (state.isConnected ||
        state.status == BleRuntimeStatus.ready ||
        state.status == BleRuntimeStatus.scanning) {
      return Future<void>.value();
    }

    final operation = _startUp();
    _startFuture = operation;
    return operation.whenComplete(() {
      if (identical(_startFuture, operation)) {
        _startFuture = null;
      }
    });
  }

  Future<void> _startUp() async {
    if (!_availabilityEnabled) {
      _setState(status: BleRuntimeStatus.idle);
      return;
    }
    _startAttempted = true;
    _setState(
      status: BleRuntimeStatus.starting,
      clearError: true,
      canOpenSettings: false,
    );
    try {
      if (!(_isAndroidOverride ?? Platform.isAndroid)) {
        _setState(status: BleRuntimeStatus.unsupported);
        return;
      }

      _attachListeners();
      var status = await _readPlatformStatus();
      if (!_availabilityEnabled) return;
      if (!status.leSupported) {
        _setState(status: BleRuntimeStatus.unsupported);
        return;
      }

      if (!status.permissionsGranted) {
        await _requestPermissions();
        if (!_availabilityEnabled) return;
        status = await _readPlatformStatus();
        if (!_availabilityEnabled) return;
      }

      if (!status.permissionsGranted) {
        _setState(
          status: BleRuntimeStatus.unauthorized,
          canOpenSettings: true,
          error:
              'Bluetooth permissions are required to scan, advertise, and '
              'connect. Open app settings to grant them.',
        );
        return;
      }
      if (!status.bluetoothEnabled) {
        _setState(
          status: BleRuntimeStatus.bluetoothOff,
          error: 'Bluetooth is turned off. Enable it and try again.',
        );
        return;
      }
      if (!status.advertisingSupported) {
        _setState(status: BleRuntimeStatus.unsupported);
        return;
      }

      await _preparePeripheral();
      if (!_availabilityEnabled) return;
      if (state.status == BleRuntimeStatus.error) return;
      _initialized = true;
      _setState(
        status: BleRuntimeStatus.ready,
        isAdvertising: _advertising,
        clearError: true,
      );
      await _resetOutbox();
      // Parked envelopes from a previous run may already be retryable.
      unawaited(retryRelayQueue());
      _ensureRelayRetryTimer();
      await _syncBackgroundServiceForState(startIfNeeded: true);
    } on BleStatusProbeException catch (error) {
      _setState(
        status: BleRuntimeStatus.error,
        error: error.message,
        canOpenSettings: false,
      );
    } catch (error) {
      _setState(status: BleRuntimeStatus.error, error: _describeError(error));
    }
  }

  Future<BlePlatformStatus> _readPlatformStatus() async {
    try {
      return await _statusProbe.getStatus();
    } on BleStatusProbeException {
      rethrow;
    } catch (error) {
      throw BleStatusProbeException(
        'Could not verify Android Bluetooth status: ${_describeError(error)}',
      );
    }
  }

  Future<void> _requestPermissions() async {
    try {
      await _authorizeCentral().timeout(_permissionTimeout);
    } catch (_) {}
    try {
      await _authorizePeripheral().timeout(_permissionTimeout);
    } catch (_) {}
  }

  Future<bool> _authorizeCentral() async {
    try {
      return await _central.authorize();
    } on UnsupportedError {
      return true;
    }
  }

  Future<bool> _authorizePeripheral() async {
    try {
      return await _peripheral.authorize();
    } on UnsupportedError {
      return true;
    }
  }

  void _attachListeners() {
    if (_listenersAttached) return;
    _listenersAttached = true;
    _subscriptions.add(
      _central.stateChanged.listen((event) {
        _handleAdapterState(event.state);
      }),
    );
    _subscriptions.add(
      _peripheral.stateChanged.listen((event) {
        _handleAdapterState(event.state);
      }),
    );
    _subscriptions.add(_central.discovered.listen(_handleDiscovered));
    _subscriptions.add(
      _central.connectionStateChanged.listen(_handleCentralConnection),
    );
    _subscriptions.add(
      _central.characteristicNotified.listen((event) {
        if (event.characteristic.uuid != _txUuid) return;
        // Route the notification to the link that owns this peripheral; each
        // central-role link holds its own transport, so simultaneous links
        // never cross-deliver inbound frames.
        final link = _links.byLinkId(event.peripheral.uuid.toString());
        final transport = link?.transport;
        if (transport is! _CentralValueTransport) return;
        transport.add(event.value);
      }),
    );
    _subscriptions.add(
      _peripheral.characteristicWriteRequested.listen(_handlePeripheralWrite),
    );
    _subscriptions.add(
      _peripheral.characteristicNotifyStateChanged.listen(
        _handleNotifyStateChanged,
      ),
    );
    _subscriptions.add(
      _peripheral.connectionStateChanged.listen(_handlePeripheralConnection),
    );
  }

  void _handleAdapterState(BluetoothLowEnergyState adapterState) {
    if (_disposed) return;
    if (!_availabilityEnabled) {
      _resetBleAfterLoss();
      return;
    }
    switch (adapterState) {
      case BluetoothLowEnergyState.unsupported:
        _resetBleAfterLoss();
        unawaited(_closeAllLinks());
        _setState(status: BleRuntimeStatus.unsupported);
      case BluetoothLowEnergyState.unauthorized:
        if (_startFuture != null) return;
        unawaited(_handleUnauthorizedAdapterState());
      case BluetoothLowEnergyState.poweredOff:
        _teardownPendingByDevice.clear();
        _resetBleAfterLoss();
        unawaited(_closeAllLinks());
        _setState(
          status: BleRuntimeStatus.bluetoothOff,
          error: 'Bluetooth is turned off. Enable it and try again.',
        );
      case BluetoothLowEnergyState.poweredOn:
      case BluetoothLowEnergyState.unknown:
        if (_startFuture != null || !_availabilityEnabled) return;
        if (_startAttempted && !_initialized && _canContinueBle) {
          unawaited(ensureStarted());
          return;
        }
        if (_initialized &&
            _canContinueBle &&
            !state.isConnected &&
            state.status != BleRuntimeStatus.connecting) {
          unawaited(_recoverAdvertising());
        }
    }
  }

  void _resetBleAfterLoss() {
    _scanTimer?.cancel();
    _scanTimer = null;
    _clearAllIncomingRequests();
    _resetCandidateTracking();
    _discovering = false;
    _advertising = false;
    _serviceAdded = false;
    _initialized = false;
  }

  Future<void> _handleUnauthorizedAdapterState() async {
    if (_disposed || _permissionCheckInFlight) return;
    _permissionCheckInFlight = true;
    try {
      final status = await _readPlatformStatus();
      if (!status.leSupported) {
        _resetBleAfterLoss();
        await _closeAllLinks();
        if (!_disposed) {
          _setState(status: BleRuntimeStatus.unsupported);
        }
        return;
      }
      if (!status.permissionsGranted) {
        _resetBleAfterLoss();
        await _closeAllLinks();
        if (_disposed) return;
        _setState(
          status: BleRuntimeStatus.unauthorized,
          canOpenSettings: true,
          error: 'Bluetooth permission was not granted.',
        );
        return;
      }
      if (!status.bluetoothEnabled) {
        _resetBleAfterLoss();
        await _closeAllLinks();
        if (_disposed) return;
        _setState(
          status: BleRuntimeStatus.bluetoothOff,
          error: 'Bluetooth is turned off. Enable it and try again.',
        );
        return;
      }
      if (!status.advertisingSupported) {
        _resetBleAfterLoss();
        await _closeAllLinks();
        if (!_disposed) {
          _setState(status: BleRuntimeStatus.unsupported);
        }
        return;
      }
      if (_initialized) {
        if (_canContinueBle &&
            !state.isConnected &&
            state.status != BleRuntimeStatus.connecting) {
          await _recoverAdvertising();
        }
        return;
      }
      if (_startAttempted && _canContinueBle) {
        await ensureStarted();
      }
    } on BleStatusProbeException catch (error) {
      if (!_disposed && !state.isConnected) {
        _setState(status: BleRuntimeStatus.error, error: error.message);
      }
    } catch (error) {
      if (!_disposed && !state.isConnected) {
        _setState(status: BleRuntimeStatus.error, error: _describeError(error));
      }
    } finally {
      _permissionCheckInFlight = false;
    }
  }

  Future<void> _recoverAdvertising() async {
    if (_disposed || !_canContinueBle || _advertising) {
      return;
    }
    if (_isTerminalStatus(state.status)) return;
    try {
      await _preparePeripheral();
      if (!_disposed) {
        _setState(
          status: state.status == BleRuntimeStatus.scanning
              ? BleRuntimeStatus.scanning
              : BleRuntimeStatus.ready,
          isAdvertising: _advertising,
          clearError: true,
        );
      }
    } catch (error) {
      _setState(status: BleRuntimeStatus.error, error: _describeError(error));
    }
  }

  Future<void> _preparePeripheral() async {
    if (!_serviceAdded) {
      await _peripheral.removeAllServices();
      final rx = GATTCharacteristic.mutable(
        uuid: _rxUuid,
        properties: [
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
        ],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: const [],
      );
      final tx = GATTCharacteristic.mutable(
        uuid: _txUuid,
        properties: [GATTCharacteristicProperty.notify],
        permissions: const [],
        descriptors: const [],
      );
      final service = GATTService(
        uuid: _serviceUuid,
        isPrimary: true,
        includedServices: const [],
        characteristics: [rx, tx],
      );
      await _peripheral.addService(service);
      _serviceAdded = true;
    }
    if (!_advertising) {
      await _peripheral.startAdvertising(
        Advertisement(name: 'BeChat', serviceUUIDs: [_serviceUuid]),
      );
      _advertising = true;
    }
  }

  Future<void> startScan() async {
    if (AppConstants.demoDataEnabled || _disposed || !_availabilityEnabled) {
      return;
    }
    await ensureStarted();
    // Scanning is allowed while other links are active: additional peers can
    // always be discovered and connected. Only an in-flight scan or connect
    // attempt on this device stops a new scan from starting.
    if (_disposed ||
        !_availabilityEnabled ||
        state.status == BleRuntimeStatus.scanning ||
        state.status == BleRuntimeStatus.connecting) {
      return;
    }
    if (state.status != BleRuntimeStatus.ready &&
        state.status != BleRuntimeStatus.connected) {
      return;
    }

    _setState(status: BleRuntimeStatus.scanning, clearError: true);
    try {
      await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);
      _discovering = true;
      _scanTimer?.cancel();
      _scanTimer = Timer(AppConstants.scanTimeout, () {
        unawaited(stopScan());
      });
    } catch (error) {
      _discovering = false;
      _setState(
        status: BleRuntimeStatus.error,
        error: 'Scanning failed: ${_describeError(error)}',
      );
    }
  }

  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (_discovering) {
      _discovering = false;
      try {
        await _central.stopDiscovery();
      } catch (_) {}
    }
    if (!_disposed && state.status == BleRuntimeStatus.scanning) {
      // Return to the status the runtime can hold now: connected when at
      // least one link is active, otherwise ready.
      _setState(
        status: state.hasSecureLink
            ? BleRuntimeStatus.connected
            : BleRuntimeStatus.ready,
      );
    }
  }

  void _handleDiscovered(DiscoveredEventArgs event) {
    if (!_foreground ||
        !_discovering ||
        state.status != BleRuntimeStatus.scanning) {
      return;
    }
    final advertisement = event.advertisement;
    if (!advertisement.serviceUUIDs.contains(_serviceUuid)) return;
    final id = event.peripheral.uuid.toString();
    _candidatesById[id] = event.peripheral;
    final name = advertisement.name?.trim();
    final displayName = name == null || name.isEmpty ? 'BeChat device' : name;
    final candidate = BleCandidate(
      id: id,
      displayName: displayName,
      rssi: event.rssi,
      lastSeen: _clock(),
    );
    final updated = [...state.candidates];
    final index = updated.indexWhere((item) => item.id == id);
    if (index < 0) {
      updated.add(candidate);
    } else {
      updated[index] = candidate;
    }
    updated.sort((a, b) => b.rssi.compareTo(a.rssi));
    _setState(candidates: updated);
    _ensureCandidateCleanup();
  }

  void _ensureCandidateCleanup() {
    if (_candidateCleanupTimer != null) return;
    _candidateCleanupTimer = Timer.periodic(
      _candidateCleanupInterval,
      (_) => _expireCandidates(),
    );
  }

  /// Starts the periodic relay-queue retry sweep once, at runtime init.
  void _ensureRelayRetryTimer() {
    if (_relayRetryTimer != null) return;
    _relayRetryTimer = Timer.periodic(_relayRetryInterval, (_) {
      unawaited(retryRelayQueue());
    });
  }

  void _expireCandidates() {
    if (_disposed) return;
    final now = _clock();
    final remaining = state.candidates
        .where(
          (candidate) =>
              candidate.lastSeen.add(_candidateExpiration).isAfter(now),
        )
        .toList();
    if (remaining.length == state.candidates.length) return;

    final remainingIds = remaining.map((candidate) => candidate.id).toSet();
    _candidatesById.removeWhere((id, _) => !remainingIds.contains(id));
    _setState(candidates: remaining);
    if (remaining.isEmpty) {
      _candidateCleanupTimer?.cancel();
      _candidateCleanupTimer = null;
    }
  }

  void _resetCandidateTracking({bool updateState = true}) {
    _candidateCleanupTimer?.cancel();
    _candidateCleanupTimer = null;
    _candidatesById.clear();
    if (updateState && !_disposed && state.candidates.isNotEmpty) {
      _setState(candidates: const []);
    }
  }

  /// Connects outward to [candidateId] as a BLE central, creating one
  /// independent link.
  ///
  /// Multi-connection behavior: this runs alongside any number of other
  /// active links (incoming or outgoing), each with its own gate, transport,
  /// Noise session and lifecycle. Connecting to a device this device already
  /// holds a link to is refused, and reaching [bleMaxLinkCount] fails
  /// gracefully without disturbing the existing links.
  Future<String?> connectToCandidate(String candidateId) async {
    if (_disposed || !_availabilityEnabled) {
      return null;
    }
    if (_links.byLinkId(candidateId) != null ||
        _pendingLinkIds.contains(candidateId)) {
      // This device already holds (or is establishing) a link to that
      // device; a second link to the same peer is never created.
      return null;
    }
    if (_teardownPendingByDevice.containsKey(candidateId)) {
      _setState(
        error:
            'The previous BLE link to this device is still closing. Turn '
            'Bluetooth off and on, or restart BeChat, before reconnecting.',
      );
      return null;
    }
    final peripheral = _candidatesById[candidateId];
    if (peripheral == null) {
      _setState(
        status: BleRuntimeStatus.error,
        error: 'That device is no longer available. Scan again.',
      );
      return null;
    }
    if (_links.length >= bleMaxLinkCount) {
      // Graceful capacity exhaustion: existing links are untouched.
      _setState(
        status: state.hasSecureLink
            ? BleRuntimeStatus.connected
            : BleRuntimeStatus.ready,
        error:
            'This device already holds the maximum number of simultaneous '
            'connections. Disconnect a peer before adding another.',
      );
      return null;
    }

    final linkId = peripheral.uuid.toString();
    _pendingLinkIds.add(linkId);
    final link = BlePeerLink(
      linkId: linkId,
      role: BleLinkRole.central,
      peripheral: peripheral,
      remoteDeviceName: state.candidates
          .where((candidate) => candidate.id == candidateId)
          .map((candidate) => candidate.displayName)
          .firstOrNull,
      remoteRssi: state.candidates
          .where((candidate) => candidate.id == candidateId)
          .map((candidate) => candidate.rssi)
          .firstOrNull,
      createdAt: _clock(),
    );
    if (!_links.add(link)) {
      _pendingLinkIds.remove(linkId);
      return null;
    }
    _linkEstablishing.add(linkId);
    _primaryLinkId ??= linkId;
    _armHelloDeadline(link);
    _publishLinks(status: BleRuntimeStatus.connecting, clearError: true);

    await _stopDiscoveryOnly();

    final waiter = Completer<void>();
    _connectionWaiters[linkId] = waiter;
    unawaited(waiter.future.catchError((Object _) {}));
    try {
      // Never overlap a new connect with this device's previous teardown:
      // the Android plugin routes GATT callbacks by address, so the old
      // instance's late callbacks would complete this connection's
      // operations (the observed "Write descriptor failed with status: 1").
      final teardown = _centralTeardowns[linkId];
      if (teardown != null) {
        await teardown;
      }
      await _central.connect(peripheral).timeout(const Duration(seconds: 15));
      await waiter.future.timeout(const Duration(seconds: 15));
      if (!_availabilityEnabled) {
        throw const BleLinkException('BeChat was turned off');
      }
      final services = await _central
          .discoverGATT(peripheral)
          .timeout(const Duration(seconds: 15));
      final characteristics = _findBeChatCharacteristics(services);
      final tx = characteristics.tx;
      final rx = characteristics.rx;
      final maxWriteLength = await _negotiateCentralWriteLimit(link);
      final transport = _CentralValueTransport(
        manager: _central,
        peripheral: peripheral,
        characteristic: rx,
        maximumWriteLength: maxWriteLength,
        gate: link.gate,
      );
      link.transport = transport;
      await _enableNotifications(peripheral, tx);
      if (!_availabilityEnabled) {
        throw const BleLinkException('BeChat was turned off');
      }
      final session = _createSession(transport, BleLinkRole.central, link);
      link.session = session;
      final hello = await session.start(
        // Bind inbound frames to this link so simultaneous links never
        // cross-deliver: the callback runs with the exact session that
        // received the frame.
        onHello: (hello) => _handleHelloForLink(link, hello),
        onMessage: (payload) => _handleIncomingForLink(link, payload),
        onRoutingEnvelope: (envelope) =>
            _handleIncomingForLink(link, envelope),
      );
      if (!_availabilityEnabled) {
        throw const BleLinkException('BeChat was turned off');
      }
      await _beginSecureLink(link, session, hello);
      return hello.deviceId;
    } catch (error, stackTrace) {
      _logError('connect failed', error, stackTrace);
      _connectionWaiters.remove(linkId);
      await _closeLink(link, error: error);
      await _disconnectCentral(peripheral);
      if (!_disposed) {
        final turnedOff = !_availabilityEnabled;
        _setState(
          status: turnedOff ? BleRuntimeStatus.idle : BleRuntimeStatus.error,
          error: turnedOff
              ? null
              : 'Connection failed: ${_describeError(error)}',
          clearError: turnedOff,
        );
        _publishLinks();
      }
      return null;
    } finally {
      _pendingLinkIds.remove(linkId);
    }
  }

  /// Negotiates this outgoing link's effective write limit.
  ///
  /// Requests the largest ATT MTU the peer supports (bounded at 517, the
  /// maximum the BLE spec and Android 14+ allow) and falls back to the
  /// default 23-byte MTU — a 20-byte write payload — whenever negotiation is
  /// unsupported or fails, which keeps the link usable on every peer. The
  /// result is stored per link, so different links legitimately end up with
  /// different effective write limits.
  Future<int> _negotiateCentralWriteLimit(BlePeerLink link) async {
    var negotiatedMtu = 23;
    try {
      negotiatedMtu = await _central
          .requestMTU(link.peripheral!, mtu: _preferredMtu)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Negotiation is best-effort: the default MTU keeps the link working.
      negotiatedMtu = 23;
    }
    int maximumWriteLength;
    try {
      maximumWriteLength = await _central.getMaximumWriteLength(
        link.peripheral!,
        type: GATTCharacteristicWriteType.withResponse,
      );
    } catch (_) {
      // Fall back to the conservative ATT default payload when the platform
      // cannot report a length.
      maximumWriteLength = negotiatedMtu > 23 ? negotiatedMtu - 3 : 20;
    }
    link.effectiveWriteLength = maximumWriteLength;
    return maximumWriteLength;
  }

  /// Preferred ATT MTU for outgoing links: the BLE maximum, which Android 14+
  /// grants to the first requesting GATT client anyway.
  static const int _preferredMtu = 517;

  /// Writes the TX client configuration descriptor.
  ///
  /// Android can report a generic status 129 for this write when it races the
  /// tail of service discovery or a just-closed link. The descriptor write is
  /// idempotent, so retrying on the same connection recovers the common case
  /// instead of forcing the user to reconnect manually.
  Future<void> _enableNotifications(
    Peripheral peripheral,
    GATTCharacteristic characteristic,
  ) {
    return retryBleOperation(
      // A lost native callback would otherwise hang the connect flow forever:
      // the descriptor write must complete (or fail) before the link can be
      // declared ready. Failure propagates to the connect flow, which tears
      // the link down instead of pretending it succeeded.
      () => _central
          .setCharacteristicNotifyState(
            peripheral,
            characteristic,
            state: true,
          )
          .timeout(const Duration(seconds: 5)),
      delay: (attempt) => Duration(milliseconds: 250 * attempt),
    );
  }

  _BeChatCharacteristics _findBeChatCharacteristics(
    List<GATTService> services,
  ) {
    for (final service in services) {
      if (service.uuid != _serviceUuid) continue;
      GATTCharacteristic? rx;
      GATTCharacteristic? tx;
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == _rxUuid) rx = characteristic;
        if (characteristic.uuid == _txUuid) tx = characteristic;
      }
      if (rx == null || tx == null) {
        throw const BleLinkException(
          'The peer did not expose the BeChat RX/TX characteristics',
        );
      }
      return _BeChatCharacteristics(rx: rx, tx: tx);
    }
    throw const BleLinkException('The peer did not expose the BeChat service');
  }

  /// Creates the link session for [link] in secure mode.
  ///
  /// Every production session requires the Noise capability: once secure
  /// messaging is selected there is no plaintext application path. Every
  /// callback is bound to [link], so late events (close, remote identity,
  /// key conflict) are always attributable to one specific link and session
  /// instance — a closed or replaced link can never publish state for
  /// another peer.
  BleLinkSession _createSession(
    BleTransport transport,
    BleLinkRole role,
    BlePeerLink link,
  ) {
    final identity = _requireSecureIdentity();
    late final BleLinkSession session;
    session = BleLinkSession(
      transport: transport,
      identity: identity,
      // Fallback handlers for the window before start() binds the link-aware
      // overrides; the overrides are always supplied by the connection flows.
      onHello: (hello) => _handleHelloForLink(link, hello),
      onMessage: (payload) => _handleIncomingForLink(link, payload),
      onRoutingEnvelope: (envelope) =>
          _handleIncomingForLink(link, envelope),
      onClosed: (error) {
        unawaited(_onSessionClosed(link, session, error));
      },
      // The runtime deadline doubles as the session's internal secure
      // handshake budget, so injected short timeouts cover both layers.
      handshakeTimeout: _linkHandshakeTimeout,
      secure: _buildSecureSessionConfig(
        role,
        onRemoteIdentity: (remote) =>
            _handleSecureRemoteIdentity(link, session, remote),
        onPinnedKeyMismatch: () => _recordPeerKeyConflict(link),
      ),
    );
    return session;
  }

  /// Validates that the local UUID identity and the synchronized native
  /// public identity are present, consistent and usable for secure mode.
  ///
  /// Fails closed with a user-visible "secure messaging unavailable" error
  /// instead of ever falling back to plaintext, using an unvalidated key, or
  /// provisioning a second identity.
  Identity _requireSecureIdentity() {
    final identity = _ref.read(identityProvider).valueOrNull;
    if (identity == null) {
      throw const BleLinkException(
        'Secure messaging is unavailable: the local identity is not ready.',
      );
    }
    final status = _ref.read(identityInitializationProvider);
    if (status.state != IdentityInitializationState.ready) {
      throw const BleLinkException(
        'Secure messaging is unavailable: the cryptographic identity has '
        'not finished initializing.',
      );
    }
    if (status.deviceId == null || status.deviceId != identity.deviceId) {
      throw const BleLinkException(
        'Secure messaging is unavailable: the native identity does not '
        'belong to this device.',
      );
    }
    final nativeKey = status.publicKeyHex;
    final syncedKey = identity.publicKey;
    if (nativeKey == null ||
        syncedKey == null ||
        !KeyFormat.isHex32(nativeKey) ||
        !KeyFormat.isHex32(syncedKey) ||
        nativeKey != syncedKey) {
      throw const BleLinkException(
        'Secure messaging is unavailable: the native identity key is '
        'missing or does not match the stored identity.',
      );
    }
    return identity;
  }

  /// Builds the secure-mode configuration for a session of [role].
  ///
  /// BLE peripheral maps to the Noise initiator, BLE central to the Noise
  /// responder. The plaintext HELLO stays an untrusted hint: the session
  /// binds the authenticated identity against it, and the runtime revalidates
  /// the authenticated identity in [_handleSecureRemoteIdentity].
  BleSecureSessionConfig _buildSecureSessionConfig(
    BleLinkRole role, {
    required FutureOr<void> Function(RemoteAuthenticatedIdentity remote)
    onRemoteIdentity,
    required FutureOr<void> Function() onPinnedKeyMismatch,
  }) {
    return BleSecureSessionConfig(
      gateway: _ref.read(secureSessionGatewayProvider),
      role: role == BleLinkRole.peripheral
          ? BleSecureRole.initiator
          : BleSecureRole.responder,
      requireHelloBinding: true,
      onRemoteIdentity: onRemoteIdentity,
      onPinnedKeyMismatch: onPinnedKeyMismatch,
    );
  }

  /// Records that a pinned peer on [link] presented a different
  /// authenticated key, preserving the original pin and fingerprint (see
  /// [PeerRepository.recordKeyConflict]). Only this link's peer is touched.
  Future<void> _recordPeerKeyConflict(BlePeerLink link) async {
    if (_disposed || link.isClosed) return;
    final peerId = link.boundPeer?.peerId ?? link.peerId;
    if (peerId == null) return;
    try {
      await _ref.read(peerRepositoryProvider).recordKeyConflict(peerId);
      await _refreshPeers();
    } catch (_) {
      // The link still fails closed below; bookkeeping must not mask it.
    }
  }

  /// Whether [link] is still the live link its session belongs to.
  ///
  /// The staleness guard for every asynchronous step: a link that was closed,
  /// removed or given a replacement session while an operation was in flight
  /// can no longer change any state.
  bool _isLiveLink(BlePeerLink link, BleLinkSession session) {
    if (_disposed || link.isClosed) return false;
    return identical(_links.byLinkId(link.linkId), link) &&
        identical(link.session, session);
  }

  /// Validates the authenticated remote identity on [link], applies the
  /// peer-key policy, explicitly confirms the Noise session, and publishes
  /// the link.
  ///
  /// Invoked inside the session's inbound-frame queue before any later frame
  /// is processed, so no application payload can precedes this decision. Every
  /// check fails closed; nothing unauthenticated is persisted, existing peer
  /// metadata is never overwritten, and `verified` is never assigned here.
  /// A failure here affects only this link — every other link keeps its own
  /// session, presence and delivery untouched.
  Future<void> _handleSecureRemoteIdentity(
    BlePeerLink link,
    BleLinkSession session,
    RemoteAuthenticatedIdentity remote,
  ) async {
    if (!_isLiveLink(link, session)) {
      throw const BleLinkException(
        'The BLE link closed during the secure handshake',
      );
    }
    final knownPeer = link.boundPeer;
    if (knownPeer == null) {
      throw const BleLinkException(
        'The BLE link has no approved peer for this secure session',
      );
    }
    if (remote.protocolVersion != BleSecureProtocol.identityFormatVersion) {
      throw const BleLinkException(
        'The peer is using an unsupported secure protocol version. Ask them '
        'to update BeChat.',
      );
    }
    if (!remote.supportsCapability(BleSecureProtocol.capabilitySecureText)) {
      throw const BleLinkException(
        'The peer does not support secure messaging.',
      );
    }
    if (!KeyFormat.isHex32(remote.publicKeyHex) ||
        !_uuidPattern.hasMatch(remote.deviceId)) {
      throw const BleLinkException('The peer presented an invalid identity.');
    }
    final hello = session.linkInfo;
    if (hello == null ||
        remote.deviceId != hello.deviceId ||
        remote.deviceId != knownPeer.peerId) {
      // The HELLO is an unauthenticated hint and the approved peer is the
      // bound context: disagreement with the authenticated identity fails
      // closed with nothing persisted.
      throw const BleLinkException(
        'The authenticated peer does not match the approved connection.',
      );
    }

    final peerRepository = _ref.read(peerRepositoryProvider);
    final existing = await peerRepository.getPeerByPeerId(remote.deviceId);
    if (existing != null &&
        (existing.isBlocked || existing.status == PeerStatus.blocked)) {
      throw const BleLinkException('Peer is blocked');
    }
    final pinnedKey = knownPeer.publicKey?.trim();
    final hasPinnedKey = pinnedKey != null && pinnedKey.isNotEmpty;
    if (hasPinnedKey && pinnedKey != remote.publicKeyHex) {
      // A different authenticated static key for a pinned peer: keep the
      // pin, mark the conflict, and fail closed. The new key never lands in
      // the database and the session never becomes usable. Only this peer's
      // pin is affected; every other link keeps its own identity binding.
      await peerRepository.recordKeyConflict(remote.deviceId);
      unawaited(_refreshPeers());
      throw const BleLinkException(
        'The identity of this peer has changed. For your safety this '
        'connection was blocked.',
      );
    }

    // First contact (no pin yet): re-read the row so a key recorded since
    // the approval decision is treated as a pin before anything is written.
    var needsPinPersist = !hasPinnedKey;
    if (needsPinPersist && existing != null) {
      final rowKey = existing.publicKey?.trim();
      if (rowKey != null && rowKey.isNotEmpty) {
        needsPinPersist = false;
        if (rowKey != remote.publicKeyHex) {
          await peerRepository.recordKeyConflict(remote.deviceId);
          unawaited(_refreshPeers());
          throw const BleLinkException(
            'The identity of this peer has changed. For your safety this '
            'connection was blocked.',
          );
        }
      }
    }

    // Explicit native confirmation comes before any persistence, so a failed
    // confirmation leaves no partially trusted peer metadata behind.
    await session.confirmSecurePeerIdentity();
    if (!_isLiveLink(link, session)) {
      throw const BleLinkException(
        'The BLE link closed during the secure handshake',
      );
    }

    if (needsPinPersist) {
      // First contact: the peer row exists only when approval already created
      // it from the untrusted HELLO hint (accept path), and does not exist
      // yet when the link was auto-approved (reconnect). Either way the
      // authenticated identity is authoritative for the name, so persist it
      // before the pin. The upsert preserves any stored key and can never
      // promote the peer to `verified`.
      await peerRepository.upsertPeer(
        knownPeer.copyWith(displayName: remote.displayName),
      );
      final recorded = await peerRepository.recordCandidatePublicKey(
        remote.deviceId,
        publicKeyHex: remote.publicKeyHex,
      );
      if (recorded != PeerKeyVerificationState.unverified) {
        throw const BleLinkException(
          'The peer key could not be recorded safely.',
        );
      }
      unawaited(_refreshPeers());
    }

    await _publishSecureLink(link, session, remote);
  }

  /// Publishes [link] as a confirmed, secure link: connected state,
  /// secure-ready flag, peer online status, chat creation, that link's own
  /// presence monitoring and its outbox drain — all of which stay dark until
  /// this point, and all of which are scoped to this link alone.
  Future<void> _publishSecureLink(
    BlePeerLink link,
    BleLinkSession session,
    RemoteAuthenticatedIdentity remote,
  ) async {
    if (!_isLiveLink(link, session)) return;
    final peer = link.boundPeer;
    if (peer == null || peer.peerId != remote.deviceId) return;
    final published = peer.copyWith(
      // The authenticated identity is authoritative for the display name.
      displayName: remote.displayName,
      status: PeerStatus.online,
      signalStrength: peer.signalStrength ?? link.remoteRssi,
    );
    link.boundPeer = published;
    // The authenticated identity is authoritative for the display name, so it
    // overrides the pre-secure HELLO or scan-time hint on this link only. The
    // raw BLE device name observed at connection time is preserved as-is.
    link.remoteDisplayName = remote.displayName;
    // The link becomes the primary view, so the derived single-active-peer
    // compatibility fields follow the most recent secure link.
    _primaryLinkId = link.linkId;
    _publishLinks(
      status: BleRuntimeStatus.connected,
      candidates: const [],
      isAdvertising: _advertising,
      clearError: true,
    );
    await _markPeerOnline(published.peerId, signalStrength: link.remoteRssi);
    if (!_isLiveLink(link, session) || !session.isSecureReady) {
      await _markPeerOffline(published.peerId);
      return;
    }
    try {
      await _ref.read(chatRepositoryProvider).getOrCreateChatForPeer(published);
      await _ref.read(chatListProvider.notifier).refreshChats();
    } catch (_) {}
    if (link.role == BleLinkRole.central) {
      _startPresenceMonitor(link);
    }
    unawaited(requestDelivery(published.peerId));
    // A new secure-ready link may unblock parked relay envelopes.
    unawaited(retryRelayQueue());
  }

  /// Resolves the pinned remote key for [peer] from the bound peer context.
  ///
  /// Returns null for a peer that has no key yet (first contact), which the
  /// engine treats as "no pin" — the policy layer then records the
  /// authenticated key as unverified before anything is published.
  Uint8List? _resolvePinnedPeerKey(Peer peer) {
    final stored = peer.publicKey?.trim();
    if (stored == null || stored.isEmpty) return null;
    if (!KeyFormat.isHex32(stored)) {
      throw const BleLinkException(
        'Secure messaging is unavailable: the stored key for this peer is '
        'invalid.',
      );
    }
    return KeyFormat.hex32ToBytes(stored);
  }

  /// Authorizes and starts the Noise handshake for [link], which the user or
  /// the auto-approve policy has approved.
  ///
  /// Binds the peer-specific context (pinned key + expected device ID) after
  /// the HELLO exchange and before the handshake, then waits for local setup
  /// within the runtime deadline. Readiness is *not* published here:
  /// [_publishSecureLink] runs only after the handshake authenticates the
  /// peer and the native session is explicitly confirmed. Only [link]'s own
  /// session is started; every other link is untouched.
  Future<void> _startSecureHandshake(
    BlePeerLink link,
    BleLinkSession session,
  ) async {
    if (!_isLiveLink(link, session)) return;
    final peer = link.boundPeer;
    if (peer == null) return;
    if (session.secureState != BleSecureLinkState.awaitingAuthorization) {
      return;
    }
    _setState(
      status: BleRuntimeStatus.connecting,
      candidates: const [],
      clearError: true,
    );
    _armHandshakeDeadline(link);
    try {
      session.bindSecurePeerContext(
        pinnedRemotePublicKey: _resolvePinnedPeerKey(peer),
        expectedPeerDeviceId: peer.peerId,
      );
      await session.startSecureHandshake().timeout(_linkHandshakeTimeout);
    } catch (error) {
      // Ensure every local handshake failure tears this link down; a session
      // that already failed closed is left alone. There is no plaintext
      // fallback from here, and no other link is affected.
      if (session.state != BleSessionState.closed) {
        await session.close(error);
      }
      rethrow;
    } finally {
      _handshakeDeadlines.remove(link.linkId)?.cancel();
    }
  }

  /// Arms this link's runtime-level secure-handshake deadline backstop, which
  /// also covers the approval-to-handshake window on the accepting side.
  void _armHandshakeDeadline(BlePeerLink link) {
    _handshakeDeadlines.remove(link.linkId)?.cancel();
    _handshakeDeadlines[link.linkId] = Timer(_linkHandshakeTimeout, () {
      final session = link.session;
      if (session != null &&
          session.secureState != BleSecureLinkState.secureReady &&
          session.state != BleSessionState.closed) {
        unawaited(session.close(const BleSecureHandshakeTimeoutException()));
      }
    });
  }

  /// Arms this outgoing link's pre-secure HELLO deadline: an outgoing link
  /// that never completes its HELLO exchange is torn down so it cannot sit
  /// half-open forever. Only this link is affected.
  void _armHelloDeadline(BlePeerLink link) {
    link.helloTimer?.cancel();
    link.helloTimer = Timer(_linkHandshakeTimeout, () {
      if (_links.byLinkId(link.linkId) == null) return;
      final session = link.session;
      if (session != null && session.isReady) return; // HELLO completed.
      unawaited(
        _closeLink(
          link,
          error: const BleLinkException('The link setup timed out'),
        ),
      );
    });
  }

  /// Device IDs of authenticated identities must be UUIDs — the format the
  /// local identity and every peer identity are created with.
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// Handles the HELLO frame that arrived on [link], applying the incoming
  /// connection policy for that link alone.
  ///
  /// Multi-connection behavior: the decision (approve, request approval,
  /// reject) is made for this link only; whether this device is the central
  /// or the peripheral on [link] is read from that link's own role, so
  /// simultaneous links in both roles each get their own correct decision.
  Future<void> _handleHelloForLink(BlePeerLink link, BleHello hello) async {
    final session = link.session;
    if (session == null) {
      throw const BleLinkException('The BLE link closed during the handshake');
    }
    final peerRepository = _ref.read(peerRepositoryProvider);
    final existing = await peerRepository.getPeerByPeerId(hello.deviceId);
    final now = DateTime.now();
    _declinedUntil.removeWhere((_, until) => !until.isAfter(now));
    final allowNewConnections = await _ref
        .read(appSettingsRepositoryProvider)
        .getAllowNewConnections();
    if (!_isLiveLink(link, session)) {
      throw const BleLinkException('The BLE link closed during the handshake');
    }

    final decision = decideIncomingConnection(
      locallyInitiated: link.role == BleLinkRole.central,
      existingPeer: existing,
      allowNewConnections: allowNewConnections,
      now: now,
      declinedUntil: _declinedUntil[hello.deviceId],
    );
    switch (decision) {
      case IncomingConnectionDecision.approve:
        await _approveHello(link, hello, existing, session);
      case IncomingConnectionDecision.requestApproval:
        await _beginIncomingRequest(link, hello, session);
      case IncomingConnectionDecision.rejectBlocked:
        throw const BleLinkException('Peer is blocked');
      case IncomingConnectionDecision.rejectDisabled:
        throw const BleLinkException('New connection requests are turned off');
      case IncomingConnectionDecision.rejectCooldown:
        throw const BleLinkException(
          'This device recently declined a connection request',
        );
    }
  }

  /// Binds the approved peer context to [link] after the connection was
  /// approved (explicitly or by the reconnect auto-approve policy).
  ///
  /// The HELLO is an untrusted hint: a stored peer keeps its stored name,
  /// UUID and key untouched, and a first-contact peer exists only in memory
  /// until the authenticated handshake confirms it — approval alone never
  /// writes peer metadata, so a failed handshake leaves nothing behind. Only
  /// this link's context is set; other links keep their own peers.
  Future<void> _approveHello(
    BlePeerLink link,
    BleHello hello,
    Peer? existing,
    BleLinkSession session,
  ) async {
    final now = DateTime.now();
    final Peer peer;
    if (existing != null) {
      peer = existing.copyWith(
        signalStrength: link.remoteRssi ?? existing.signalStrength,
        lastSeen: now,
      );
    } else {
      peer = Peer(
        peerId: hello.deviceId,
        displayName: hello.displayName,
        deviceName: link.remoteDeviceName ?? 'BeChat device',
        status: PeerStatus.offline,
        signalStrength: link.remoteRssi,
        firstSeen: now,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      );
    }
    if (!_isLiveLink(link, session) ||
        session.state == BleSessionState.closed) {
      return;
    }
    if (!_links.bindPeer(link, hello.deviceId)) {
      // Another live link already owns this peer identity: never share one
      // peer across two links, so this link fails closed.
      throw const BleLinkException(
        'This device already holds a connection to that peer',
      );
    }
    link.boundPeer = peer;
    link.remoteDisplayName = peer.displayName;
    _setState(clearError: true);
    unawaited(_refreshPeers());
  }

  /// Records a pending incoming approval request on [link].
  ///
  /// Phase 6 behavior: the request is stored in the per-request collection
  /// keyed by its own request ID, so several peers can await approval at the
  /// same time. No Noise handshake has started, the link is never shown as
  /// connected, and there is no auto-approve — the user's decision is the
  /// only way forward. [link] stays live (its session and transport are kept)
  /// until the decision or the timeout.
  Future<void> _beginIncomingRequest(
    BlePeerLink link,
    BleHello hello,
    BleLinkSession session,
  ) async {
    final now = DateTime.now();
    final request = IncomingConnectionRequest(
      requestId: const Uuid().v4(),
      peerId: hello.deviceId,
      displayName: hello.displayName,
      deviceName: link.remoteDeviceName ?? 'BeChat device',
      signalStrength: link.remoteRssi,
      requestedAt: now,
      expiresAt: now.add(AppConstants.incomingRequestTimeout),
    );
    final timer = Timer(AppConstants.incomingRequestTimeout, () {
      final pending = _incomingRequests[request.requestId];
      if (pending != null) {
        unawaited(_declineRequest(pending, applyCooldown: false));
      }
    });
    _incomingRequests[request.requestId] = _PendingIncomingRequest(
      request: request,
      linkId: link.linkId,
      session: session,
      timer: timer,
    );
    _resetCandidateTracking(updateState: false);
    _setState(candidates: const [], clearError: true);
    if (!_foreground) {
      unawaited(_showIncomingRequestNotification(request));
    }
  }

  /// Handles an inbound application message that arrived on [link], routing
  /// it to that link's own bound peer.
  ///
  /// Multi-connection behavior: the peer is resolved from the receiving
  /// link, so a message on one link can never be attributed to another peer.
  ///
  /// This now delegates to the routing handler which handles both direct
  /// messages (delivered locally) and routing envelopes (forwarded or
  /// delivered locally based on destination).
  Future<BleAckResult> _handleIncomingForLink(
    BlePeerLink link,
    Object payload,
  ) async {
    final peer = link.boundPeer;
    final identity = _ref.read(identityProvider).valueOrNull;
    if (peer == null || identity == null) {
      if (_pendingRequestList().any((r) => r.peerId == link.peerId)) {
        throw const BleLinkException(BleProtocol.approvalPendingReason);
      }
      throw const BleLinkException('The BLE link has no validated peer');
    }

    if (payload is BleRoutingEnvelope) {
      // Built only for envelopes: direct messages must keep working without
      // a local routing identity (localDeviceIdProvider can be null).
      final routingHandler = _getRoutingHandler();

      final (result, _) = await routingHandler.processEnvelope(
        payload,
        incomingPeerId: link.peerId ?? '',
        deliver: (inner, relayedFrom) => _deliverRoutedMessage(
          inner,
          relayedFrom: relayedFrom,
          peer: peer,
          identity: identity,
        ),
      );

      // Convert routing result to ACK result
      final ackResult = switch (result) {
        BleRoutingResult.delivered => BleAckResult.stored,
        BleRoutingResult.queuedForForward => BleAckResult.stored,
        BleRoutingResult.duplicate => BleAckResult.duplicate,
        BleRoutingResult.expired => BleAckResult.rejected,
        BleRoutingResult.hopLimitExhausted => BleAckResult.rejected,
        BleRoutingResult.rejected => BleAckResult.rejected,
      };

      unawaited(_refreshIncoming(peer));
      return ackResult;
    } else if (payload is BleMessagePayload) {
      // Handle direct message via existing handler
      final handler = BleIncomingMessageHandler(
        identity: identity,
        store: BleMessageStore(),
        onStored: (storedPayload, receipt) => _notifyIncomingMessage(
          payload: storedPayload,
          peer: peer,
          receipt: receipt,
        ),
      );
      final result = await handler.handle(
        payload,
        peer: peer,
        linkedPeerId: peer.peerId,
      );
      unawaited(_refreshIncoming(peer));
      return result;
    } else {
      throw const BleLinkException('Unknown payload type');
    }
  }

  /// Delivers a routing envelope's inner payload through the existing
  /// incoming-message pipeline (same store transaction, same validation as a
  /// direct message).
  ///
  /// Identity: the authenticated immediate relay ([peer], [linkedPeerId]) is
  /// the peer/chat context; the envelope's claimed origin travels only as
  /// [relayedFrom] for a consistency check inside the handler. The origin is
  /// NOT authenticated and is never used to resolve a peer or conversation.
  /// Validation failures map to rejected — a message is never stored under a
  /// weakened check.
  ///
  /// shortcut: the message is stored in the relay's chat with the unverified
  /// origin as senderId, so the 1:1 UI shows the relay as the conversation
  /// partner and cannot prove who really wrote it — upgrade to true origin
  /// attribution when end-to-end authenticated payloads exist (deferred E2EE).
  Future<BleRoutingResult> _deliverRoutedMessage(
    BleMessagePayload payload, {
    required String relayedFrom,
    required Peer peer,
    required Identity identity,
  }) async {
    try {
      final handler = BleIncomingMessageHandler(
        identity: identity,
        store: BleMessageStore(),
        onStored: (storedPayload, receipt) => _notifyIncomingMessage(
          payload: storedPayload,
          peer: peer,
          receipt: receipt,
        ),
      );
      final ack = await handler.handle(
        payload,
        peer: peer,
        linkedPeerId: peer.peerId,
        relayedFrom: relayedFrom,
      );
      return switch (ack) {
        BleAckResult.stored => BleRoutingResult.delivered,
        BleAckResult.duplicate => BleRoutingResult.duplicate,
        BleAckResult.rejected => BleRoutingResult.rejected,
      };
    } on BleProtocolException {
      return BleRoutingResult.rejected;
    }
  }

  /// Accepts the pending request with ID [requestId], which authorizes that
  /// request's own link and — for a secure link — starts its Noise handshake.
  ///
  /// Only the link that carried this request is affected: other pending
  /// requests and their links, and every other established link, keep running
  /// independently. Approval never marks the peer connected or secure-ready;
  /// for a secure link those follow the confirmed handshake via
  /// [_publishSecureLink], and for a legacy link they follow this method.
  Future<void> acceptIncomingRequest(String requestId) async {
    final pending = _currentIncomingRequest(requestId);
    if (pending == null) {
      throw const BleLinkException(
        'This connection request is no longer available',
      );
    }
    final request = pending.request;
    final link = _links.byLinkId(pending.linkId);
    final session = pending.session;
    if (link == null || !_isSessionUsableForApproval(session)) {
      _removePendingRequest(requestId);
      throw const BleLinkException('The BLE link is no longer active');
    }

    final peerRepository = _ref.read(peerRepositoryProvider);
    final existing = await peerRepository.getPeerByPeerId(request.peerId);
    if (existing?.isBlocked == true || existing?.status == PeerStatus.blocked) {
      _removePendingRequest(requestId);
      await _closeLink(link);
      throw const BleLinkException('Peer is blocked');
    }

    final now = DateTime.now();
    final peer = Peer(
      peerId: request.peerId,
      displayName: request.displayName,
      deviceName: request.deviceName,
      status: PeerStatus.offline,
      signalStrength: request.signalStrength,
      firstSeen: existing?.firstSeen ?? now,
      lastSeen: now,
      publicKey: existing?.publicKey,
      createdAt: existing?.createdAt,
      updatedAt: now,
    );
    await peerRepository.upsertPeer(peer);
    if (!_isLiveLink(link, session) || !_isSessionUsableForApproval(session)) {
      await _markPeerOffline(peer.peerId);
      _removePendingRequest(requestId);
      throw const BleLinkException('The BLE link closed before approval');
    }

    // Bind the approved peer to this link only, then drop this one request.
    if (!_links.bindPeer(link, peer.peerId)) {
      _removePendingRequest(requestId);
      await _closeLink(link);
      throw const BleLinkException(
        'This device already holds a connection to that peer',
      );
    }
    link.boundPeer = peer;
    link.remoteDisplayName = peer.displayName;
    link.remoteDeviceName = peer.deviceName;
    _removePendingRequest(requestId);
    _resetCandidateTracking(updateState: false);
    _setState();
    if (session.secure != null) {
      try {
        await _startSecureHandshake(link, session);
      } catch (error) {
        if (_links.byLinkId(link.linkId) != null) {
          await _closeLink(link);
        }
        throw BleLinkException(_describeError(error));
      }
      return;
    }
    // Legacy (non-secure) link: publish readiness directly. Secure links
    // never reach here — their readiness only follows a confirmed handshake.
    _setState(
      status: BleRuntimeStatus.connected,
      candidates: const [],
      clearError: true,
    );
    await _markPeerOnline(peer.peerId, signalStrength: peer.signalStrength);
    if (!_isLiveLink(link, session) || !session.isReady) {
      await _markPeerOffline(peer.peerId);
      return;
    }
    try {
      await _ref.read(chatRepositoryProvider).getOrCreateChatForPeer(peer);
      await _ref.read(chatListProvider.notifier).refreshChats();
    } catch (_) {}
    unawaited(_refreshPeers());
    unawaited(requestDelivery(peer.peerId));
  }

  /// Denies the pending request with ID [requestId]: that request's link is
  /// torn down and a decline cooldown is recorded for that peer. Other
  /// pending requests and links are unaffected.
  Future<void> declineIncomingRequest(String requestId) async {
    final pending = _currentIncomingRequest(requestId);
    if (pending == null) {
      throw const BleLinkException(
        'This connection request is no longer available',
      );
    }
    await _declineRequest(pending, applyCooldown: true);
  }

  /// Denies every currently pending request. Kept for the single-request UI
  /// path that dismisses whatever is showing; each request is denied
  /// independently and its own link torn down.
  Future<void> declinePendingIncomingRequest() async {
    final pending = _incomingRequests.values.toList();
    for (final entry in pending) {
      try {
        await declineIncomingRequest(entry.request.requestId);
      } catch (_) {}
    }
  }

  /// Blocks the requesting peer and tears down the link that carried the
  /// request with ID [requestId]. Other pending requests, peers and links are
  /// unaffected.
  Future<void> blockIncomingRequest(String requestId) async {
    final pending = _currentIncomingRequest(requestId);
    if (pending == null) {
      throw const BleLinkException(
        'This connection request is no longer available',
      );
    }
    final request = pending.request;
    await _ref
        .read(peerRepositoryProvider)
        .blockPeer(
          request.peerId,
          displayName: request.displayName,
          deviceName: request.deviceName,
          signalStrength: request.signalStrength,
        );
    _removePendingRequest(requestId);
    unawaited(_refreshPeers());
    final link = _links.byLinkId(pending.linkId);
    if (link != null) {
      await _closeLink(link);
    }
    _setState();
  }

  /// Resolves the pending request with ID [requestId] from the collection,
  /// validating that its own link is still usable for approval. An expired or
  /// orphaned request is removed (and its link torn down) and null is
  /// returned, so a decision can never act on a dead link.
  _PendingIncomingRequest? _currentIncomingRequest(String requestId) {
    final pending = _incomingRequests[requestId];
    if (pending == null) return null;
    if (pending.request.isExpired) {
      unawaited(_declineRequest(pending, applyCooldown: false));
      return null;
    }
    final link = _links.byLinkId(pending.linkId);
    if (link == null || !_isSessionUsableForApproval(pending.session)) {
      _removePendingRequest(requestId);
      return null;
    }
    return pending;
  }

  /// Denies one pending request: removes it from the collection, optionally
  /// applies the decline cooldown for that peer, and tears down the link that
  /// carried the request. Every other pending request and link is untouched.
  Future<void> _declineRequest(
    _PendingIncomingRequest pending, {
    required bool applyCooldown,
  }) async {
    if (applyCooldown) {
      _declinedUntil[pending.request.peerId] = DateTime.now().add(
        AppConstants.declineCooldown,
      );
    }
    _removePendingRequest(pending.request.requestId);
    final link = _links.byLinkId(pending.linkId);
    if (link != null) {
      await _closeLink(link);
    }
    _setState();
  }

  /// Removes a single pending request from the collection and releases its
  /// own timer and notification. Other pending requests are untouched.
  _PendingIncomingRequest? _removePendingRequest(String requestId) {
    final pending = _incomingRequests.remove(requestId);
    if (pending == null) return null;
    pending.timer.cancel();
    unawaited(_cancelIncomingRequestNotification(pending.request));
    return pending;
  }

  /// Clears every pending request and releases each one's own resources.
  void _clearAllIncomingRequests() {
    final pending = _incomingRequests.values.toList();
    _incomingRequests.clear();
    for (final entry in pending) {
      entry.timer.cancel();
      unawaited(_cancelIncomingRequestNotification(entry.request));
    }
    if (!_disposed && pending.isNotEmpty) {
      _setState();
    }
  }

  Future<void> _markPeerOffline(String peerId) async {
    try {
      await _ref.read(peerRepositoryProvider).markPeerOffline(peerId);
      await _refreshPeers();
    } catch (_) {}
  }

  Future<void> _markPeerOnline(String peerId, {int? signalStrength}) async {
    try {
      await _ref
          .read(peerRepositoryProvider)
          .markPeerOnline(peerId, signalStrength: signalStrength);
      await _refreshPeers();
    } catch (_) {}
  }

  Future<void> _refreshIncoming(Peer peer) async {
    try {
      final chat = await _ref
          .read(chatRepositoryProvider)
          .getChatByPeerId(peer.peerId);
      await _ref.read(chatListProvider.notifier).refreshChats();
      await _ref.read(peerListProvider.notifier).refreshPeers();
      if (chat != null) {
        await _ref
            .read(messageListProvider(chat.chatId).notifier)
            .refreshMessages();
      }
    } catch (_) {}
  }

  Future<void> _refreshMessageStatus(Message message) async {
    try {
      await _ref.read(chatListProvider.notifier).refreshChats();
      await _ref
          .read(messageListProvider(message.chatId).notifier)
          .refreshMessages();
    } catch (_) {}
  }

  Future<void> _refreshPeers() async {
    try {
      await _ref.read(peerListProvider.notifier).refreshPeers();
    } catch (_) {}
  }

  Future<void> _resetOutbox() async {
    final localDeviceId = _ref.read(localDeviceIdProvider);
    if (localDeviceId == null) return;
    await _ref
        .read(messageRepositoryProvider)
        .resetOutboxForSender(localDeviceId);
    await _ref.read(chatListProvider.notifier).refreshChats();
  }

  /// Requeues only [peerId]'s undelivered outgoing messages back to queued
  /// when that peer's link closes, so they retry on a later reconnect. Other
  /// peers' queued messages are untouched and keep draining over their own
  /// links.
  Future<void> _resetOutboxForPeer(String? peerId) async {
    if (peerId == null) return;
    final localDeviceId = _ref.read(localDeviceIdProvider);
    if (localDeviceId == null) return;
    try {
      await _ref
          .read(messageRepositoryProvider)
          .resetOutboxForSender(localDeviceId);
      await _ref.read(chatListProvider.notifier).refreshChats();
    } catch (_) {}
  }

  /// Stops advertising (used only for availability shutdown and Bluetooth-off,
  /// never because a link came up — advertising keeps running while linked so
  /// more peers can discover and connect).
  Future<void> _stopAdvertising() async {
    if (!_advertising) return;
    try {
      await _peripheral.stopAdvertising();
    } catch (_) {}
    _advertising = false;
  }

  /// Completes link establishment for [link] in secure mode.
  ///
  /// Nothing here marks the link connected: when an approval request is
  /// pending, the Noise handshake waits for the user's decision; otherwise
  /// the authorized handshake starts and readiness is published later by
  /// [_publishSecureLink] after authentication and explicit confirmation.
  ///
  /// Advertising is deliberately left running (Phase 4): this device keeps
  /// discoverable so additional peers can establish their own links while
  /// [link] is active.
  Future<void> _beginSecureLink(
    BlePeerLink link,
    BleLinkSession session,
    BleHello hello,
  ) async {
    if (!_isLiveLink(link, session)) return;
    _linkEstablishing.remove(link.linkId);
    link.helloTimer?.cancel();
    link.helloTimer = null;
    if (!_canContinueBle) {
      await _closeLink(link);
      return;
    }
    _resetCandidateTracking(updateState: false);
    if (_pendingRequestList().any(
      (request) => request.peerId == hello.deviceId,
    )) {
      // Approval pending on this link: no handshake, no connected state, no
      // presence monitoring and no outbox drain for this peer until the user
      // accepts. Other links are unaffected.
      _setState(candidates: const [], clearError: true);
      return;
    }
    final peer = link.boundPeer;
    if (peer == null || peer.peerId != hello.deviceId) {
      // No approved peer context for this link: fail closed instead of
      // starting a handshake against an unapproved peer.
      await _closeLink(link);
      return;
    }
    await _startSecureHandshake(link, session);
  }

  /// Routes a central-role (outgoing) connection state change to the link
  /// that owns that peripheral, if one exists.
  void _handleCentralConnection(
    PeripheralConnectionStateChangedEventArgs event,
  ) {
    final key = event.peripheral.uuid.toString();
    if (event.state == ConnectionState.connected) {
      final waiter = _connectionWaiters.remove(key);
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      return;
    }
    final waiter = _connectionWaiters.remove(key);
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(
        const BleLinkException(
          'The peer disconnected during connection setup.',
        ),
      );
    }
    _clearTeardownPending(key);
    // Tear down only the link that owns this peripheral; every other link is
    // untouched.
    final link = _links.byLinkId(key);
    if (link != null) {
      unawaited(_closeLink(link));
    }
  }

  /// Routes a peripheral-role (incoming) connection state change to the link
  /// that owns that central. A disconnect tears down only that link.
  void _handlePeripheralConnection(
    CentralConnectionStateChangedEventArgs event,
  ) {
    if (event.state == ConnectionState.connected) return;
    final link = _links.byLinkId(event.central.uuid.toString());
    if (link != null) {
      unawaited(_closeLink(link));
    }
  }

  /// Handles an inbound GATT write, routing it to the link owned by the
  /// writing central.
  ///
  /// Writes that arrive before a link (and its session) exists are buffered
  /// per link and replayed into that link's transport on session creation, so
  /// no link ever consumes another's early writes.
  Future<void> _handlePeripheralWrite(
    GATTCharacteristicWriteRequestedEventArgs event,
  ) async {
    if (event.characteristic.uuid != _rxUuid) {
      try {
        await _peripheral.respondWriteRequestWithError(
          event.request,
          error: GATTError.writeNotPermitted,
        );
      } catch (_) {}
      return;
    }
    try {
      await _peripheral.respondWriteRequest(event.request);
    } catch (_) {
      return;
    }

    final key = event.central.uuid.toString();
    final link = _links.byLinkId(key);
    if (link != null) {
      final transport = link.transport;
      if (transport is _PeripheralValueTransport) {
        transport.add(event.request.value);
        return;
      }
    }
    // No link (or no transport) for this central yet: buffer the write on the
    // link if it exists, otherwise in the shared pre-link buffer, and cap the
    // size so an unapproved central cannot exhaust memory.
    final buffer = link?.pendingWrites;
    if (buffer != null) {
      if (buffer.length < 64) {
        buffer.add(Uint8List.fromList(event.request.value));
      }
      return;
    }
    if (!_pendingCentralWrites.containsKey(key) &&
        _pendingCentralWrites.length >= 8) {
      return;
    }
    final pending = _pendingCentralWrites.putIfAbsent(key, () => []);
    if (pending.length < 64) {
      pending.add(Uint8List.fromList(event.request.value));
    }
  }

  /// Handles a notify-state change for the TX characteristic.
  ///
  /// Multi-connection behavior: an established link for this central is left
  /// alone, and — unlike the single-link build — a second (or Nth) incoming
  /// central is never disconnected just because another link exists. Each
  /// central gets its own independent link, so this device holds as many
  /// incoming links as the connection limit allows.
  Future<void> _handleNotifyStateChanged(
    GATTCharacteristicNotifyStateChangedEventArgs event,
  ) async {
    if (event.characteristic.uuid != _txUuid) return;
    if (!event.state) {
      // Notifications stopped for this central: tear down only its link.
      final link = _links.byLinkId(event.central.uuid.toString());
      if (link != null && link.role == BleLinkRole.peripheral) {
        unawaited(_closeLink(link));
      }
      return;
    }
    final key = event.central.uuid.toString();
    if (_links.byLinkId(key) != null || _linkEstablishing.contains(key)) {
      // This central already has a live or establishing link; do not create
      // a second one for the same device.
      return;
    }
    if (_links.length >= bleMaxLinkCount) {
      // Graceful exhaustion: refuse only this new central, keep existing links.
      try {
        await _peripheral.disconnect(event.central);
      } catch (_) {}
      return;
    }

    final link = BlePeerLink(
      linkId: key,
      role: BleLinkRole.peripheral,
      central: event.central,
      remoteDeviceName:
          'BeChat device ${event.central.uuid.toString().split('-').last}',
      createdAt: _clock(),
    );
    if (!_links.add(link)) return;
    _linkEstablishing.add(key);
    _setState();

    try {
      final maxNotifyLength = await _peripheral.getMaximumNotifyLength(
        event.central,
      );
      final transport = _PeripheralValueTransport(
        manager: _peripheral,
        central: event.central,
        characteristic: event.characteristic,
        maximumWriteLength: maxNotifyLength,
      );
      link.transport = transport;
      // Replay any writes that arrived for this central before its link and
      // transport existed, in arrival order.
      final pending = _pendingCentralWrites.remove(key) ?? const <Uint8List>[];
      for (final value in pending) {
        transport.add(value);
      }
      for (final value in link.pendingWrites) {
        transport.add(value);
      }
      link.pendingWrites.clear();
      final session = _createSession(transport, BleLinkRole.peripheral, link);
      link.session = session;
      final hello = await session.start(
        onHello: (hello) => _handleHelloForLink(link, hello),
        onMessage: (payload) => _handleIncomingForLink(link, payload),
        onRoutingEnvelope: (envelope) =>
            _handleIncomingForLink(link, envelope),
      );
      await _beginSecureLink(link, session, hello);
    } catch (error) {
      _linkEstablishing.remove(key);
      await _closeLink(link, error: error);
      try {
        await _peripheral.disconnect(event.central);
      } catch (_) {}
      if (!_disposed) {
        final rejected = error is BleHelloRejectedException;
        // Only surface a failure when no other link is carrying a connection;
        // one rejected central never disturbs the others.
        if (!rejected && !_links.isEmpty) {
          _setState(
            error: 'Incoming connection failed: ${_describeError(error)}',
          );
        } else if (rejected) {
          _setState(clearError: true);
        } else {
          _setState(
            status: _canContinueBle
                ? BleRuntimeStatus.ready
                : BleRuntimeStatus.idle,
            error: 'Incoming connection failed: ${_describeError(error)}',
          );
        }
      }
    } finally {
      _linkEstablishing.remove(key);
    }
  }

  /// Cleans up [link] after its own session closed.
  ///
  /// Multi-connection behavior: only [link]'s resources are released — its
  /// presence monitor, its GATT gate, its timers and its buffers. Every other
  /// link keeps its own session, presence and delivery untouched. A secure
  /// session that stopped for any reason other than a clean close or a policy
  /// rejection surfaces an explicit failure, so the user never mistakes a
  /// torn-down secure link for a usable one.
  Future<void> _onSessionClosed(
    BlePeerLink link,
    BleLinkSession session,
    Object? error,
  ) async {
    // A late callback from a session that was already replaced (or whose
    // cleanup already ran) must never tear down the current link's state,
    // presence monitoring or peer status.
    if (!identical(link.session, session)) return;
    if (link.isClosed) return;
    await _closeLink(link, error: error, sessionClosed: true);
  }

  /// Starts (or replaces) [link]'s own presence monitor.
  ///
  /// Each central-role link owns exactly one monitor; starting one for a link
  /// never touches another link's monitor. Generation counters guard late
  /// callbacks so a stopped link's callbacks can never affect a new monitor.
  void _startPresenceMonitor(BlePeerLink link) {
    final previous = link.presenceMonitor;
    previous?.stop();
    final generation = ++link.presenceGeneration;
    final monitor = BlePresenceMonitor(
      probe: () => _probeCentralLink(link),
      onSignal: (rssi) => _handlePresenceSignal(link, rssi, generation),
      onLost: (reason) => _handlePresenceLoss(link, reason, generation),
      foregroundInterval: AppConstants.presenceForegroundInterval,
      backgroundInterval: AppConstants.presenceBackgroundInterval,
      probeTimeout: AppConstants.presenceProbeTimeout,
    );
    link.presenceMonitor = monitor;
    monitor.start(foreground: _foreground);
  }

  /// Probes [link]'s own central connection for signal strength, using that
  /// link's own GATT gate so a busy link never blocks another link's probe.
  Future<BlePresenceProbeResult> _probeCentralLink(BlePeerLink link) async {
    final session = link.session;
    final peripheral = link.peripheral;
    if (session == null ||
        peripheral == null ||
        link.role != BleLinkRole.central ||
        !session.isReady ||
        link.gate.isClosed ||
        _teardownPendingByDevice.containsKey(link.linkId)) {
      return const BlePresenceProbeResult.skipped();
    }
    final operation = link.gate.tryRun(() async {
      if (!identical(link.session, session) || !session.isReady) {
        throw const BleLinkClosedException(
          'The BLE link closed before the presence probe',
        );
      }
      return _central.readRSSI(peripheral);
    });
    if (operation == null) {
      return const BlePresenceProbeResult.skipped();
    }
    try {
      return BlePresenceProbeResult.signal(await operation);
    } catch (_) {
      return const BlePresenceProbeResult.failed();
    }
  }

  /// Handles a fresh signal from [link]'s own presence monitor: updates only
  /// that link's RSSI and that peer's stored signal strength.
  void _handlePresenceSignal(BlePeerLink link, int rssi, int generation) {
    if (generation != link.presenceGeneration || link.isClosed) return;
    final peerId = link.peerId;
    if (peerId == null) return;
    link.remoteRssi = rssi;
    final bound = link.boundPeer;
    if (bound != null) {
      link.boundPeer = bound.copyWith(signalStrength: rssi);
    }
    _setState();
    unawaited(
      _ref
          .read(peerRepositoryProvider)
          .updateSignalStrength(peerId, rssi)
          .catchError((Object _) {}),
    );
  }

  /// Handles loss of [link]'s own presence: tears down only that link. A
  /// "stuck" loss records the teardown-pending marker for this device so a
  /// reconnect is refused until recovery, mirroring the single-link policy but
  /// scoped to this link alone.
  Future<void> _handlePresenceLoss(
    BlePeerLink link,
    BlePresenceLossReason reason,
    int generation,
  ) async {
    if (generation != link.presenceGeneration || link.isClosed) return;
    if (reason == BlePresenceLossReason.stuck) {
      final key = link.linkId;
      _teardownPendingByDevice[key] = link.peerId;
      final peerId = link.peerId;
      if (peerId != null) {
        _teardownPendingByDevice[peerId] = key;
      }
    }
    await _closeLink(link);
  }

  void _clearTeardownPending(String deviceKey) {
    final related = _teardownPendingByDevice.remove(deviceKey);
    if (related != null) {
      _teardownPendingByDevice.remove(related);
    }
  }

  /// Tears down a single link and releases everything that link owns.
  ///
  /// Closes that link's session (releasing its native Noise handle), stops
  /// its presence monitor, closes its GATT gate, cancels its timers, and — by
  /// role — disconnects that one remote device. Other links are never touched.
  /// Safe to call repeatedly; a link that is already gone is a no-op.
  Future<void> _closeLink(
    BlePeerLink link, {
    Object? error,
    bool sessionClosed = false,
  }) async {
    final closingPeerId = link.peerId;
    final role = link.role;
    final peripheral = link.peripheral;
    final central = link.central;
    final session = link.session;
    // Release the link's own resources first: presence, timers, gate. This
    // also marks it closed so late callbacks from its session are ignored.
    _links.remove(link);
    _linkEstablishing.remove(link.linkId);
    _handshakeDeadlines.remove(link.linkId)?.cancel();
    link.release();
    if (identical(_primaryLinkId, link.linkId)) {
      _primaryLinkId = null;
    }

    // Close the session (and its Noise handle) unless it already closed.
    if (session != null &&
        !sessionClosed &&
        session.state != BleSessionState.closed) {
      try {
        await session.close(error);
      } catch (_) {}
    }

    // A secure session that stopped for any reason other than a clean close
    // or a policy rejection surfaces an explicit failure — but only when no
    // other link is still carrying a connection, so one peer's failure never
    // disturbs another peer's healthy link.
    final secureFailure =
        session?.secure != null &&
        error != null &&
        error is! BleLinkClosedException &&
        error is! BleHelloRejectedException;
    if (!_disposed && !_isTerminalStatus(state.status)) {
      // Status is derived from the links that remain: connected only while a
      // secure link survives this teardown, otherwise back to ready (or idle
      // when BLE can no longer continue). A link closing can never leave the
      // runtime claiming a connection it no longer holds.
      final remainingStatus = _links.hasSecureLink
          ? BleRuntimeStatus.connected
          : (_canContinueBle ? BleRuntimeStatus.ready : BleRuntimeStatus.idle);
      _setState(
        status: remainingStatus,
        candidates: const [],
        error: secureFailure
            ? 'Secure connection failed: ${_describeError(error)}'
            : null,
        clearError:
            !secureFailure &&
            (error is BleLinkClosedException ||
                error is BleHelloRejectedException),
      );
    }

    if (closingPeerId != null) {
      await _markPeerOffline(closingPeerId);
    }
    // Requeue only this peer's undelivered messages; other peers' queues are
    // untouched and keep draining over their own links.
    await _resetOutboxForPeer(closingPeerId);

    if (role == BleLinkRole.central && peripheral != null) {
      await _disconnectCentral(peripheral);
    } else if (role == BleLinkRole.peripheral && central != null) {
      try {
        await _peripheral.disconnect(central);
      } catch (_) {}
    }

    // Recover advertising if this was the last link and we can still operate;
    // a secure failure must stay visible after recovery finishes.
    if (_links.isEmpty && _canContinueBle && _initialized && !_disposed) {
      await _recoverAdvertising();
      if (secureFailure && !_disposed) {
        _setState(error: 'Secure connection failed: ${_describeError(error)}');
      }
    }
  }

  /// Tears down every link, each independently, and disconnects every remote
  /// device. Used for availability shutdown, Bluetooth-off, disposal and the
  /// global disconnect. Each link releases its own resources; no link's
  /// cleanup depends on another's.
  Future<void> _closeAllLinks() async {
    // Snapshot the registry, then close each link through the normal path so
    // every link's cleanup (session, presence, gate, buffers, disconnect) runs
    // exactly once and identically to a single-link teardown.
    final links = _links.links.values.toList();
    for (final link in links) {
      await _closeLink(link);
    }
    _primaryLinkId = null;
    _setState();
  }

  /// Disconnects every link (same as a global disconnect).
  Future<void> disconnect() async {
    await _closeAllLinks();
  }

  /// Disconnects only [peerId]'s link, leaving every other peer connected.
  Future<void> disconnectPeer(String peerId) async {
    final link = _linkFor(peerId);
    if (link == null) return;
    await _closeLink(link);
  }

  Future<void> _disconnectCentral(Peripheral peripheral) async {
    final address = peripheral.uuid.toString();
    final inFlight = _centralTeardowns[address];
    if (inFlight != null) {
      // One teardown per device: a second caller awaits the same future
      // instead of racing the plugin's address-keyed state again.
      await inFlight;
      return;
    }
    final teardown = () async {
      try {
        await _central
            .disconnect(peripheral)
            .timeout(AppConstants.gattTeardownTimeout);
      } catch (_) {}
    }();
    _centralTeardowns[address] = teardown;
    try {
      await teardown;
    } finally {
      _centralTeardowns.remove(address);
    }
  }

  Future<void> _stopDiscoveryOnly() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (_discovering) {
      _discovering = false;
      try {
        await _central.stopDiscovery();
      } catch (_) {}
    }
  }

  Future<void> openAppSettings() async {
    try {
      await _central.showAppSettings();
    } catch (_) {
      try {
        await _peripheral.showAppSettings();
      } catch (_) {}
    }
  }

  Future<void> retry() async {
    if (_disposed || !_availabilityEnabled) return;
    final inFlight = _startFuture;
    if (inFlight != null) {
      await inFlight;
    } else {
      await ensureStarted();
    }
    if (_disposed || !_foreground || state.status != BleRuntimeStatus.ready) {
      return;
    }
    await startScan();
  }

  /// Pauses foreground BLE operation, keeping established links alive when
  /// background mode is active.
  ///
  /// Phase 9 behavior: every link is handled independently. When background
  /// mode can keep operating, all established links are preserved (each
  /// switching its own presence monitor to the background interval) rather
  /// than being torn down. When it cannot, every link is closed through the
  /// normal per-link path. No link's secure-ready state is ever fabricated on
  /// resume, and closing links never touches another link's state.
  Future<void> pauseForBackground() async {
    if (_disposed || !_foreground) return;
    final keepActive =
        _backgroundBleEnabled &&
        _backgroundNotificationsAllowed &&
        _backgroundServiceRunning &&
        _isBackgroundOperational(state.status);
    _foreground = false;
    _setState(isForeground: false);
    // Switch every link's own presence monitor to the background interval.
    for (final link in _links.links.values) {
      link.presenceMonitor?.updateForeground(false);
    }
    _clearAllIncomingRequests();
    await stopScan();
    _resetCandidateTracking();
    if (!keepActive) {
      // Background mode cannot operate: close every link independently and
      // stop advertising. Each link releases its own resources.
      await _closeAllLinks();
      await _stopAdvertising();
      if (!_disposed) {
        _setState(status: BleRuntimeStatus.idle, isAdvertising: false);
      }
      if (_backgroundServiceRunning) {
        await _stopBackgroundService();
      } else {
        await _syncBackgroundServiceForState(startIfNeeded: false);
      }
      return;
    }
    // Background mode is operational: keep all established links alive. Only
    // update the publication; no link is closed and no secure-ready state is
    // changed or fabricated.
    if (_links.isEmpty) {
      await _stopAdvertising();
      if (!_disposed) {
        _setState(
          status: BleRuntimeStatus.ready,
          isAdvertising: false,
          clearError: true,
        );
      }
    } else {
      _setState();
    }
    await _updateBackgroundServiceNotification();
  }

  Future<void> resumeFromBackground() async {
    if (_disposed) return;
    _foreground = true;
    _setState(isForeground: true);
    await _cancelConnectionRequestNotification();
    await reconcileBackgroundBle();
    if (!_availabilityEnabled) return;
    final inFlight = _startFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    if (!_startAttempted) return;
    if (!_initialized) {
      await ensureStarted();
      return;
    }

    try {
      final status = await _readPlatformStatus();
      if (!status.leSupported) {
        _resetBleAfterLoss();
        await _closeAllLinks();
        if (!_disposed) {
          _setState(status: BleRuntimeStatus.unsupported);
        }
        return;
      }
      if (!status.permissionsGranted) {
        _resetBleAfterLoss();
        await _closeAllLinks();
        if (_disposed) return;
        _setState(
          status: BleRuntimeStatus.unauthorized,
          canOpenSettings: true,
          error: 'Bluetooth permission was not granted.',
        );
        return;
      }
      if (!status.bluetoothEnabled) {
        _resetBleAfterLoss();
        await _closeAllLinks();
        if (_disposed) return;
        _setState(
          status: BleRuntimeStatus.bluetoothOff,
          error: 'Bluetooth is turned off. Enable it and try again.',
        );
        return;
      }
      if (!status.advertisingSupported) {
        _resetBleAfterLoss();
        await _closeAllLinks();
        if (!_disposed) {
          _setState(status: BleRuntimeStatus.unsupported);
        }
        return;
      }
      if (_links.isEmpty && state.status != BleRuntimeStatus.connecting) {
        await _recoverAdvertising();
      }
    } on BleStatusProbeException catch (error) {
      if (!_disposed && _links.isEmpty) {
        _setState(status: BleRuntimeStatus.error, error: error.message);
      }
    } catch (error) {
      if (!_disposed && _links.isEmpty) {
        _setState(status: BleRuntimeStatus.error, error: _describeError(error));
      }
    }
    // Resume each link's own presence monitor to the foreground interval and
    // probe it now. Each link's monitor is updated independently; a link that
    // lost its peer is torn down by its own monitor, never by this loop, and
    // no secure-ready state is fabricated here.
    for (final link in _links.links.values.toList()) {
      final monitor = link.presenceMonitor;
      if (monitor == null) continue;
      monitor.updateForeground(true);
      unawaited(monitor.checkNow());
    }
    await reconcileBackgroundBle();
  }

  bool _isTerminalStatus(BleRuntimeStatus status) =>
      status == BleRuntimeStatus.unsupported ||
      status == BleRuntimeStatus.unauthorized ||
      status == BleRuntimeStatus.bluetoothOff;

  String _describeError(Object error) {
    if (error is TimeoutException) {
      return 'The operation timed out.';
    }
    if (error is BleSecureHandshakeTimeoutException) {
      return 'A secure connection could not be established in time.';
    }
    if (error is BleAckTimeoutException) {
      return 'The peer stopped acknowledging messages.';
    }
    if (error is BleProtocolException) return error.message;
    if (error is BleLinkException) return error.message;
    if (error is BleLinkClosedException) return error.message;
    // Concise, single-line, never a Java/Dart stack trace: this string is the
    // only thing the Nearby and Settings banners display.
    return describeErrorForUser(error);
  }

  /// Keeps the full detail (native code, Java message, stack) in the log, where
  /// it belongs — the UI only ever receives [describeErrorForUser].
  void _logError(String context, Object error, [StackTrace? stackTrace]) {
    debugPrint('BeChat BLE $context: ${describeErrorDiagnostics(error, stackTrace)}');
  }

  bool _isBackgroundOperational(BleRuntimeStatus status) =>
      status == BleRuntimeStatus.ready ||
      status == BleRuntimeStatus.scanning ||
      status == BleRuntimeStatus.connected;

  void _setBackgroundStatus(BackgroundBleRuntimeStatus status, String? error) {
    if (_disposed) return;
    state = state.copyWith(
      backgroundStatus: status,
      backgroundError: error,
      clearBackgroundError: error == null,
    );
  }

  Future<void> _syncBackgroundServiceForState({
    required bool startIfNeeded,
  }) async {
    if (_disposed) return;
    if (!_backgroundBleEnabled) {
      if (_backgroundServiceRunning) await _stopBackgroundService();
      if (state.backgroundStatus != BackgroundBleRuntimeStatus.disabled) {
        _setBackgroundStatus(BackgroundBleRuntimeStatus.disabled, null);
      }
      return;
    }
    if (!_availabilityEnabled) {
      if (_backgroundServiceRunning) await _stopBackgroundService();
      _setBackgroundStatus(
        BackgroundBleRuntimeStatus.paused,
        'Background mode starts when BeChat is on.',
      );
      return;
    }
    if (!_backgroundNotificationsAllowed) {
      if (_backgroundServiceRunning) await _stopBackgroundService();
      _setBackgroundStatus(
        BackgroundBleRuntimeStatus.permissionDenied,
        'Notification permission is required for background messaging.',
      );
      return;
    }
    if (!_isBackgroundOperational(state.status)) {
      if (_backgroundServiceRunning) {
        await _refreshBackgroundServiceState();
      } else {
        _setBackgroundStatus(
          BackgroundBleRuntimeStatus.paused,
          'Background mode waits for BeChat to be online.',
        );
      }
      return;
    }
    if (_backgroundServiceRunning) {
      _setBackgroundStatus(BackgroundBleRuntimeStatus.active, null);
      await _updateBackgroundServiceNotification();
      return;
    }
    if (!startIfNeeded || !_foreground) return;
    try {
      await _startBackgroundService();
    } catch (error) {
      _setBackgroundStatus(
        BackgroundBleRuntimeStatus.error,
        'Could not start background mode: ${_describeError(error)}',
      );
    }
  }

  Future<void> _startBackgroundService() async {
    if (_disposed || _backgroundServiceRunning || _backgroundStartInFlight) {
      return;
    }
    _setBackgroundStatus(BackgroundBleRuntimeStatus.starting, null);
    _backgroundStartInFlight = true;
    try {
      await _backgroundService.startService(
        statusText: _backgroundNotificationText(state),
      );
    } finally {
      _backgroundStartInFlight = false;
    }
    if (_disposed) return;
    if (state.backgroundStatus == BackgroundBleRuntimeStatus.error) {
      throw BackgroundBleServiceException(
        state.backgroundError ?? 'The background service did not start.',
      );
    }
    _backgroundServiceRunning = true;
    _setBackgroundStatus(BackgroundBleRuntimeStatus.active, null);
  }

  Future<void> _stopBackgroundService({bool force = false}) async {
    final wasRunning = _backgroundServiceRunning;
    _backgroundServiceRunning = false;
    if (!wasRunning && !force) return;
    try {
      await _backgroundService.stopService();
    } catch (_) {}
    if (!_disposed && wasRunning) {
      _setBackgroundStatus(
        _backgroundBleEnabled
            ? BackgroundBleRuntimeStatus.paused
            : BackgroundBleRuntimeStatus.disabled,
        _backgroundBleEnabled
            ? 'Background mode starts when BeChat is on.'
            : null,
      );
    }
  }

  Future<void> _refreshBackgroundServiceState() async {
    if (_disposed || !_backgroundServiceRunning) return;
    switch (state.status) {
      case BleRuntimeStatus.ready:
      case BleRuntimeStatus.scanning:
      case BleRuntimeStatus.connected:
        _setBackgroundStatus(BackgroundBleRuntimeStatus.active, null);
      case BleRuntimeStatus.idle:
      case BleRuntimeStatus.bluetoothOff:
      case BleRuntimeStatus.unauthorized:
      case BleRuntimeStatus.unsupported:
        _setBackgroundStatus(
          BackgroundBleRuntimeStatus.paused,
          _backgroundStatePauseMessage(state.status),
        );
      case BleRuntimeStatus.starting:
      case BleRuntimeStatus.connecting:
        _setBackgroundStatus(BackgroundBleRuntimeStatus.starting, null);
      case BleRuntimeStatus.error:
        _setBackgroundStatus(
          BackgroundBleRuntimeStatus.error,
          state.error ?? 'Background messaging needs attention.',
        );
    }
    await _updateBackgroundServiceNotification();
  }

  String _backgroundStatePauseMessage(BleRuntimeStatus status) {
    return switch (status) {
      BleRuntimeStatus.bluetoothOff =>
        'Bluetooth is off. Background messaging is paused.',
      BleRuntimeStatus.unauthorized =>
        'Bluetooth permission is required. Background messaging is paused.',
      BleRuntimeStatus.unsupported =>
        'BLE is unavailable. Background messaging is paused.',
      BleRuntimeStatus.idle => 'BeChat is off. Background messaging is paused.',
      _ => 'Background messaging is paused.',
    };
  }

  String _backgroundNotificationText(BleRuntimeState current) {
    return switch (current.status) {
      BleRuntimeStatus.ready => 'BeChat is available for nearby messaging.',
      BleRuntimeStatus.scanning =>
        'BeChat is available. Background scanning is paused.',
      BleRuntimeStatus.connected =>
        'Connected to a nearby peer. More messaging is available.',
      BleRuntimeStatus.starting ||
      BleRuntimeStatus.connecting => 'Starting nearby messaging...',
      BleRuntimeStatus.bluetoothOff =>
        'Bluetooth is off. Background messaging is paused.',
      BleRuntimeStatus.unauthorized =>
        'Bluetooth permission is needed. Background messaging is paused.',
      BleRuntimeStatus.unsupported =>
        'BLE is unavailable. Background messaging is paused.',
      BleRuntimeStatus.error =>
        'Background messaging needs attention. Open BeChat for details.',
      BleRuntimeStatus.idle => 'BeChat is off. Background messaging is paused.',
    };
  }

  Future<void> _updateBackgroundServiceNotification() async {
    if (_disposed || !_backgroundServiceRunning) return;
    try {
      await _backgroundService.updateService(
        statusText: _backgroundNotificationText(state),
      );
    } catch (error) {
      if (_disposed || !_backgroundServiceRunning) return;
      _backgroundServiceRunning = false;
      _setBackgroundStatus(
        BackgroundBleRuntimeStatus.error,
        'Background service failed: ${_describeError(error)}',
      );
      if (!_foreground) {
        unawaited(_pauseUnavailableBackground());
      }
    }
  }

  Future<void> _showIncomingRequestNotification(
    IncomingConnectionRequest request,
  ) async {
    if (_disposed || !_backgroundRuntimeActive || _foreground) return;
    try {
      await _backgroundService.showConnectionRequestNotification(
        requestId: request.requestId,
        peerName: request.displayName,
      );
    } catch (_) {}
  }

  Future<void> _cancelIncomingRequestNotification(
    IncomingConnectionRequest? request,
  ) async {
    if (request == null) return;
    try {
      await _backgroundService.cancelConnectionRequestNotification(
        request.requestId,
      );
    } catch (_) {}
  }

  Future<void> _cancelConnectionRequestNotification() =>
      _cancelIncomingRequestNotification(state.incomingRequest);

  Future<void> _notifyIncomingMessage({
    required BleMessagePayload payload,
    required Peer peer,
    required BleIncomingReceipt receipt,
  }) async {
    if (_disposed || _foreground || !_backgroundRuntimeActive) return;
    try {
      final previewsEnabled = await _ref
          .read(appSettingsRepositoryProvider)
          .getMessagePreviewsEnabled();
      await _backgroundService.showMessageNotification(
        messageId: payload.metadata.messageId,
        chatId: receipt.chatId,
        senderName: peer.displayName,
        body: BackgroundNotificationPolicy.messageBody(
          previewsEnabled: previewsEnabled,
          content: payload.content,
        ),
      );
    } catch (_) {}
  }

  /// Publishes a new runtime state.
  ///
  /// Link-derived fields ([BleRuntimeState.links], [BleRuntimeState.incomingRequests]
  /// and the derived single-active-peer views) are always recomputed from the
  /// link registry and the pending-request collection, never passed in, so a
  /// stale or hand-written value can never misrepresent a link's phase. Only
  /// non-link facts (status, candidates, error, advertising, background,
  /// availability) are accepted as parameters.
  void _setState({
    BleRuntimeStatus? status,
    List<BleCandidate>? candidates,
    String? error,
    bool? canOpenSettings,
    bool? isAdvertising,
    bool? isForeground,
    BackgroundBleRuntimeStatus? backgroundStatus,
    String? backgroundError,
    bool? availabilityEnabled,
    bool clearError = false,
    bool clearBackgroundError = false,
  }) {
    if (_disposed) return;
    final primary = _primaryLink;
    state = state.copyWith(
      status: status,
      candidates: candidates,
      error: error,
      canOpenSettings: canOpenSettings,
      isAdvertising: isAdvertising,
      isForeground: isForeground,
      backgroundStatus: backgroundStatus,
      backgroundError: backgroundError,
      availabilityEnabled: availabilityEnabled,
      clearError: clearError,
      clearBackgroundError: clearBackgroundError,
      // Recomputed from the registry: one snapshot per live link.
      links: _links.states(now: _clock()),
      incomingRequests: _pendingRequestList(),
      // Derived single-active-peer compatibility views: the primary link's
      // own values, cleared automatically when no link holds a peer.
      activePeerId: primary?.peerId,
      activePeerName: primary?.remoteDisplayName ?? primary?.remoteDeviceName,
      activeRole: primary?.role,
      activeSignalStrength: primary?.remoteRssi,
      isSecureReady:
          primary != null && primary.phase == BleLinkPhase.secureReady,
      clearActiveLink: primary == null,
    );
    if (_backgroundServiceRunning) {
      unawaited(_refreshBackgroundServiceState());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _scanTimer?.cancel();
    _candidateCleanupTimer?.cancel();
    _relayRetryTimer?.cancel();
    for (final waiter in _connectionWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(const BleLinkException('BLE runtime disposed'));
      }
    }
    _connectionWaiters.clear();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    // Close every link's session so no native Noise handle is leaked, then
    // release the links' own resources (presence, timers, gates).
    for (final link in _links.links.values) {
      unawaited(link.session?.close());
    }
    _links.removeAll();
    super.dispose();
  }
}

class _BeChatCharacteristics {
  const _BeChatCharacteristics({required this.rx, required this.tx});

  final GATTCharacteristic rx;
  final GATTCharacteristic tx;
}

class _CentralValueTransport implements BleTransport {
  _CentralValueTransport({
    required CentralManager manager,
    required this.peripheral,
    required this.characteristic,
    required this.maximumWriteLength,
    required BleGattOperationGate gate,
  }) : _manager = manager,
       _gate = gate;

  final CentralManager _manager;
  final BleGattOperationGate _gate;
  final Peripheral peripheral;
  final GATTCharacteristic characteristic;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  bool _closed = false;

  @override
  final int maximumWriteLength;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  void add(Uint8List value) {
    if (!_closed) _incoming.add(Uint8List.fromList(value));
  }

  @override
  Future<void> write(Uint8List value) async {
    if (_closed) throw const BleLinkClosedException();
    await _gate.run(() async {
      if (_closed) throw const BleLinkClosedException();
      await _manager.writeCharacteristic(
        peripheral,
        characteristic,
        value: value,
        type: GATTCharacteristicWriteType.withResponse,
      );
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}

class _PeripheralValueTransport implements BleTransport {
  _PeripheralValueTransport({
    required PeripheralManager manager,
    required this.central,
    required this.characteristic,
    required this.maximumWriteLength,
  }) : _manager = manager;

  final PeripheralManager _manager;
  final Central central;
  final GATTCharacteristic characteristic;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  bool _closed = false;

  @override
  final int maximumWriteLength;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  void add(Uint8List value) {
    if (!_closed) _incoming.add(Uint8List.fromList(value));
  }

  @override
  Future<void> write(Uint8List value) async {
    if (_closed) throw const BleLinkClosedException();
    await _manager.notifyCharacteristic(central, characteristic, value: value);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}
