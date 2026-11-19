import 'package:bechat/data/models/message.dart';

/// How the online transport currently sees the Firebase backend.
///
/// [ready] is only reached after a *server* acknowledgement — an authenticated
/// session plus a Firestore snapshot that did not come from the local cache —
/// so it reflects real server availability rather than device connectivity.
enum OnlineConnectionState { disconnected, connecting, ready }

/// Seam between [TransportManager] and the real Firestore-backed transport.
///
/// The manager only needs these operations, which lets tests drive it with an
/// in-memory transport: `cloud_firestore` cannot run inside `flutter test`
/// (its plugins are platform channels, not pure Dart).
///
/// Callbacks are plain mutable fields so both the real transport and a test
/// double can hold them; the manager assigns them right after construction.
abstract class OnlineTransport {
  OnlineConnectionState get state;

  bool get isReady => state == OnlineConnectionState.ready;

  /// The manager refreshes its mode from this and treats a transition to
  /// [OnlineConnectionState.ready] as "sync everything still queued".
  void Function(OnlineConnectionState state)? onStateChanged;
  void Function(Map<String, dynamic> frame)? onIncoming;
  void Function(String messageId)? onDelivered;

  /// Authenticates, registers the device and attaches the listeners.
  /// Must never throw: an unavailable backend simply leaves [state] at
  /// [OnlineConnectionState.disconnected].
  Future<void> start();

  Future<void> stop();

  /// Sends one message and resolves once Firestore accepted the write —
  /// which is *not* final recipient delivery (that arrives via [onDelivered]).
  ///
  /// Throws when the backend is unreachable or rejects the write, so the
  /// caller can fall back to BLE.
  Future<void> send(Message message);

  /// Records that the local device persisted [messageId]; the sender is
  /// notified through [onDelivered]. Idempotent.
  void sendDelivered(String messageId);
}
