import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bechat/core/ble/ble_link_session.dart';
import 'package:bechat/core/ble/ble_protocol.dart';
import 'package:bechat/core/ble/ble_transport.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/ble_candidate.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/message_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/providers/settings_providers.dart';
import 'package:bechat/services/ble/ble_message_store.dart';
import 'package:bechat/services/ble/ble_outbox.dart';
import 'package:bechat/services/ble/ble_status_probe.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  });

  final BleRuntimeStatus status;
  final List<BleCandidate> candidates;
  final String? activePeerId;
  final String? activePeerName;
  final BleLinkRole? activeRole;
  final String? error;
  final bool canOpenSettings;
  final bool isAdvertising;

  bool get isConnected =>
      status == BleRuntimeStatus.connected && activePeerId != null;

  BleRuntimeState copyWith({
    BleRuntimeStatus? status,
    List<BleCandidate>? candidates,
    String? activePeerId,
    String? activePeerName,
    BleLinkRole? activeRole,
    String? error,
    bool? canOpenSettings,
    bool? isAdvertising,
    bool clearActiveLink = false,
    bool clearError = false,
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
  }) : _centralOverride = centralManager,
       _peripheralOverride = peripheralManager,
       _statusProbe = statusProbe ?? MethodChannelBleStatusProbe(),
       _permissionTimeout = permissionTimeout,
       _isAndroidOverride = isAndroidOverride,
       super(const BleRuntimeState()) {
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
  final bool? _isAndroidOverride;
  CentralManager? _centralInstance;
  PeripheralManager? _peripheralInstance;
  late final BleOutbox _outbox;

  CentralManager get _central =>
      _centralInstance ??= _centralOverride ?? CentralManager();
  PeripheralManager get _peripheral =>
      _peripheralInstance ??= _peripheralOverride ?? PeripheralManager();

  final UUID _serviceUuid = UUID.fromString(BleProtocol.serviceUuid);
  final UUID _rxUuid = UUID.fromString(BleProtocol.rxCharacteristicUuid);
  final UUID _txUuid = UUID.fromString(BleProtocol.txCharacteristicUuid);

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, Peripheral> _candidatesById = {};
  final Map<String, Completer<void>> _connectionWaiters = {};
  final Map<String, List<Uint8List>> _pendingCentralWrites = {};

  Timer? _scanTimer;
  Future<void>? _startFuture;
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
    return session != null && session.isReady;
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

  Future<void> ensureStarted() {
    if (_disposed || AppConstants.demoDataEnabled) {
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
    _startAttempted = true;
    _foreground = true;
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
      if (!status.leSupported) {
        _setState(status: BleRuntimeStatus.unsupported);
        return;
      }

      if (!status.permissionsGranted) {
        await _requestPermissions();
        status = await _readPlatformStatus();
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
      if (state.status == BleRuntimeStatus.error) return;
      _initialized = true;
      _setState(
        status: BleRuntimeStatus.ready,
        isAdvertising: _advertising,
        clearError: true,
      );
      await _resetOutbox();
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
    switch (adapterState) {
      case BluetoothLowEnergyState.unsupported:
        _resetBleAfterLoss();
        unawaited(_closeActiveLink());
        _setState(status: BleRuntimeStatus.unsupported, clearActiveLink: true);
      case BluetoothLowEnergyState.unauthorized:
        if (_startFuture != null) return;
        unawaited(_handleUnauthorizedAdapterState());
      case BluetoothLowEnergyState.poweredOff:
        _resetBleAfterLoss();
        unawaited(_closeActiveLink());
        _setState(
          status: BleRuntimeStatus.bluetoothOff,
          error: 'Bluetooth is turned off. Enable it and try again.',
          clearActiveLink: true,
        );
      case BluetoothLowEnergyState.poweredOn:
      case BluetoothLowEnergyState.unknown:
        if (_startFuture != null) return;
        if (_startAttempted && !_initialized && _foreground) {
          unawaited(ensureStarted());
          return;
        }
        if (_initialized &&
            _foreground &&
            !state.isConnected &&
            state.status != BleRuntimeStatus.connecting) {
          unawaited(_recoverAdvertising());
        }
    }
  }

  void _resetBleAfterLoss() {
    _scanTimer?.cancel();
    _scanTimer = null;
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
        if (_foreground &&
            !state.isConnected &&
            state.status != BleRuntimeStatus.connecting) {
          await _recoverAdvertising();
        }
        return;
      }
      if (_startAttempted && _foreground) {
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
    if (_disposed || !_foreground || _advertising) return;
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
    if (AppConstants.demoDataEnabled || _disposed) return;
    await ensureStarted();
    if (_disposed ||
        state.isConnected ||
        state.status == BleRuntimeStatus.scanning ||
        state.status == BleRuntimeStatus.connecting) {
      return;
    }
    if (state.status != BleRuntimeStatus.ready) return;

    _setState(
      status: BleRuntimeStatus.scanning,
      candidates: const [],
      clearError: true,
    );
    _candidatesById.clear();
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
      lastSeen: DateTime.now(),
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
  }

  Future<String?> connectToCandidate(String candidateId) async {
    if (_disposed || _activeSession != null || _linkEstablishing) return null;
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
      final services = await _central.discoverGATT(peripheral);
      final characteristics = _findBeChatCharacteristics(services);
      final tx = characteristics.tx;
      final rx = characteristics.rx;
      final maxWriteLength = await _central.getMaximumWriteLength(
        peripheral,
        type: GATTCharacteristicWriteType.withResponse,
      );
      final transport = _CentralValueTransport(
        manager: _central,
        peripheral: peripheral,
        characteristic: rx,
        maximumWriteLength: maxWriteLength,
      );
      _centralTransport = transport;
      await _enableNotifications(peripheral, tx);
      final session = _createSession(transport, BleLinkRole.central);
      _activeSession = session;
      final hello = await session.start();
      _linkEstablishing = false;
      await _onLinkReady(session, hello);
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
        _setState(
          status: BleRuntimeStatus.error,
          error: 'Connection failed: ${_describeError(error)}',
          clearActiveLink: true,
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

  BleLinkSession _createSession(BleTransport transport, BleLinkRole role) {
    return BleLinkSession(
      transport: transport,
      identity: _requireIdentity(),
      onHello: _handleHello,
      onMessage: _handleIncoming,
      onClosed: (error) {
        unawaited(_onSessionClosed(role, error));
      },
    );
  }

  Future<void> _handleHello(BleHello hello) async {
    final peerRepository = _ref.read(peerRepositoryProvider);
    final existing = await peerRepository.getPeerByPeerId(hello.deviceId);
    if (existing?.isBlocked == true) {
      throw const BleLinkException('Peer is blocked');
    }
    final now = DateTime.now();
    final peer = Peer(
      peerId: hello.deviceId,
      displayName: hello.displayName,
      deviceName: _remoteDeviceName ?? existing?.deviceName ?? 'BeChat device',
      status: PeerStatus.online,
      signalStrength: _remoteRssi,
      firstSeen: existing?.firstSeen ?? now,
      lastSeen: now,
      publicKey: existing?.publicKey,
      createdAt: existing?.createdAt,
      updatedAt: now,
    );
    await peerRepository.upsertPeer(peer);
    _activePeer = peer;
    _remoteDeviceName = peer.deviceName;
    if (!_disposed) {
      _setState(
        activePeerId: peer.peerId,
        activePeerName: peer.displayName,
        activeRole: _activeRole,
      );
      unawaited(_refreshPeers());
    }
  }

  Future<BleAckResult> _handleIncoming(BleMessagePayload payload) async {
    final peer = _activePeer;
    final identity = _ref.read(identityProvider).valueOrNull;
    if (peer == null || identity == null) {
      throw const BleLinkException('The BLE link has no validated peer');
    }
    final handler = BleIncomingMessageHandler(
      identity: identity,
      store: BleMessageStore(),
    );
    final result = await handler.handle(
      payload,
      peer: peer,
      linkedPeerId: peer.peerId,
    );
    unawaited(_refreshIncoming(peer));
    return result;
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

  Future<void> _onLinkReady(BleLinkSession session, BleHello hello) async {
    if (_disposed || _activeSession != session) return;
    _linkEstablishing = false;
    if (!_foreground) {
      await _closeActiveLink();
      return;
    }
    await _stopAdvertisingForLink();
    final role = _activeRole ?? BleLinkRole.central;
    _setState(
      status: BleRuntimeStatus.connected,
      candidates: const [],
      activePeerId: hello.deviceId,
      activePeerName: hello.displayName,
      activeRole: role,
      isAdvertising: false,
      clearError: true,
    );
    unawaited(requestDelivery(hello.deviceId));
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
      await _onLinkReady(session, hello);
    } catch (error) {
      _linkEstablishing = false;
      await _closeActiveLink();
      try {
        await _peripheral.disconnect(event.central);
      } catch (_) {}
      if (!_disposed) {
        _setState(
          status: BleRuntimeStatus.error,
          error: 'Incoming connection failed: ${_describeError(error)}',
          clearActiveLink: true,
        );
      }
    }
  }

  Future<void> _onSessionClosed(BleLinkRole role, Object? error) async {
    if (_cleaningLink) return;
    _cleaningLink = true;
    final cleanup = Completer<void>();
    _linkCleanupCompleter = cleanup;
    try {
      _activeSession = null;
      _activePeer = null;
      _peripheralTransport = null;
      _centralTransport = null;
      final peripheral = _activePeripheral;
      final central = _activeCentral;
      _activePeripheral = null;
      _activeCentral = null;
      _activeRole = null;
      final closingPeerId = state.activePeerId;
      _remoteDeviceName = null;
      _remoteRssi = null;

      if (!_linkEstablishing &&
          !_disposed &&
          !_isTerminalStatus(state.status)) {
        _setState(
          status: _foreground ? BleRuntimeStatus.ready : BleRuntimeStatus.idle,
          candidates: const [],
          clearActiveLink: true,
          clearError: error is BleLinkClosedException,
        );
      }

      if (closingPeerId != null) {
        try {
          await _ref
              .read(peerRepositoryProvider)
              .updatePeerStatus(closingPeerId, PeerStatus.offline);
          await _refreshPeers();
        } catch (_) {}
      }
      await _resetOutbox();

      if (role == BleLinkRole.central && peripheral != null) {
        await _disconnectCentral(peripheral);
      } else if (role == BleLinkRole.peripheral && central != null) {
        try {
          await _peripheral.disconnect(central);
        } catch (_) {}
      }

      if (_foreground && _initialized && !_disposed) {
        await _recoverAdvertising();
      }
    } finally {
      _cleaningLink = false;
      if (!cleanup.isCompleted) cleanup.complete();
      if (identical(_linkCleanupCompleter, cleanup)) {
        _linkCleanupCompleter = null;
      }
    }
  }

  Future<void> _closeActiveLink() async {
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

  Future<void> _disconnectCentral(Peripheral peripheral) async {
    try {
      await _central.disconnect(peripheral);
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
    if (_disposed) return;
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
    _foreground = false;
    await stopScan();
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
  }

  Future<void> resumeFromBackground() async {
    if (_disposed) return;
    _foreground = true;
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
  }

  Identity _requireIdentity() {
    final identity = _ref.read(identityProvider).valueOrNull;
    if (identity == null) {
      throw const BleLinkException('Local identity is not available');
    }
    return identity;
  }

  bool _isTerminalStatus(BleRuntimeStatus status) =>
      status == BleRuntimeStatus.unsupported ||
      status == BleRuntimeStatus.unauthorized ||
      status == BleRuntimeStatus.bluetoothOff;

  String _describeError(Object error) {
    if (error is TimeoutException) {
      return 'The operation timed out.';
    }
    if (error is BleProtocolException) return error.message;
    if (error is BleLinkException) return error.message;
    if (error is BleLinkClosedException) return error.message;
    return error.toString();
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
    bool clearActiveLink = false,
    bool clearError = false,
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
      clearActiveLink: clearActiveLink,
      clearError: clearError,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _scanTimer?.cancel();
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
  }) : _manager = manager;

  final CentralManager _manager;
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
    await _manager.writeCharacteristic(
      peripheral,
      characteristic,
      value: value,
      type: GATTCharacteristicWriteType.withResponse,
    );
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
