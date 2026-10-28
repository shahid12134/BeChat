//! Production Noise XX secure session engine for BeChat.
//!
//! This module adds cryptographic *sessions* on top of the installed Noise
//! static identity from [`crate::identity`]. It is the Rust-side half of the
//! secure BLE transport: JNI/Kotlin/Dart integration comes in later phases and
//! nothing here is exposed through the JNI crate yet. Until that integration
//! ships, production BLE traffic is **not** encrypted.
//!
//! Design invariants:
//!
//! * Suite: [`crate::NOISE_XX_PATTERN`] only. No runtime pattern negotiation
//!   and no IK fallback in this phase.
//! * Prologue: [`SECURE_PROLOGUE`], a production-specific versioned string,
//!   distinct from the spike's prologue so spike sessions can never
//!   interoperate with production sessions.
//! * Private key material never leaves Rust. The session engine reads the
//!   installed seed through a crate-internal zeroizing accessor and drops it
//!   as soon as the Noise handshake state is built. There is no seed getter
//!   and no arbitrary secret-injection API anywhere in this crate.
//! * Opaque `u32` session handles come from a monotonic counter and are never
//!   recycled while a live session holds them, so a stale handle cannot reach
//!   a replacement session.
//! * Handshake completion does **not** grant transport access. The caller must
//!   explicitly confirm the authenticated remote identity via
//!   [`session_confirm_peer_identity`] before [`session_encrypt`] or
//!   [`session_decrypt`] will run, keeping cryptographic completion separate
//!   from application authorization.
//! * Any fatal error (malformed handshake message, pin mismatch, failed
//!   authenticated decrypt) poisons the session into `Failed`: all further
//!   operations are refused until the caller closes the session and
//!   reconnects. Errors never fall back to plaintext.
//! * The registry lock is only held for handle lookup/insert/remove; each
//!   session's cryptographic operations run under a per-session mutex.
//! * All error strings are fixed and non-secret.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use snow::params::NoiseParams;
use snow::{Builder, HandshakeState, TransportState};

use crate::identity::{decode_public_key, installed_identity_key_material};
use crate::NOISE_XX_PATTERN;

/// Versioned Noise prologue for production secure sessions.
///
/// Binding a prologue into the handshake transcript means every peer must
/// agree on it; a session built by the isolated spike (different prologue)
/// can never complete against a production session.
pub const SECURE_PROLOGUE: &[u8] = b"BeChat secure transport v1";

/// Upper bound for one encoded authenticated identity payload.
///
/// Deliberately smaller than the BLE `maxHelloBytes` limit (1024): the
/// identity payload is carried inside Noise handshake messages, which must
/// stay well within one BLE transfer.
pub const MAX_IDENTITY_PAYLOAD_LENGTH: usize = 512;

/// Upper bound for one Noise handshake message (message 1, 2 or 3).
///
/// XX messages are small (ephemeral/static keys plus the identity payload and
/// AEAD tags); 1024 bytes bounds every inbound allocation well below the BLE
/// transfer limit.
pub const MAX_HANDSHAKE_MESSAGE_LENGTH: usize = 1024;

/// Upper bound for one encrypted transport message (ciphertext including the
/// 16-byte ChaChaPoly tag).
///
/// Matches the BLE `maxTransferLength` of 8192 so a transport message always
/// fits an existing transfer without new fragmentation rules. The later BLE
/// integration still enforces its own transfer limit on top of this.
pub const MAX_TRANSPORT_MESSAGE_LENGTH: usize = 8192;

/// Upper bound for one plaintext transport payload (ciphertext limit minus
/// the 16-byte authentication tag).
pub const MAX_TRANSPORT_PLAINTEXT_LENGTH: usize = MAX_TRANSPORT_MESSAGE_LENGTH - 16;

/// Maximum number of concurrently open sessions.
///
/// Conservative initial bound: BeChat maintains at most one active link, with
/// a small allowance for a link in teardown overlapping its replacement. If
/// the runtime later needs a different limit, change this constant and its
/// capacity test together.
pub const MAX_SESSIONS: usize = 4;

/// Format version of the encoded authenticated identity payload.
const IDENTITY_PAYLOAD_FORMAT_VERSION: u8 = 1;

/// Capability bit: the peer can exchange secure text messages.
pub const CAPABILITY_SECURE_TEXT: u8 = 0b0000_0001;

/// Capabilities advertised by this build's identity payload.
pub const LOCAL_CAPABILITIES: u8 = CAPABILITY_SECURE_TEXT;

/// Longest accepted device UUID in the identity payload (matches HELLO).
const MAX_DEVICE_ID_LENGTH: usize = 128;

/// Longest accepted display name in the identity payload (matches HELLO).
const MAX_DISPLAY_NAME_LENGTH: usize = 64;

/// Errors produced by session operations. Fixed, non-secret strings.
pub type SessionError = String;

/// The application identity authenticated by a completed Noise handshake.
///
/// Every field was recovered from an AEAD-encrypted handshake payload, so it
/// is bound to the peer's static key. It is *not* proof that the key belongs
/// to a particular human: first-contact trust and out-of-band verification
/// are application-layer concerns handled above this engine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteIdentity {
    /// Lowercase-hex X25519 static public key authenticated by the handshake.
    pub static_public_key_hex: String,
    /// Asserted BeChat device UUID of the peer.
    pub device_id: String,
    /// Asserted display name of the peer (unverified as to ownership).
    pub display_name: String,
    /// Secure protocol version from the peer's payload.
    pub protocol_version: u8,
    /// Capability bits from the peer's payload.
    pub capabilities: u8,
}

/// Result of one handshake step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HandshakeOutput {
    /// Outbound handshake message to transmit to the peer, when any.
    pub outgoing: Vec<u8>,
    /// Whether the cryptographic handshake has finished.
    pub finished: bool,
    /// Authenticated remote identity, once its handshake payload arrived.
    pub remote_identity: Option<RemoteIdentity>,
    /// True once the handshake is finished but application-level confirmation
    /// is still required before transport operations are allowed.
    pub confirmation_required: bool,
}

/// Non-secret session stage names reported by [`session_status`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionStageName {
    Handshaking,
    AwaitingConfirmation,
    Ready,
    Failed,
}

/// Non-secret status snapshot of a session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionStatusReport {
    pub stage: SessionStageName,
    pub remote_static_public_key_hex: Option<String>,
    pub remote_identity_available: bool,
}

/// Snow handshake or transport state plus the policy data around it.
enum SessionStage {
    Handshake(Box<HandshakeState>),
    /// Handshake finished; transport exists but application authorization has
    /// not confirmed the remote identity yet.
    AwaitingConfirmation(Box<TransportState>),
    Ready(Box<TransportState>),
    /// Poisoned by a fatal error. Only close is allowed from here.
    Failed,
}

struct Session {
    stage: SessionStage,
    /// True when this side built the initiator handshake.
    initiator: bool,
    /// Optional pinned remote static key (raw bytes) supplied at creation.
    pinned_remote: Option<Vec<u8>>,
    /// Optional expected peer device UUID supplied at creation.
    expected_device_id: Option<String>,
    /// Local identity payload bytes, embedded in this side's handshake
    /// message. Public information only.
    local_payload: Vec<u8>,
    /// Authenticated remote identity, once recovered.
    remote_identity: Option<RemoteIdentity>,
    /// Number of inbound handshake messages processed so far. The
    /// responder's first read is message 1, which is unauthenticated.
    reads: usize,
}

impl Session {
    fn stage_name(&self) -> SessionStageName {
        match self.stage {
            SessionStage::Handshake(_) => SessionStageName::Handshaking,
            SessionStage::AwaitingConfirmation(_) => SessionStageName::AwaitingConfirmation,
            SessionStage::Ready(_) => SessionStageName::Ready,
            SessionStage::Failed => SessionStageName::Failed,
        }
    }

    /// Moves the session to `Failed`, dropping any retained Noise state.
    fn fail(&mut self) {
        self.stage = SessionStage::Failed;
    }
}

/// Process-wide session registry.
///
/// The registry mutex protects only the handle map and the handle counter.
/// Each session's cryptographic work runs under its own per-session mutex, so
/// one session's operations never hold the registry lock.
static SESSIONS: OnceLock<Mutex<SessionRegistry>> = OnceLock::new();

struct SessionRegistry {
    sessions: HashMap<u32, Arc<Mutex<Session>>>,
    next_handle: u32,
}

fn registry() -> &'static Mutex<SessionRegistry> {
    SESSIONS.get_or_init(|| {
        Mutex::new(SessionRegistry {
            sessions: HashMap::new(),
            next_handle: 0,
        })
    })
}

fn lock_registry() -> MutexGuard<'static, SessionRegistry> {
    // A panic while holding the registry lock leaves the map consistent
    // (insert/remove are the only mutations); recovering keeps the engine
    // usable instead of poisoning every later call.
    registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn lock_session(session: &Arc<Mutex<Session>>) -> MutexGuard<'_, Session> {
    session
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Allocates a fresh handle that never collides with a live session.
///
/// The counter is monotonic and skips zero; handles are only reused after
/// wrap-around of the full u32 space, and even then never while a session is
/// live, so a stale handle cannot operate on a replacement session.
fn allocate_handle(registry: &mut SessionRegistry) -> Result<u32, SessionError> {
    if registry.sessions.len() >= MAX_SESSIONS {
        return Err("too many active sessions".to_string());
    }
    loop {
        registry.next_handle = registry.next_handle.wrapping_add(1);
        if registry.next_handle == 0 {
            continue;
        }
        if !registry.sessions.contains_key(&registry.next_handle) {
            return Ok(registry.next_handle);
        }
    }
}

/// Looks up a live session by handle, cloning its Arc for locked use.
fn lookup_session(handle: u32) -> Result<Arc<Mutex<Session>>, SessionError> {
    lock_registry()
        .sessions
        .get(&handle)
        .cloned()
        .ok_or_else(|| "session is closed or unknown".to_string())
}

/// Validates the fields of a local or remote identity payload.
fn validate_identity_fields(device_id: &str, display_name: &str) -> Result<(), SessionError> {
    if device_id.trim().is_empty() || device_id.len() > MAX_DEVICE_ID_LENGTH {
        return Err("invalid device id".to_string());
    }
    if display_name.trim().is_empty() || display_name.len() > MAX_DISPLAY_NAME_LENGTH {
        return Err("invalid display name".to_string());
    }
    Ok(())
}

/// Encodes the local application identity for embedding in a handshake
/// payload.
///
/// Layout (all integers big-endian):
/// `[version:1][deviceIdLen:2][deviceId][nameLen:2][name][capabilities:1]`
///
/// The encoded size is bounded by [`MAX_IDENTITY_PAYLOAD_LENGTH`]. The payload
/// carries public information only: no key material, no filesystem data.
pub fn encode_identity_payload(
    device_id: &str,
    display_name: &str,
) -> Result<Vec<u8>, SessionError> {
    validate_identity_fields(device_id, display_name)?;
    let device_bytes = device_id.as_bytes();
    let name_bytes = display_name.as_bytes();
    let total = 1 + 2 + device_bytes.len() + 2 + name_bytes.len() + 1;
    if total > MAX_IDENTITY_PAYLOAD_LENGTH {
        return Err("identity payload is too large".to_string());
    }
    let mut out = Vec::with_capacity(total);
    out.push(IDENTITY_PAYLOAD_FORMAT_VERSION);
    out.extend_from_slice(&(device_bytes.len() as u16).to_be_bytes());
    out.extend_from_slice(device_bytes);
    out.extend_from_slice(&(name_bytes.len() as u16).to_be_bytes());
    out.extend_from_slice(name_bytes);
    out.push(LOCAL_CAPABILITIES);
    Ok(out)
}

/// Reads one length-prefixed field from an identity payload, advancing
/// `cursor`. Fails closed on truncation.
fn read_payload_field<'a>(bytes: &'a [u8], cursor: &mut usize) -> Result<&'a [u8], SessionError> {
    if *cursor + 2 > bytes.len() {
        return Err("identity payload is truncated".to_string());
    }
    let len = u16::from_be_bytes([bytes[*cursor], bytes[*cursor + 1]]) as usize;
    *cursor += 2;
    if *cursor + len > bytes.len() {
        return Err("identity payload is truncated".to_string());
    }
    let field = &bytes[*cursor..*cursor + len];
    *cursor += len;
    Ok(field)
}

/// Decodes and validates a remote identity payload from a handshake message.
///
/// Fails closed on truncation, trailing bytes, unknown format versions,
/// oversized fields and malformed UTF-8. Never panics on hostile input.
pub fn decode_identity_payload(bytes: &[u8]) -> Result<RemoteIdentity, SessionError> {
    if bytes.is_empty() {
        return Err("identity payload is empty".to_string());
    }
    if bytes.len() > MAX_IDENTITY_PAYLOAD_LENGTH {
        return Err("identity payload is too large".to_string());
    }
    let version = bytes[0];
    if version != IDENTITY_PAYLOAD_FORMAT_VERSION {
        return Err("unsupported identity payload version".to_string());
    }

    let mut cursor = 1usize;
    let device_field = read_payload_field(bytes, &mut cursor)?;
    let name_field = read_payload_field(bytes, &mut cursor)?;
    if cursor + 1 != bytes.len() {
        return Err("identity payload has trailing bytes".to_string());
    }
    let capabilities = bytes[cursor];

    let device_id = std::str::from_utf8(device_field)
        .map_err(|_| "device id is not valid UTF-8".to_string())?;
    let display_name = std::str::from_utf8(name_field)
        .map_err(|_| "display name is not valid UTF-8".to_string())?;
    validate_identity_fields(device_id, display_name)?;

    Ok(RemoteIdentity {
        static_public_key_hex: String::new(),
        device_id: device_id.to_string(),
        display_name: display_name.to_string(),
        protocol_version: version,
        capabilities,
    })
}

/// Creates a new secure session using the installed Noise identity.
///
/// * `initiator` — true when this side sends handshake message 1.
/// * `device_id`, `display_name` — the local application identity embedded in
///   this side's authenticated handshake payload.
/// * `pinned_remote_static_public_key_hex` — optional expected peer static key
///   (lowercase-hex X25519). When present, the completed handshake must
///   authenticate exactly this key or the session fails closed.
/// * `expected_peer_device_id` — optional device UUID the remote identity
///   payload must assert, checked at handshake completion.
///
/// Fails when no identity is installed, when the pin is malformed, or when
/// the session capacity is exhausted. Never returns key material.
pub fn session_create(
    initiator: bool,
    device_id: &str,
    display_name: &str,
    pinned_remote_static_public_key_hex: Option<&str>,
    expected_peer_device_id: Option<&str>,
) -> Result<u32, SessionError> {
    let local_payload = encode_identity_payload(device_id, display_name)?;
    let pinned_remote = match pinned_remote_static_public_key_hex {
        Some(hex_key) => Some(decode_public_key(hex_key)?),
        None => None,
    };
    if let Some(expected) = expected_peer_device_id {
        if expected.trim().is_empty() || expected.len() > MAX_DEVICE_ID_LENGTH {
            return Err("invalid expected peer device id".to_string());
        }
    }

    // The installed seed is cloned into the local handshake builder only; the
    // zeroizing copy is dropped as soon as the handshake state exists.
    let (seed, _public) = installed_identity_key_material()?;

    let params: NoiseParams = NOISE_XX_PATTERN
        .parse()
        .map_err(|_| "invalid Noise parameters".to_string())?;
    let builder = Builder::new(params)
        .local_private_key(&seed)
        .map_err(|_| "invalid local identity key".to_string())?
        .prologue(SECURE_PROLOGUE)
        .map_err(|_| "invalid Noise prologue".to_string())?;
    let handshake = if initiator {
        builder.build_initiator()
    } else {
        builder.build_responder()
    }
    .map_err(|_| "could not initialize Noise handshake".to_string())?;

    let session = Session {
        stage: SessionStage::Handshake(Box::new(handshake)),
        initiator,
        pinned_remote,
        expected_device_id: expected_peer_device_id.map(str::to_string),
        local_payload,
        remote_identity: None,
        reads: 0,
    };

    let mut registry = lock_registry();
    let handle = allocate_handle(&mut registry)?;
    registry
        .sessions
        .insert(handle, Arc::new(Mutex::new(session)));
    Ok(handle)
}

/// Produces handshake message 1. Initiator sessions only.
pub fn session_start_handshake(handle: u32) -> Result<HandshakeOutput, SessionError> {
    let session_arc = lookup_session(handle)?;
    let mut session = lock_session(&session_arc);
    if !session.initiator {
        return Err("only the initiator starts the handshake".to_string());
    }
    match session.stage_name() {
        SessionStageName::Handshaking => {}
        SessionStageName::Failed => return Err("session has failed".to_string()),
        _ => return Err("handshake already finished".to_string()),
    }
    // Move the handshake state out of the session so the session can be
    // poisoned without fighting the borrow checker; restore it on success.
    let previous = std::mem::replace(&mut session.stage, SessionStage::Failed);
    let SessionStage::Handshake(mut handshake) = previous else {
        return Err("session has failed".to_string());
    };
    if !handshake.is_my_turn() {
        session.stage = SessionStage::Handshake(handshake);
        return Err("handshake is waiting for the remote message".to_string());
    }
    // Message 1 carries no payload: its contents are not yet encrypted or
    // authenticated, so no claimed identity may travel in it.
    let mut outgoing = vec![0u8; MAX_HANDSHAKE_MESSAGE_LENGTH];
    let len = match handshake.write_message(&[], &mut outgoing) {
        Ok(len) => len,
        Err(_) => return Err("could not write handshake message".to_string()),
    };
    outgoing.truncate(len);
    session.stage = SessionStage::Handshake(handshake);
    Ok(HandshakeOutput {
        outgoing,
        finished: false,
        remote_identity: None,
        confirmation_required: false,
    })
}

/// Processes one inbound handshake message and, when it becomes this side's
/// turn, produces the next outbound handshake message.
///
/// Fails closed on oversized or malformed input, on an identity payload in an
/// unauthenticated position (message 1), on a pinned-key mismatch, on a
/// missing remote identity payload at completion, and on an expected-device
/// mismatch. Any of these poisons the session.
///
/// When the handshake finishes the session moves to `AwaitingConfirmation`:
/// the transport exists but [`session_confirm_peer_identity`] is still
/// required before encrypt/decrypt are allowed.
pub fn session_process_handshake(
    handle: u32,
    incoming: &[u8],
) -> Result<HandshakeOutput, SessionError> {
    if incoming.len() > MAX_HANDSHAKE_MESSAGE_LENGTH {
        return Err("handshake message is too large".to_string());
    }
    if incoming.is_empty() {
        return Err("handshake message is empty".to_string());
    }
    let session_arc = lookup_session(handle)?;
    let mut session = lock_session(&session_arc);
    match session.stage_name() {
        SessionStageName::Handshaking => {}
        SessionStageName::Failed => return Err("session has failed".to_string()),
        _ => return Err("handshake already finished".to_string()),
    }
    session.reads += 1;
    // Message 1 (the responder's first read) is unauthenticated: a payload
    // there carries no proof of anything, so it must be empty. Identity
    // claims are only accepted from AEAD-protected handshake messages.
    let first_read_unauthenticated = !session.initiator && session.reads == 1;

    let previous = std::mem::replace(&mut session.stage, SessionStage::Failed);
    let SessionStage::Handshake(mut handshake) = previous else {
        return Err("session has failed".to_string());
    };
    if handshake.is_my_turn() {
        session.stage = SessionStage::Handshake(handshake);
        return Err("handshake is waiting for the remote message".to_string());
    }

    let mut payload = vec![0u8; incoming.len()];
    let payload_len = match handshake.read_message(incoming, &mut payload) {
        Ok(len) => len,
        Err(_) => return Err("handshake message rejected".to_string()),
    };
    payload.truncate(payload_len);

    if first_read_unauthenticated && !payload.is_empty() {
        return Err("identity payload in unauthenticated handshake message".to_string());
    }
    if !payload.is_empty() {
        if session.remote_identity.is_some() {
            return Err("duplicate remote identity payload".to_string());
        }
        let mut identity = match decode_identity_payload(&payload) {
            Ok(identity) => identity,
            Err(_) => return Err("remote identity payload is invalid".to_string()),
        };
        match handshake.get_remote_static() {
            Some(remote) => identity.static_public_key_hex = hex::encode(remote),
            None => return Err("remote identity is not bound to a static key".to_string()),
        }
        session.remote_identity = Some(identity);
    }

    // Produce this side's next handshake message when it is now our turn,
    // embedding the local identity payload in the AEAD-protected message.
    let mut outgoing = Vec::new();
    if !handshake.is_handshake_finished() {
        if !handshake.is_my_turn() {
            return Err("unexpected handshake state".to_string());
        }
        let mut buffer = vec![0u8; MAX_HANDSHAKE_MESSAGE_LENGTH];
        let len = match handshake.write_message(&session.local_payload, &mut buffer) {
            Ok(len) => len,
            Err(_) => return Err("could not write handshake message".to_string()),
        };
        buffer.truncate(len);
        outgoing = buffer;
    }

    if !handshake.is_handshake_finished() {
        session.stage = SessionStage::Handshake(handshake);
        return Ok(HandshakeOutput {
            outgoing,
            finished: false,
            remote_identity: session.remote_identity.clone(),
            confirmation_required: false,
        });
    }

    // Handshake complete: authenticate the remote static key against the
    // optional pin before the session may proceed at all.
    let remote_static = handshake
        .get_remote_static()
        .map(<[u8]>::to_vec)
        .ok_or_else(|| "remote static key was not authenticated".to_string())?;
    if let Some(pinned) = &session.pinned_remote {
        if pinned != &remote_static {
            return Err("remote static key does not match the pinned key".to_string());
        }
    }
    let remote_identity = session
        .remote_identity
        .clone()
        .ok_or_else(|| "remote identity payload is missing".to_string())?;
    if let Some(expected) = &session.expected_device_id {
        if expected != &remote_identity.device_id {
            return Err("remote identity does not match the expected peer".to_string());
        }
    }
    let transport = match handshake.into_transport_mode() {
        Ok(transport) => transport,
        Err(_) => return Err("could not enter transport mode".to_string()),
    };
    session.stage = SessionStage::AwaitingConfirmation(Box::new(transport));
    Ok(HandshakeOutput {
        outgoing,
        finished: true,
        remote_identity: Some(remote_identity),
        confirmation_required: true,
    })
}

/// Explicitly confirms the authenticated remote identity, unlocking
/// transport operations.
///
/// The calling application layer invokes this only after it has inspected the
/// [`RemoteIdentity`] from the completed handshake — checked the device UUID
/// against its peer association, resolved pinned-key and first-contact or
/// changed-key policy, and accepted the binding. Until then the session stays
/// in `AwaitingConfirmation` and encrypt/decrypt are refused, so the
/// cryptographic handshake alone can never grant message transport access.
///
/// The engine never assigns the application's `verified` peer state; that
/// remains an out-of-band, application-layer decision.
pub fn session_confirm_peer_identity(handle: u32) -> Result<(), SessionError> {
    let session_arc = lookup_session(handle)?;
    let mut session = lock_session(&session_arc);
    match session.stage_name() {
        SessionStageName::AwaitingConfirmation => {}
        SessionStageName::Failed => return Err("session has failed".to_string()),
        _ => return Err("session is not awaiting confirmation".to_string()),
    }
    // A confirmed session without an authenticated remote identity would be
    // unusable for policy decisions; treat that as fatal rather than
    // unlocking the transport.
    if session.remote_identity.is_none() {
        session.fail();
        return Err("remote identity is missing".to_string());
    }
    let previous = std::mem::replace(&mut session.stage, SessionStage::Failed);
    let SessionStage::AwaitingConfirmation(transport) = previous else {
        return Err("session is not awaiting confirmation".to_string());
    };
    session.stage = SessionStage::Ready(transport);
    Ok(())
}

/// Encrypts one plaintext transport payload with the confirmed session.
///
/// Rejects oversized plaintext before any allocation. Refuses to operate
/// before explicit confirmation. A failed encrypt poisons the session,
/// because a write failure means the transport state can no longer be
/// trusted to stay synchronized with the peer.
pub fn session_encrypt(handle: u32, plaintext: &[u8]) -> Result<Vec<u8>, SessionError> {
    if plaintext.len() > MAX_TRANSPORT_PLAINTEXT_LENGTH {
        return Err("plaintext is too large".to_string());
    }
    let session_arc = lookup_session(handle)?;
    let mut session = lock_session(&session_arc);
    match session.stage_name() {
        SessionStageName::Ready => {}
        SessionStageName::Failed => return Err("session has failed".to_string()),
        SessionStageName::AwaitingConfirmation => {
            return Err("session confirmation required".to_string());
        }
        SessionStageName::Handshaking => return Err("handshake is not complete".to_string()),
    }
    // Move the transport out: on success it is restored; on failure the
    // session stays `Failed` because the nonce counters may have advanced.
    let previous = std::mem::replace(&mut session.stage, SessionStage::Failed);
    let SessionStage::Ready(mut transport) = previous else {
        return Err("session is not ready".to_string());
    };
    // Ciphertext = plaintext + 16-byte ChaChaPoly authentication tag.
    let mut ciphertext = vec![0u8; plaintext.len() + 16];
    match transport.write_message(plaintext, &mut ciphertext) {
        Ok(len) => {
            ciphertext.truncate(len);
            session.stage = SessionStage::Ready(transport);
            Ok(ciphertext)
        }
        Err(_) => Err("could not encrypt transport message".to_string()),
    }
}

/// Decrypts one authenticated transport payload with the confirmed session.
///
/// Any authentication failure poisons the session: a rejected ciphertext
/// means either tampering or nonce-counter desynchronization, and continuing
/// would risk nonce reuse or accepting forged data. The caller must close the
/// session and reconnect; there is no plaintext fallback.
pub fn session_decrypt(handle: u32, ciphertext: &[u8]) -> Result<Vec<u8>, SessionError> {
    if ciphertext.len() > MAX_TRANSPORT_MESSAGE_LENGTH {
        return Err("ciphertext is too large".to_string());
    }
    // Every transport message carries at least the 16-byte authentication
    // tag; shorter input cannot be authentic.
    if ciphertext.len() < 16 {
        return Err("ciphertext is too short".to_string());
    }
    let session_arc = lookup_session(handle)?;
    let mut session = lock_session(&session_arc);
    match session.stage_name() {
        SessionStageName::Ready => {}
        SessionStageName::Failed => return Err("session has failed".to_string()),
        SessionStageName::AwaitingConfirmation => {
            return Err("session confirmation required".to_string());
        }
        SessionStageName::Handshaking => return Err("handshake is not complete".to_string()),
    }
    let previous = std::mem::replace(&mut session.stage, SessionStage::Failed);
    let SessionStage::Ready(mut transport) = previous else {
        return Err("session is not ready".to_string());
    };
    let mut plaintext = vec![0u8; ciphertext.len() - 16];
    match transport.read_message(ciphertext, &mut plaintext) {
        Ok(len) => {
            plaintext.truncate(len);
            session.stage = SessionStage::Ready(transport);
            Ok(plaintext)
        }
        // Deliberately leave the stage as `Failed`: the session is poisoned.
        Err(_) => Err("transport message authentication failed".to_string()),
    }
}

/// Closes a session, dropping all of its Noise state and releasing its
/// registry slot.
///
/// Returns `true` when a live session was removed, `false` for unknown or
/// already-closed handles. A closed handle can never operate on a later
/// session, because handles are never recycled while live.
pub fn session_close(handle: u32) -> bool {
    lock_registry().sessions.remove(&handle).is_some()
}

/// Returns a non-secret status snapshot for a live session.
///
/// Reports the stage plus public information only; no key material, no
/// identity payload contents beyond availability.
pub fn session_status(handle: u32) -> Result<SessionStatusReport, SessionError> {
    let session_arc = lookup_session(handle)?;
    let session = lock_session(&session_arc);
    Ok(SessionStatusReport {
        stage: session.stage_name(),
        remote_static_public_key_hex: session
            .remote_identity
            .as_ref()
            .map(|identity| identity.static_public_key_hex.clone()),
        remote_identity_available: session.remote_identity.is_some(),
    })
}

#[cfg(test)]
mod tests {
    //! Unit tests for the pure identity-payload codec. Session-level tests
    //! (which need the process-wide installed identity and session registry)
    //! live in `tests/session_engine.rs` and serialize on a lock there; these
    //! tests touch no global state and can run in parallel.

    use super::*;

    #[test]
    fn constants_reflect_the_real_ble_limits() {
        // Derived from the actual BLE protocol constants (maxTransferLength
        // 8192, maxMessageContentBytes 4096), not the spike's 65535.
        assert_eq!(MAX_TRANSPORT_MESSAGE_LENGTH, 8192);
        assert_eq!(
            MAX_TRANSPORT_PLAINTEXT_LENGTH,
            MAX_TRANSPORT_MESSAGE_LENGTH - 16
        );
        // Compile-time relationships between the engine limits.
        const {
            assert!(MAX_HANDSHAKE_MESSAGE_LENGTH < MAX_TRANSPORT_MESSAGE_LENGTH);
            assert!(MAX_IDENTITY_PAYLOAD_LENGTH < MAX_HANDSHAKE_MESSAGE_LENGTH);
        }
        assert_eq!(MAX_SESSIONS, 4);
        assert_eq!(SECURE_PROLOGUE, b"BeChat secure transport v1");
    }

    #[test]
    fn identity_payload_roundtrip_preserves_fields() {
        let encoded = encode_identity_payload("device-uuid-1", "Alice").expect("encode");
        let decoded = decode_identity_payload(&encoded).expect("decode");
        assert_eq!(decoded.device_id, "device-uuid-1");
        assert_eq!(decoded.display_name, "Alice");
        assert_eq!(decoded.protocol_version, 1);
        assert_eq!(decoded.capabilities, CAPABILITY_SECURE_TEXT);
        // The static-key binding is added by the session layer, not the codec.
        assert!(decoded.static_public_key_hex.is_empty());
    }

    #[test]
    fn identity_payload_encode_enforces_field_limits() {
        assert!(encode_identity_payload("", "Alice").is_err());
        assert!(encode_identity_payload("   ", "Alice").is_err());
        assert!(encode_identity_payload("device", "").is_err());
        assert!(encode_identity_payload("device", "   ").is_err());
        assert!(encode_identity_payload(&"d".repeat(MAX_DEVICE_ID_LENGTH), "Alice").is_ok());
        assert!(encode_identity_payload(&"d".repeat(MAX_DEVICE_ID_LENGTH + 1), "Alice").is_err());
        assert!(encode_identity_payload("device", &"n".repeat(MAX_DISPLAY_NAME_LENGTH)).is_ok());
        assert!(
            encode_identity_payload("device", &"n".repeat(MAX_DISPLAY_NAME_LENGTH + 1)).is_err()
        );
    }

    #[test]
    fn identity_payload_decode_rejects_truncation_and_trailing_bytes() {
        let encoded = encode_identity_payload("device-uuid-1", "Alice").expect("encode");
        for len in 0..encoded.len() {
            assert!(
                decode_identity_payload(&encoded[..len]).is_err(),
                "prefix of length {len} must be rejected"
            );
        }
        let mut trailing = encoded;
        trailing.push(0);
        assert!(decode_identity_payload(&trailing).is_err());
    }

    #[test]
    fn identity_payload_decode_rejects_bad_version_and_non_utf8() {
        let mut bad_version = encode_identity_payload("device", "Alice").expect("encode");
        bad_version[0] = 99;
        assert!(decode_identity_payload(&bad_version).is_err());

        // [version=1][deviceIdLen=2][invalid UTF-8][nameLen=1]["x"][caps]
        let non_utf8 = [1u8, 0, 2, 0xff, 0xfe, 0, 1, b'x', CAPABILITY_SECURE_TEXT];
        assert!(decode_identity_payload(&non_utf8).is_err());

        assert!(decode_identity_payload(&[]).is_err());
        assert!(decode_identity_payload(&vec![0u8; MAX_IDENTITY_PAYLOAD_LENGTH + 1]).is_err());
    }
}
