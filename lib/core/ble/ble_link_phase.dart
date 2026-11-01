/// The BLE link role one device holds on a single connection.
///
/// A device acts as [central] when it connects outward (and maps to the Noise
/// responder), and as [peripheral] when it accepts an incoming connection
/// (and maps to the Noise initiator). In the multi-connection architecture a
/// device holds both roles at the same time, one per link.
enum BleLinkRole { central, peripheral }

///
/// Every BLE link moves through this lifecycle independently: one peer's
/// handshake failure or teardown never changes another peer's phase. Only
/// [BleLinkPhase.secureReady] — reached exclusively after the Noise XX
/// handshake completed, the pinned-key and expected-identity policy passed,
/// and the application explicitly confirmed the authenticated identity —
/// counts as connected for secure message delivery. There is no plaintext
/// fallback and no phase that fabricates secure readiness.
enum BleLinkPhase {
  /// A GATT connection is being established (outgoing connect or an incoming
  /// central that has not finished the pre-secure HELLO exchange).
  connecting,

  /// The plaintext HELLO exchange finished and the link is waiting for the
  /// user's approval decision. No Noise handshake has started.
  awaitingAuthorization,

  /// The Noise XX handshake is running.
  handshaking,

  /// The handshake authenticated the remote identity; the application's
  /// explicit confirmation is still outstanding.
  awaitingConfirmation,

  /// Fully secure: handshake, key policy and explicit confirmation all
  /// passed. The only phase eligible for secure message delivery.
  secureReady,

  /// The link is being torn down on user request or lifecycle shutdown.
  disconnecting,

  /// The link failed (handshake failure, protocol violation, transport loss)
  /// and is unusable. Recovery requires a fresh connection and handshake.
  failed,

  /// The link closed cleanly or after cleanup finished.
  closed,
}

/// Immutable, UI-facing snapshot of one peer's BLE link.
///
/// Exposed through [BleRuntimeState.activeLinks] so the application can show
/// every peer's independent connection state at once. It never contains key
/// material, Noise handles or transport objects — only non-secret facts.
class BlePeerLinkState {
  const BlePeerLinkState({
    required this.peerId,
    required this.phase,
    required this.role,
    this.displayName,
    this.deviceName,
    this.signalStrength,
    this.effectiveWriteLength,
    this.error,
    required this.updatedAt,
  });

  /// Authenticated BeChat device ID of the peer, or `null` before the HELLO
  /// exchange reveals it (an incoming central that is still connecting).
  final String? peerId;

  final BleLinkPhase phase;
  final BleLinkRole role;

  /// Best-known peer display name: the authenticated identity once available,
  /// otherwise the pre-secure HELLO or scan-time name (a hint only).
  final String? displayName;

  /// Raw BLE device name observed from the platform.
  final String? deviceName;

  final int? signalStrength;

  /// This link's negotiated effective GATT write limit in bytes.
  final int? effectiveWriteLength;

  /// Non-secret failure description when the phase is failed.
  final String? error;

  final DateTime updatedAt;

  /// Only secure-ready links count as connected for delivery and presence.
  bool get isSecureReady => phase == BleLinkPhase.secureReady;

  /// Whether the link may still take part in the incoming-approval flow: a
  /// secure session sits at awaitingAuthorization between HELLO and the Noise
  /// handshake, while a legacy session is simply ready.
  bool get isAwaitingAuthorization =>
      phase == BleLinkPhase.awaitingAuthorization;

  BlePeerLinkState copyWith({
    BleLinkPhase? phase,
    BleLinkRole? role,
    String? displayName,
    String? deviceName,
    int? signalStrength,
    int? effectiveWriteLength,
    String? error,
    DateTime? updatedAt,
  }) {
    return BlePeerLinkState(
      peerId: peerId,
      phase: phase ?? this.phase,
      role: role ?? this.role,
      displayName: displayName ?? this.displayName,
      deviceName: deviceName ?? this.deviceName,
      signalStrength: signalStrength ?? this.signalStrength,
      effectiveWriteLength: effectiveWriteLength ?? this.effectiveWriteLength,
      error: error ?? this.error,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'BlePeerLinkState(peerId: $peerId, phase: $phase, role: $role)';
}

/// Non-secret, UI-facing label for one link phase.
String bleLinkPhaseLabel(BleLinkPhase phase) {
  return switch (phase) {
    BleLinkPhase.connecting => 'Connecting',
    BleLinkPhase.awaitingAuthorization => 'Awaiting approval',
    BleLinkPhase.handshaking => 'Securing...',
    BleLinkPhase.awaitingConfirmation => 'Awaiting confirmation',
    BleLinkPhase.secureReady => 'Secure',
    BleLinkPhase.disconnecting => 'Disconnecting',
    BleLinkPhase.failed => 'Failed',
    BleLinkPhase.closed => 'Disconnected',
  };
}
