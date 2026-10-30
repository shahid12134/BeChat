import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_secure_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/core/ble/peer_presence.dart';
import 'package:bechat/core/constants/app_constants.dart';
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
import 'package:bechat/services/ble/ble_gatt_operation_gate.dart';
import 'package:bechat/services/ble/ble_message_store.dart';
import 'package:bechat/services/ble/ble_outbox.dart';
import 'package:bechat/services/ble/ble_presence_monitor.dart';
import 'package:bechat/services/ble/ble_status_probe.dart';
import 'package:bechat/services/ble/incoming_connection_policy.dart';
import 'package:bechat/services/ble/incoming_connection_request.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

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

enum BleLinkRole { central, peripheral }

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
  });

  final BleRuntimeStatus status;
  final List<BleCandidate> candidates;
  final String? activePeerId;
  final String? activePeerName;
  final BleLinkRole? activeRole;
  final String? error;
  final bool canOpenSettings;
  final bool isAdvertising;
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
  /// set it.
  final bool isSecureReady;

  bool get isConnected =>
      status == BleRuntimeStatus.connected && activePeerId != null;

  bool get isBackgroundServiceActive =>
      backgroundStatus == BackgroundBleRuntimeStatus.active;

  PeerPresenceContext get presenceContext => PeerPresenceContext(
    availabilityEnabled: availabilityEnabled,
    localUnavailable:
        status == BleRuntimeStatus.unsupported ||
        status == BleRuntimeStatus.unauthorized ||
        status == BleRuntimeStatus.bluetoothOff,
    connected: isConnected,
    connecting: status == BleRuntimeStatus.connecting,
    activePeerId: activePeerId,
    awaitingApprovalPeerId: incomingRequest?.peerId,
  );

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
    bool clearActiveLink = false,
    bool clearError = false,
    bool clearIncomingRequest = false,
    bool clearBackgroundError = false,
    bool clearActiveSignal = false,
  }) {
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
      incomingRequest: clearIncomingRequest
          ? null
          : incomingRequest ?? this.incomingRequest,
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
    );
  }
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
  final Map<String, List<Uint8List>> _pendingCentralWrites = {};

  Timer? _scanTimer;
  Timer? _candidateCleanupTimer;
  Timer? _incomingRequestTimer;
  BleLinkSession? _incomingRequestSession;
  final Map<String, DateTime> _declinedUntil = {};
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
  bool _linkEstablishing = false;
  bool _cleaningLink = false;
  Completer<void>? _linkCleanupCompleter;
  bool _disposed = false;
  BleGattOperationGate _centralGate = BleGattOperationGate();
  BlePresenceMonitor? _presenceMonitor;
  int _presenceGeneration = 0;
  final Map<String, String?> _teardownPendingByDevice = {};

  BleLinkSession? _activeSession;
  BleLinkRole? _activeRole;
  Peripheral? _activePeripheral;
  Central? _activeCentral;
  _PeripheralValueTransport? _peripheralTransport;
  _CentralValueTransport? _centralTransport;
  Peer? _activePeer;
  String? _remoteDeviceName;
  int? _remoteRssi;

  bool _isLinkUsable() {
    final session = _activeSession;
    if (session == null || !session.isReady) return false;
    // A secure session only carries application traffic once the link was
    // published as secure-ready (handshake + authenticated identity + key
    // policy + explicit confirmation). Legacy sessions keep the old rule.
    if (session.secure != null && !state.isSecureReady) return false;
    return true;
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

  Future<BleAckResult> _sendOverLink(
    Message message, {
    Future<void> Function()? onTransmitted,
  }) {
    final session = _activeSession;
    if (session == null ||
        !session.isReady ||
        session.linkInfo?.deviceId != message.receiverId) {
      throw const BleLinkClosedException('No usable BLE link for this peer');
    }
    return session.sendMessage(message, onTransmitted: onTransmitted);
  }

  Future<void> requestDelivery(String peerId) async {
    final localDeviceId = _ref.read(localDeviceIdProvider);
    if (localDeviceId == null || !_isLinkUsable()) return;
    if (_activeSession?.linkInfo?.deviceId != peerId) return;
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
        clearActiveLink: true,
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
    await _closeActiveLink();
    if (_advertising) {
      try {
        await _peripheral.stopAdvertising();
      } catch (_) {}
      _advertising = false;
    }
    _setState(
      status: BleRuntimeStatus.idle,
      isAdvertising: false,
      clearActiveLink: true,
    );
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
    _clearIncomingRequest();
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
    _pendingCentralWrites.clear();
    _declinedUntil.clear();
    final peripheral = _activePeripheral;
    final central = _activeCentral;
    await _closeActiveLink();
    if (peripheral != null) {
      await _disconnectCentral(peripheral);
    }
    if (central != null) {
      try {
        await _peripheral.disconnect(central);
      } catch (_) {}
    }
    await _stopAdvertisingForLink();
    await _stopDiscoveryOnly();
    await _stopBackgroundService();
    _resetBleAfterLoss();
    _resetCandidateTracking(updateState: false);
    _setState(
      status: BleRuntimeStatus.idle,
      candidates: const [],
      isAdvertising: false,
      clearActiveLink: true,
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
        final transport = _centralTransport;
        if (transport == null) return;
        if (event.peripheral.uuid != transport.peripheral.uuid) return;
        if (event.characteristic.uuid != _txUuid) return;
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
        unawaited(_closeActiveLink());
        _setState(status: BleRuntimeStatus.unsupported, clearActiveLink: true);
      case BluetoothLowEnergyState.unauthorized:
        if (_startFuture != null) return;
        unawaited(_handleUnauthorizedAdapterState());
      case BluetoothLowEnergyState.poweredOff:
        _teardownPendingByDevice.clear();
        _resetBleAfterLoss();
        unawaited(_closeActiveLink());
        _setState(
          status: BleRuntimeStatus.bluetoothOff,
          error: 'Bluetooth is turned off. Enable it and try again.',
          clearActiveLink: true,
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
    _clearIncomingRequest();
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
        await _closeActiveLink();
        if (!_disposed) {
          _setState(
            status: BleRuntimeStatus.unsupported,
            clearActiveLink: true,
          );
        }
        return;
      }
      if (!status.permissionsGranted) {
        _resetBleAfterLoss();
        await _closeActiveLink();
        if (_disposed) return;
        _setState(
          status: BleRuntimeStatus.unauthorized,
          canOpenSettings: true,
          error: 'Bluetooth permission was not granted.',
          clearActiveLink: true,
        );
        return;
      }
      if (!status.bluetoothEnabled) {
        _resetBleAfterLoss();
        await _closeActiveLink();
        if (_disposed) return;
        _setState(
          status: BleRuntimeStatus.bluetoothOff,
          error: 'Bluetooth is turned off. Enable it and try again.',
          clearActiveLink: true,
        );
        return;
      }
      if (!status.advertisingSupported) {
        _resetBleAfterLoss();
        await _closeActiveLink();
        if (!_disposed) {
          _setState(
            status: BleRuntimeStatus.unsupported,
            clearActiveLink: true,
          );
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
    if (_disposed ||
        !_availabilityEnabled ||
        state.isConnected ||
        _activeSession != null ||
        _linkEstablishing ||
        state.status == BleRuntimeStatus.scanning ||
        state.status == BleRuntimeStatus.connecting) {
      return;
    }
    if (state.status != BleRuntimeStatus.ready) return;

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
    if (!_disposed &&
        !state.isConnected &&
        state.status == BleRuntimeStatus.scanning) {
      _setState(status: BleRuntimeStatus.ready);
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

  Future<String?> connectToCandidate(String candidateId) async {
    if (_disposed ||
        !_availabilityEnabled ||
        _activeSession != null ||
        _linkEstablishing) {
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

    _linkEstablishing = true;
    _activeRole = BleLinkRole.central;
    _activePeripheral = peripheral;
    _activeCentral = null;
    _remoteDeviceName = state.candidates
        .where((candidate) => candidate.id == candidateId)
        .map((candidate) => candidate.displayName)
        .firstOrNull;
    _remoteRssi = state.candidates
        .where((candidate) => candidate.id == candidateId)
        .map((candidate) => candidate.rssi)
        .firstOrNull;

    await _stopDiscoveryOnly();
    _setState(
      status: BleRuntimeStatus.connecting,
      activePeerName: _remoteDeviceName,
      activeRole: BleLinkRole.central,
      clearError: true,
    );

    final waiter = Completer<void>();
    _connectionWaiters[peripheral.uuid.toString()] = waiter;
    unawaited(waiter.future.catchError((Object _) {}));
    try {
      await _central.connect(peripheral).timeout(const Duration(seconds: 15));
      await waiter.future.timeout(const Duration(seconds: 15));
      if (!_availabilityEnabled) {
        throw const BleLinkException('BeChat was turned off');
      }
      final services = await _central.discoverGATT(peripheral);
      final characteristics = _findBeChatCharacteristics(services);
      final tx = characteristics.tx;
      final rx = characteristics.rx;
      final maxWriteLength = await _central.getMaximumWriteLength(
        peripheral,
        type: GATTCharacteristicWriteType.withResponse,
      );
      _centralGate = BleGattOperationGate();
      final transport = _CentralValueTransport(
        manager: _central,
        peripheral: peripheral,
        characteristic: rx,
        maximumWriteLength: maxWriteLength,
        gate: _centralGate,
      );
      _centralTransport = transport;
      await _enableNotifications(peripheral, tx);
      if (!_availabilityEnabled) {
        throw const BleLinkException('BeChat was turned off');
      }
      final session = _createSession(transport, BleLinkRole.central);
      _activeSession = session;
      final hello = await session.start();
      if (!_availabilityEnabled) {
        throw const BleLinkException('BeChat was turned off');
      }
      _linkEstablishing = false;
      await _beginSecureLink(session, hello);
      return hello.deviceId;
    } catch (error) {
      _connectionWaiters.remove(peripheral.uuid.toString());
      _linkEstablishing = false;
      await _closeActiveLink();
      await _disconnectCentral(peripheral);
      _activePeripheral = null;
      _activeCentral = null;
      _activeRole = null;
      _remoteDeviceName = null;
      _remoteRssi = null;
      if (!_disposed) {
        final turnedOff = !_availabilityEnabled;
        _setState(
          status: turnedOff ? BleRuntimeStatus.idle : BleRuntimeStatus.error,
          error: turnedOff
              ? null
              : 'Connection failed: ${_describeError(error)}',
          clearActiveLink: true,
          clearError: turnedOff,
        );
      }
      return null;
    }
  }

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
      () => _central.setCharacteristicNotifyState(
        peripheral,
        characteristic,
        state: true,
      ),
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

  /// Creates the runtime's link session in secure mode.
  ///
  /// Every production session requires the Noise capability: once secure
  /// messaging is selected there is no plaintext application path. The
  /// session reference is captured by the callbacks so late events (close,
  /// remote identity, key conflict) are always attributable to one specific
  /// session instance and a replaced session can never publish state.
  BleLinkSession _createSession(BleTransport transport, BleLinkRole role) {
    final identity = _requireSecureIdentity();
    late final BleLinkSession session;
    session = BleLinkSession(
      transport: transport,
      identity: identity,
      onHello: _handleHello,
      onMessage: _handleIncoming,
      onClosed: (error) {
        unawaited(_onSessionClosed(session, role, error));
      },
      // The runtime deadline doubles as the session's internal secure
      // handshake budget, so injected short timeouts cover both layers.
      handshakeTimeout: _linkHandshakeTimeout,
      secure: _buildSecureSessionConfig(
        role,
        onRemoteIdentity: (remote) =>
            _handleSecureRemoteIdentity(session, remote),
        onPinnedKeyMismatch: () => _recordActivePeerKeyConflict(session),
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

  /// Records that a pinned peer presented a different authenticated key,
  /// preserving the original pin and fingerprint (see
  /// [PeerRepository.recordKeyConflict]).
  Future<void> _recordActivePeerKeyConflict(BleLinkSession session) async {
    if (_disposed || !identical(_activeSession, session)) return;
    final peerId = _activePeer?.peerId ?? state.activePeerId;
    if (peerId == null) return;
    try {
      await _ref.read(peerRepositoryProvider).recordKeyConflict(peerId);
      await _refreshPeers();
    } catch (_) {
      // The link still fails closed below; bookkeeping must not mask it.
    }
  }

  /// Validates the authenticated remote identity, applies the peer-key
  /// policy, explicitly confirms the Noise session, and publishes the link.
  ///
  /// Invoked inside the session's inbound-frame queue before any later frame
  /// is processed, so no application payload can precede this decision. Every
  /// check fails closed; nothing unauthenticated is persisted, existing peer
  /// metadata is never overwritten, and `verified` is never assigned here.
  Future<void> _handleSecureRemoteIdentity(
    BleLinkSession session,
    RemoteAuthenticatedIdentity remote,
  ) async {
    if (_disposed || !identical(_activeSession, session)) {
      throw const BleLinkException(
        'The BLE link closed during the secure handshake',
      );
    }
    final knownPeer = _activePeer;
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
      // the database and the session never becomes usable.
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
    if (_disposed || !identical(_activeSession, session)) {
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

    await _publishSecureLink(session, remote);
  }

  /// Publishes a confirmed, secure link: connected state, secure-ready flag,
  /// peer online status, chat creation, presence monitoring and outbox
  /// draining — all of which stay dark until this point.
  Future<void> _publishSecureLink(
    BleLinkSession session,
    RemoteAuthenticatedIdentity remote,
  ) async {
    if (_disposed || !identical(_activeSession, session)) return;
    final peer = _activePeer;
    if (peer == null || peer.peerId != remote.deviceId) return;
    final role = _activeRole ?? BleLinkRole.central;
    final published = peer.copyWith(
      // The authenticated identity is authoritative for the display name.
      displayName: remote.displayName,
      status: PeerStatus.online,
      signalStrength: peer.signalStrength ?? _remoteRssi,
    );
    _activePeer = published;
    _setState(
      status: BleRuntimeStatus.connected,
      candidates: const [],
      activePeerId: published.peerId,
      activePeerName: remote.displayName,
      activeRole: role,
      isAdvertising: false,
      isSecureReady: true,
      clearError: true,
    );
    await _markPeerOnline(published.peerId, signalStrength: _remoteRssi);
    if (_disposed ||
        !identical(_activeSession, session) ||
        !session.isSecureReady) {
      await _markPeerOffline(published.peerId);
      return;
    }
    try {
      await _ref.read(chatRepositoryProvider).getOrCreateChatForPeer(published);
      await _ref.read(chatListProvider.notifier).refreshChats();
    } catch (_) {}
    if (role == BleLinkRole.central) {
      _startPresenceMonitor(published.peerId);
    }
    unawaited(requestDelivery(published.peerId));
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

  /// Authorizes and starts the Noise handshake for an approved link.
  ///
  /// Binds the peer-specific context (pinned key + expected device ID) after
  /// the HELLO exchange and before the handshake, then waits for local
  /// setup within the runtime deadline. Readiness is *not* published here:
  /// [_publishSecureLink] runs only after the handshake authenticates the
  /// peer and the native session is explicitly confirmed.
  Future<void> _startSecureHandshake(BleLinkSession session) async {
    if (_disposed || !identical(_activeSession, session)) return;
    final peer = _activePeer;
    if (peer == null) return;
    if (session.secureState != BleSecureLinkState.awaitingAuthorization) {
      return;
    }
    _setState(
      status: BleRuntimeStatus.connecting,
      candidates: const [],
      clearError: true,
    );
    try {
      session.bindSecurePeerContext(
        pinnedRemotePublicKey: _resolvePinnedPeerKey(peer),
        expectedPeerDeviceId: peer.peerId,
      );
      await session.startSecureHandshake().timeout(_linkHandshakeTimeout);
    } catch (error) {
      // Ensure every local handshake failure tears the link down; a session
      // that already failed closed is left alone. There is no plaintext
      // fallback from here.
      if (session.state != BleSessionState.closed) {
        await session.close(error);
      }
      rethrow;
    }
  }

  /// Device IDs of authenticated identities must be UUIDs — the format the
  /// local identity and every peer identity are created with.
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  Future<void> _handleHello(BleHello hello) async {
    final session = _activeSession;
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
    if (!identical(_activeSession, session)) {
      throw const BleLinkException('The BLE link closed during the handshake');
    }

    final decision = decideIncomingConnection(
      locallyInitiated: _activeRole == BleLinkRole.central,
      existingPeer: existing,
      allowNewConnections: allowNewConnections,
      now: now,
      declinedUntil: _declinedUntil[hello.deviceId],
    );
    switch (decision) {
      case IncomingConnectionDecision.approve:
        await _approveHello(hello, existing, session);
      case IncomingConnectionDecision.requestApproval:
        await _beginIncomingRequest(hello, session);
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

  Future<void> _approveHello(
    BleHello hello,
    Peer? existing,
    BleLinkSession session,
  ) async {
    final now = DateTime.now();
    // The HELLO is an untrusted hint: a stored peer keeps its stored name,
    // UUID and key untouched, and a first-contact peer exists only in memory
    // until the authenticated handshake confirms it — approval alone never
    // writes peer metadata, so a failed handshake leaves nothing behind.
    final Peer peer;
    if (existing != null) {
      peer = existing.copyWith(
        signalStrength: _remoteRssi ?? existing.signalStrength,
        lastSeen: now,
      );
    } else {
      peer = Peer(
        peerId: hello.deviceId,
        displayName: hello.displayName,
        deviceName: _remoteDeviceName ?? 'BeChat device',
        status: PeerStatus.offline,
        signalStrength: _remoteRssi,
        firstSeen: now,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      );
    }
    if (_disposed ||
        !identical(_activeSession, session) ||
        session.state == BleSessionState.closed) {
      return;
    }
    _activePeer = peer;
    _remoteDeviceName = peer.deviceName;
    _setState(
      activePeerId: peer.peerId,
      activePeerName: peer.displayName,
      activeRole: _activeRole,
      clearIncomingRequest: true,
    );
    unawaited(_refreshPeers());
  }

  Future<void> _beginIncomingRequest(
    BleHello hello,
    BleLinkSession session,
  ) async {
    final previousRequest = state.incomingRequest;
    if (previousRequest != null) {
      unawaited(_cancelIncomingRequestNotification(previousRequest));
    }
    final now = DateTime.now();
    final request = IncomingConnectionRequest(
      requestId: const Uuid().v4(),
      peerId: hello.deviceId,
      displayName: hello.displayName,
      deviceName: _remoteDeviceName ?? 'BeChat device',
      signalStrength: _remoteRssi,
      requestedAt: now,
      expiresAt: now.add(AppConstants.incomingRequestTimeout),
    );
    _incomingRequestSession = session;
    _resetCandidateTracking(updateState: false);
    _incomingRequestTimer?.cancel();
    _incomingRequestTimer = Timer(AppConstants.incomingRequestTimeout, () {
      final current = state.incomingRequest;
      if (current?.requestId == request.requestId) {
        unawaited(_declineRequest(current!, applyCooldown: false));
      }
    });
    _setState(
      status: BleRuntimeStatus.ready,
      candidates: const [],
      incomingRequest: request,
      isAdvertising: false,
      clearActiveLink: true,
      clearError: true,
    );
    if (!_foreground) {
      unawaited(_showIncomingRequestNotification(request));
    }
  }

  Future<BleAckResult> _handleIncoming(BleMessagePayload payload) async {
    final peer = _activePeer;
    final identity = _ref.read(identityProvider).valueOrNull;
    if (peer == null || identity == null) {
      if (state.incomingRequest != null) {
        throw const BleLinkException(BleProtocol.approvalPendingReason);
      }
      throw const BleLinkException('The BLE link has no validated peer');
    }
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
  }

  Future<void> acceptIncomingRequest(String requestId) async {
    final request = _currentIncomingRequest(requestId);
    if (request == null) {
      throw const BleLinkException(
        'This connection request is no longer available',
      );
    }
    final session = _activeSession;
    if (session == null || !_isSessionUsableForApproval(session)) {
      _clearIncomingRequest();
      throw const BleLinkException('The BLE link is no longer active');
    }

    final peerRepository = _ref.read(peerRepositoryProvider);
    final existing = await peerRepository.getPeerByPeerId(request.peerId);
    if (existing?.isBlocked == true || existing?.status == PeerStatus.blocked) {
      _clearIncomingRequest();
      await _closeActiveLink();
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
    if (_disposed ||
        !identical(_activeSession, session) ||
        !_isSessionUsableForApproval(session)) {
      await _markPeerOffline(peer.peerId);
      _clearIncomingRequest();
      throw const BleLinkException('The BLE link closed before approval');
    }

    _activePeer = peer;
    _remoteDeviceName = peer.deviceName;
    _clearIncomingRequest();
    _resetCandidateTracking(updateState: false);
    if (session.secure != null) {
      // Approval only authorizes the Noise handshake. Connected state, peer
      // presence, the secure-ready flag and outbox draining all follow the
      // confirmed handshake via _publishSecureLink — never here.
      try {
        await _startSecureHandshake(session);
      } catch (error) {
        if (identical(_activeSession, session)) {
          await _closeActiveLink();
        }
        throw BleLinkException(_describeError(error));
      }
      return;
    }
    _setState(
      status: BleRuntimeStatus.connected,
      candidates: const [],
      activePeerId: peer.peerId,
      activePeerName: peer.displayName,
      activeRole: _activeRole,
      isAdvertising: false,
      clearError: true,
      clearIncomingRequest: true,
    );
    await _markPeerOnline(peer.peerId, signalStrength: peer.signalStrength);
    if (_disposed || !identical(_activeSession, session) || !session.isReady) {
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

  Future<void> declineIncomingRequest(String requestId) async {
    final request = _currentIncomingRequest(requestId);
    if (request == null) {
      throw const BleLinkException(
        'This connection request is no longer available',
      );
    }
    await _declineRequest(request, applyCooldown: true);
  }

  Future<void> declinePendingIncomingRequest() async {
    final request = state.incomingRequest;
    if (request == null) return;
    try {
      await declineIncomingRequest(request.requestId);
    } catch (_) {}
  }

  Future<void> blockIncomingRequest(String requestId) async {
    final request = _currentIncomingRequest(requestId);
    if (request == null) {
      throw const BleLinkException(
        'This connection request is no longer available',
      );
    }
    final session = _activeSession;
    await _ref
        .read(peerRepositoryProvider)
        .blockPeer(
          request.peerId,
          displayName: request.displayName,
          deviceName: request.deviceName,
          signalStrength: request.signalStrength,
        );
    _clearIncomingRequest();
    unawaited(_refreshPeers());
    if (session != null && identical(_activeSession, session)) {
      await _closeActiveLink();
    }
  }

  IncomingConnectionRequest? _currentIncomingRequest(String requestId) {
    final request = state.incomingRequest;
    if (request == null || request.requestId != requestId) return null;
    if (request.isExpired) {
      unawaited(_declineRequest(request, applyCooldown: false));
      return null;
    }
    final session = _activeSession;
    if (session == null ||
        !_isSessionUsableForApproval(session) ||
        !identical(session, _incomingRequestSession)) {
      _clearIncomingRequest();
      return null;
    }
    return request;
  }

  Future<void> _declineRequest(
    IncomingConnectionRequest request, {
    required bool applyCooldown,
  }) async {
    if (applyCooldown) {
      _declinedUntil[request.peerId] = DateTime.now().add(
        AppConstants.declineCooldown,
      );
    }
    _clearIncomingRequest();
    await _closeActiveLink();
  }

  void _clearIncomingRequest() {
    final request = state.incomingRequest;
    _incomingRequestTimer?.cancel();
    _incomingRequestTimer = null;
    _incomingRequestSession = null;
    if (!_disposed && request != null) {
      _setState(clearIncomingRequest: true);
      unawaited(_cancelIncomingRequestNotification(request));
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

  /// Completes link establishment in secure mode.
  ///
  /// This replaces the legacy "link is ready" publication: nothing here marks
  /// the link connected. When an approval request is pending, the Noise
  /// handshake waits for the user's decision; otherwise the authorized
  /// handshake starts and readiness is published later by
  /// [_publishSecureLink] after authentication and explicit confirmation.
  Future<void> _beginSecureLink(BleLinkSession session, BleHello hello) async {
    if (_disposed || _activeSession != session) return;
    _linkEstablishing = false;
    if (!_canContinueBle) {
      await _closeActiveLink();
      return;
    }
    await _stopAdvertisingForLink();
    _resetCandidateTracking(updateState: false);
    if (state.incomingRequest?.peerId == hello.deviceId) {
      // Approval pending: no handshake, no connected state, no presence
      // monitoring and no outbox drain until the user accepts.
      _setState(
        status: BleRuntimeStatus.ready,
        candidates: const [],
        isAdvertising: false,
        clearActiveLink: true,
        clearError: true,
      );
      return;
    }
    final peer = _activePeer;
    if (peer == null || peer.peerId != hello.deviceId) {
      // No approved peer context for this link: fail closed instead of
      // starting a handshake against an unapproved peer.
      await _closeActiveLink();
      return;
    }
    await _startSecureHandshake(session);
  }

  Future<void> _stopAdvertisingForLink() async {
    if (!_advertising) return;
    try {
      await _peripheral.stopAdvertising();
    } catch (_) {}
    _advertising = false;
  }

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
    _pendingCentralWrites.remove(key);
    final activePeripheral = _activePeripheral;
    if (activePeripheral != null &&
        activePeripheral.uuid == event.peripheral.uuid) {
      unawaited(_closeActiveLink());
    }
  }

  void _handlePeripheralConnection(
    CentralConnectionStateChangedEventArgs event,
  ) {
    if (event.state == ConnectionState.connected) return;
    _pendingCentralWrites.remove(event.central.uuid.toString());
    final activeCentral = _activeCentral;
    if (activeCentral != null && activeCentral.uuid == event.central.uuid) {
      unawaited(_closeActiveLink());
    }
  }

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
    if (_activeRole == BleLinkRole.peripheral &&
        _activeCentral != null &&
        _activeCentral!.uuid == event.central.uuid) {
      _peripheralTransport?.add(event.request.value);
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

  Future<void> _handleNotifyStateChanged(
    GATTCharacteristicNotifyStateChangedEventArgs event,
  ) async {
    if (event.characteristic.uuid != _txUuid) return;
    if (!event.state) {
      if (_activeRole == BleLinkRole.peripheral &&
          _activeCentral?.uuid == event.central.uuid) {
        unawaited(_closeActiveLink());
      }
      return;
    }
    final cleanup = _linkCleanupCompleter;
    if (cleanup != null) {
      await cleanup.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      if (_disposed) return;
    }
    if (_activeRole == BleLinkRole.peripheral &&
        _activeCentral?.uuid == event.central.uuid &&
        (_activeSession != null || _linkEstablishing)) {
      return;
    }
    if (_activeSession != null || _linkEstablishing) {
      try {
        await _peripheral.disconnect(event.central);
      } catch (_) {}
      return;
    }

    _linkEstablishing = true;
    _activeRole = BleLinkRole.peripheral;
    _activeCentral = event.central;
    _activePeripheral = null;
    _remoteDeviceName =
        'BeChat device ${event.central.uuid.toString().split('-').last}';
    _remoteRssi = null;

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
      _peripheralTransport = transport;
      final session = _createSession(transport, BleLinkRole.peripheral);
      _activeSession = session;
      final pending = _pendingCentralWrites.remove(
        event.central.uuid.toString(),
      );
      for (final value in pending ?? const <Uint8List>[]) {
        transport.add(value);
      }
      final hello = await session.start();
      _linkEstablishing = false;
      await _beginSecureLink(session, hello);
    } catch (error) {
      _linkEstablishing = false;
      await _closeActiveLink();
      try {
        await _peripheral.disconnect(event.central);
      } catch (_) {}
      if (!_disposed) {
        final rejected = error is BleHelloRejectedException;
        _setState(
          status: rejected
              ? (_canContinueBle
                    ? BleRuntimeStatus.ready
                    : BleRuntimeStatus.idle)
              : BleRuntimeStatus.error,
          error: rejected
              ? null
              : 'Incoming connection failed: ${_describeError(error)}',
          clearActiveLink: true,
          clearError: rejected,
        );
      }
    }
  }

  Future<void> _onSessionClosed(
    BleLinkSession session,
    BleLinkRole role,
    Object? error,
  ) async {
    // A late callback from a session that was already replaced (or whose
    // cleanup already ran) must never tear down the current link's state,
    // presence monitoring or peer status.
    if (!identical(_activeSession, session)) return;
    if (_cleaningLink) return;
    _cleaningLink = true;
    final cleanup = Completer<void>();
    _linkCleanupCompleter = cleanup;
    try {
      final closingPeerId = _activePeer?.peerId ?? state.activePeerId;
      _stopPresenceMonitor();
      _centralGate.close();
      _activeSession = null;
      _activePeer = null;
      _peripheralTransport = null;
      _centralTransport = null;
      final peripheral = _activePeripheral;
      final central = _activeCentral;
      _activePeripheral = null;
      _activeCentral = null;
      _activeRole = null;
      _remoteDeviceName = null;
      _remoteRssi = null;
      _clearIncomingRequest();
      _resetCandidateTracking(updateState: false);

      // A secure session that stopped for any reason other than a clean
      // close or a policy rejection surfaces an explicit failure — the user
      // must never mistake a torn-down secure link for a usable one.
      final secureFailure =
          session.secure != null &&
          error != null &&
          error is! BleLinkClosedException &&
          error is! BleHelloRejectedException;
      if (!_linkEstablishing &&
          !_disposed &&
          !_isTerminalStatus(state.status)) {
        _setState(
          status: _canContinueBle
              ? BleRuntimeStatus.ready
              : BleRuntimeStatus.idle,
          candidates: const [],
          clearActiveLink: true,
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
      await _resetOutbox();

      if (role == BleLinkRole.central && peripheral != null) {
        await _disconnectCentral(peripheral);
      } else if (role == BleLinkRole.peripheral && central != null) {
        try {
          await _peripheral.disconnect(central);
        } catch (_) {}
      }

      if (_canContinueBle && _initialized && !_disposed) {
        await _recoverAdvertising();
        // Advertising recovery clears the error field; a secure failure
        // must stay visible, so republish it after recovery finished.
        if (secureFailure && !_disposed) {
          _setState(
            error: 'Secure connection failed: ${_describeError(error)}',
          );
        }
      }
    } finally {
      _cleaningLink = false;
      if (!cleanup.isCompleted) cleanup.complete();
      if (identical(_linkCleanupCompleter, cleanup)) {
        _linkCleanupCompleter = null;
      }
    }
  }

  void _startPresenceMonitor(String peerId) {
    _presenceMonitor?.stop();
    final generation = ++_presenceGeneration;
    final monitor = BlePresenceMonitor(
      probe: _probeActiveCentralLink,
      onSignal: (rssi) => _handlePresenceSignal(rssi, generation),
      onLost: (reason) => _handlePresenceLoss(reason, generation),
      foregroundInterval: AppConstants.presenceForegroundInterval,
      backgroundInterval: AppConstants.presenceBackgroundInterval,
      probeTimeout: AppConstants.presenceProbeTimeout,
    );
    _presenceMonitor = monitor;
    monitor.start(foreground: _foreground);
  }

  void _stopPresenceMonitor() {
    _presenceGeneration++;
    _presenceMonitor?.stop();
    _presenceMonitor = null;
  }

  Future<BlePresenceProbeResult> _probeActiveCentralLink() async {
    final session = _activeSession;
    final peripheral = _activePeripheral;
    if (session == null ||
        peripheral == null ||
        _activeRole != BleLinkRole.central ||
        !session.isReady ||
        _centralGate.isClosed ||
        _teardownPendingByDevice.containsKey(peripheral.uuid.toString())) {
      return const BlePresenceProbeResult.skipped();
    }
    final operation = _centralGate.tryRun(() async {
      if (!identical(_activeSession, session) || !session.isReady) {
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

  void _handlePresenceSignal(int rssi, int generation) {
    if (generation != _presenceGeneration ||
        !state.isConnected ||
        _activeRole != BleLinkRole.central) {
      return;
    }
    _activePeer = _activePeer?.copyWith(signalStrength: rssi);
    _setState(activeSignalStrength: rssi);
    final peerId = state.activePeerId;
    if (peerId == null) return;
    unawaited(
      _ref
          .read(peerRepositoryProvider)
          .updateSignalStrength(peerId, rssi)
          .catchError((Object _) {}),
    );
  }

  Future<void> _handlePresenceLoss(
    BlePresenceLossReason reason,
    int generation,
  ) async {
    if (generation != _presenceGeneration ||
        !state.isConnected ||
        _activeRole != BleLinkRole.central) {
      return;
    }
    final peripheral = _activePeripheral;
    if (reason == BlePresenceLossReason.stuck) {
      final peerId = state.activePeerId;
      final key = peripheral?.uuid.toString();
      if (key != null) {
        _teardownPendingByDevice[key] = peerId;
      }
      if (peerId != null) {
        _teardownPendingByDevice[peerId] = key;
      }
    }
    await _closeActiveLink();
    if (peripheral != null) {
      await _disconnectCentral(peripheral);
    }
  }

  void _clearTeardownPending(String deviceKey) {
    final related = _teardownPendingByDevice.remove(deviceKey);
    if (related != null) {
      _teardownPendingByDevice.remove(related);
    }
  }

  Future<void> _closeActiveLink() async {
    _stopPresenceMonitor();
    _centralGate.close();
    final session = _activeSession;
    if (session == null) {
      _centralTransport = null;
      _peripheralTransport = null;
      return;
    }
    await session.close();
  }

  Future<void> disconnect() async {
    await _closeActiveLink();
    final peripheral = _activePeripheral;
    if (peripheral != null) await _disconnectCentral(peripheral);
  }

  Future<void> disconnectPeer(String peerId) async {
    if (state.activePeerId != peerId && _activePeer?.peerId != peerId) return;
    await disconnect();
  }

  Future<void> _disconnectCentral(Peripheral peripheral) async {
    try {
      await _central
          .disconnect(peripheral)
          .timeout(AppConstants.gattTeardownTimeout);
    } catch (_) {}
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

  Future<void> pauseForBackground() async {
    if (_disposed || !_foreground) return;
    final keepActive =
        _backgroundBleEnabled &&
        _backgroundNotificationsAllowed &&
        _backgroundServiceRunning &&
        _isBackgroundOperational(state.status);
    _foreground = false;
    _setState(isForeground: false);
    _presenceMonitor?.updateForeground(false);
    _clearIncomingRequest();
    await stopScan();
    _resetCandidateTracking();
    if (!keepActive) {
      await _closeActiveLink();
      if (_advertising) {
        try {
          await _peripheral.stopAdvertising();
        } catch (_) {}
        _advertising = false;
      }
      if (!_disposed) {
        _setState(
          status: BleRuntimeStatus.idle,
          isAdvertising: false,
          clearActiveLink: true,
        );
      }
      if (_backgroundServiceRunning) {
        await _stopBackgroundService();
      } else {
        await _syncBackgroundServiceForState(startIfNeeded: false);
      }
      return;
    }
    if (state.isConnected) return;
    if (_advertising) {
      try {
        await _peripheral.stopAdvertising();
      } catch (_) {}
      _advertising = false;
    }
    if (!_disposed) {
      _setState(
        status: BleRuntimeStatus.ready,
        isAdvertising: false,
        clearError: true,
      );
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
        await _closeActiveLink();
        if (!_disposed) {
          _setState(
            status: BleRuntimeStatus.unsupported,
            clearActiveLink: true,
          );
        }
        return;
      }
      if (!status.permissionsGranted) {
        _resetBleAfterLoss();
        await _closeActiveLink();
        if (_disposed) return;
        _setState(
          status: BleRuntimeStatus.unauthorized,
          canOpenSettings: true,
          error: 'Bluetooth permission was not granted.',
          clearActiveLink: true,
        );
        return;
      }
      if (!status.bluetoothEnabled) {
        _resetBleAfterLoss();
        await _closeActiveLink();
        if (_disposed) return;
        _setState(
          status: BleRuntimeStatus.bluetoothOff,
          error: 'Bluetooth is turned off. Enable it and try again.',
          clearActiveLink: true,
        );
        return;
      }
      if (!status.advertisingSupported) {
        _resetBleAfterLoss();
        await _closeActiveLink();
        if (!_disposed) {
          _setState(
            status: BleRuntimeStatus.unsupported,
            clearActiveLink: true,
          );
        }
        return;
      }
      if (!state.isConnected && state.status != BleRuntimeStatus.connecting) {
        await _recoverAdvertising();
      }
    } on BleStatusProbeException catch (error) {
      if (!_disposed && !state.isConnected) {
        _setState(status: BleRuntimeStatus.error, error: error.message);
      }
    } catch (error) {
      if (!_disposed && !state.isConnected) {
        _setState(status: BleRuntimeStatus.error, error: _describeError(error));
      }
    }
    final monitor = _presenceMonitor;
    if (monitor != null && state.isConnected) {
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
    return error.toString();
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

  void _setState({
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
    bool clearActiveLink = false,
    bool clearError = false,
    bool clearIncomingRequest = false,
    bool clearBackgroundError = false,
    bool clearActiveSignal = false,
  }) {
    if (_disposed) return;
    state = state.copyWith(
      status: status,
      candidates: candidates,
      activePeerId: activePeerId,
      activePeerName: activePeerName,
      activeRole: activeRole,
      error: error,
      canOpenSettings: canOpenSettings,
      isAdvertising: isAdvertising,
      incomingRequest: incomingRequest,
      isForeground: isForeground,
      backgroundStatus: backgroundStatus,
      backgroundError: backgroundError,
      availabilityEnabled: availabilityEnabled,
      activeSignalStrength: activeSignalStrength,
      isSecureReady: isSecureReady,
      clearActiveLink: clearActiveLink,
      clearError: clearError,
      clearIncomingRequest: clearIncomingRequest,
      clearBackgroundError: clearBackgroundError,
      clearActiveSignal: clearActiveSignal,
    );
    if (_backgroundServiceRunning) {
      unawaited(_refreshBackgroundServiceState());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPresenceMonitor();
    _centralGate.close();
    _scanTimer?.cancel();
    _candidateCleanupTimer?.cancel();
    _incomingRequestTimer?.cancel();
    for (final waiter in _connectionWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(const BleLinkException('BLE runtime disposed'));
      }
    }
    _connectionWaiters.clear();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_activeSession?.close());
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
