//! Integration tests for the production Noise XX secure session engine.
//!
//! Every test here touches process-global state (the installed Noise identity
//! and the session registry), so all tests serialize on one lock. Peer
//! identities are deterministic fixed seeds: each is installed only long
//! enough to create the sessions that capture it (Snow copies the private key
//! into the handshake state at build time), after which the next identity may
//! replace it. No API used here exports private key material.
//!
//! These tests exercise only the public API surface of `bechat_crypto_core`
//! — exactly what the later JNI/Kotlin integration will call.

use std::collections::HashSet;
use std::sync::{Mutex, MutexGuard, OnceLock};

use bechat_crypto_core::{
    clear_installed_identity, decode_identity_payload, derive_identity_public_key_hex,
    encode_identity_payload, install_identity, installed_public_key_hex, session_close,
    session_confirm_peer_identity, session_create, session_decrypt, session_encrypt,
    session_process_handshake, session_start_handshake, session_status, HandshakeOutput,
    SessionStageName, CAPABILITY_SECURE_TEXT, MAX_IDENTITY_PAYLOAD_LENGTH, MAX_SESSIONS,
    MAX_TRANSPORT_MESSAGE_LENGTH, MAX_TRANSPORT_PLAINTEXT_LENGTH, NOISE_XX_PATTERN,
    SECURE_PROLOGUE,
};
use snow::params::NoiseParams;
use snow::Builder;

/// Device UUIDs used as the local/remote application identities.
const ALICE_ID: &str = "11111111-2222-3333-4444-555555555555";
const BOB_ID: &str = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

/// Serializes tests: the installed identity and session registry are
/// process-wide, so parallel tests would race on them.
fn exclusive() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct Peer {
    handle: u32,
    public_hex: String,
}

/// Installs a deterministic identity derived from `seed_byte` and creates a
/// session with it. The session captures the seed immediately; later installs
/// of other identities do not affect it.
fn create_peer(
    seed_byte: u8,
    initiator: bool,
    device_id: &str,
    display_name: &str,
    pin: Option<&str>,
    expected_peer_device_id: Option<&str>,
) -> Peer {
    let seed = vec![seed_byte; 32];
    let public_hex = derive_identity_public_key_hex(&seed).expect("derive public key");
    install_identity(&seed, &public_hex).expect("install identity");
    let handle = session_create(
        initiator,
        device_id,
        display_name,
        pin,
        expected_peer_device_id,
    )
    .expect("create session");
    Peer { handle, public_hex }
}

/// The public key of a seed without installing it (used to build wrong pins).
fn public_hex_for(seed_byte: u8) -> String {
    derive_identity_public_key_hex(&[seed_byte; 32]).expect("derive public key")
}

/// Drives a full XX handshake between two sessions: message 1
/// (initiator→responder), message 2 (responder→initiator), message 3
/// (initiator→responder). Returns all four step outputs.
fn drive_handshake(
    initiator: &Peer,
    responder: &Peer,
) -> (
    HandshakeOutput,
    HandshakeOutput,
    HandshakeOutput,
    HandshakeOutput,
) {
    let step1 = session_start_handshake(initiator.handle).expect("message 1");
    assert!(!step1.finished);
    let step2 = session_process_handshake(responder.handle, &step1.outgoing).expect("message 2");
    assert!(!step2.finished);
    let step3 = session_process_handshake(initiator.handle, &step2.outgoing).expect("message 3");
    assert!(step3.finished && step3.confirmation_required);
    let finish = session_process_handshake(responder.handle, &step3.outgoing).expect("finish");
    assert!(finish.finished && finish.confirmation_required);
    (step1, step2, step3, finish)
}

/// Creates a confirmed ready pair (initiator seed `a`, responder seed `b`).
fn confirmed_pair(a: u8, b: u8) -> (Peer, Peer) {
    let initiator = create_peer(a, true, ALICE_ID, "Alice", None, None);
    let responder = create_peer(b, false, BOB_ID, "Bob", None, None);
    drive_handshake(&initiator, &responder);
    session_confirm_peer_identity(initiator.handle).expect("confirm initiator");
    session_confirm_peer_identity(responder.handle).expect("confirm responder");
    (initiator, responder)
}

#[test]
fn xx_handshake_authenticates_both_identities_and_transports_both_ways() {
    let _guard = exclusive();
    let alice = create_peer(0x01, true, ALICE_ID, "Alice", None, None);
    let bob = create_peer(0x02, false, BOB_ID, "Bob", None, None);

    // Fresh sessions start in the handshaking stage with no remote data.
    let report = session_status(alice.handle).expect("status");
    assert_eq!(report.stage, SessionStageName::Handshaking);
    assert!(report.remote_static_public_key_hex.is_none());
    assert!(!report.remote_identity_available);

    let (step1, step2, step3, finish) = drive_handshake(&alice, &bob);

    // The initiator recovers Bob's identity from the authenticated message 2.
    let bob_identity = step3.remote_identity.as_ref().expect("bob identity");
    assert_eq!(bob_identity.device_id, BOB_ID);
    assert_eq!(bob_identity.display_name, "Bob");
    assert_eq!(bob_identity.static_public_key_hex, bob.public_hex);
    assert_eq!(bob_identity.protocol_version, 1);
    assert_eq!(bob_identity.capabilities, CAPABILITY_SECURE_TEXT);

    // The responder recovers Alice's identity from the authenticated message 3.
    let alice_identity = finish.remote_identity.as_ref().expect("alice identity");
    assert_eq!(alice_identity.device_id, ALICE_ID);
    assert_eq!(alice_identity.display_name, "Alice");
    assert_eq!(alice_identity.static_public_key_hex, alice.public_hex);

    // Message 2 carried Bob's payload; message 1 carried nothing.
    assert!(step2.remote_identity.is_none());
    assert!(step1.remote_identity.is_none());

    // Handshake completion leaves both sides awaiting explicit confirmation.
    assert_eq!(
        session_status(alice.handle).expect("status").stage,
        SessionStageName::AwaitingConfirmation
    );
    assert_eq!(
        session_status(bob.handle).expect("status").stage,
        SessionStageName::AwaitingConfirmation
    );
    assert!(
        session_status(bob.handle)
            .expect("status")
            .remote_identity_available
    );

    session_confirm_peer_identity(alice.handle).expect("confirm alice");
    session_confirm_peer_identity(bob.handle).expect("confirm bob");
    assert_eq!(
        session_status(alice.handle).expect("status").stage,
        SessionStageName::Ready
    );
    assert_eq!(
        session_status(bob.handle).expect("status").stage,
        SessionStageName::Ready
    );
    assert_eq!(
        session_status(alice.handle)
            .expect("status")
            .remote_static_public_key_hex
            .expect("remote key"),
        bob.public_hex
    );

    // Bidirectional authenticated transport, including multi-byte UTF-8.
    let ciphertext = session_encrypt(alice.handle, b"ping").expect("encrypt ping");
    assert_eq!(
        session_decrypt(bob.handle, &ciphertext).expect("decrypt ping"),
        b"ping"
    );
    let reply = session_encrypt(bob.handle, "pong \u{1f30d}".as_bytes()).expect("encrypt pong");
    assert_eq!(
        session_decrypt(alice.handle, &reply).expect("decrypt pong"),
        "pong \u{1f30d}".as_bytes()
    );

    session_close(alice.handle);
    session_close(bob.handle);
}

#[test]
fn handshake_message_one_contains_no_identity_payload() {
    let _guard = exclusive();
    let alice = create_peer(0x01, true, ALICE_ID, "Alice", None, None);
    let bob = create_peer(0x02, false, BOB_ID, "Bob", None, None);

    let step1 = session_start_handshake(alice.handle).expect("message 1");
    // XX message 1 with an empty payload is exactly the 32-byte ephemeral.
    assert_eq!(step1.outgoing.len(), 32);
    // Neither device UUID nor display name may appear in message 1.
    assert!(!step1
        .outgoing
        .windows(ALICE_ID.len())
        .any(|w| w == ALICE_ID.as_bytes()));
    assert!(!step1.outgoing.windows(5).any(|w| w == b"Alice"));
    assert!(step1.remote_identity.is_none());
    assert!(!step1.finished);

    session_close(alice.handle);
    session_close(bob.handle);
}

#[test]
fn hostile_identity_payload_in_message_one_is_rejected() {
    let _guard = exclusive();
    // Our responder is honest; the attacker forges message 1 with a claimed
    // identity payload using Snow directly (no production API allows this).
    let bob = create_peer(0x02, false, BOB_ID, "Bob", None, None);

    let params: NoiseParams = NOISE_XX_PATTERN.parse().expect("XX params");
    let keypair = Builder::new(params.clone())
        .generate_keypair()
        .expect("keypair");
    let mut hostile = Builder::new(params)
        .local_private_key(&keypair.private)
        .expect("key set")
        .prologue(SECURE_PROLOGUE)
        .expect("prologue")
        .build_initiator()
        .expect("hostile initiator");
    let mut buffer = [0u8; 1024];
    let len = hostile
        .write_message(b"claimed identity payload", &mut buffer)
        .expect("hostile message 1");

    let result = session_process_handshake(bob.handle, &buffer[..len]);
    assert_eq!(
        result.unwrap_err(),
        "identity payload in unauthenticated handshake message"
    );
    // The session is poisoned and cannot continue.
    assert_eq!(
        session_status(bob.handle).expect("status").stage,
        SessionStageName::Failed
    );
    assert_eq!(
        session_confirm_peer_identity(bob.handle).unwrap_err(),
        "session has failed"
    );
    session_close(bob.handle);
}

#[test]
fn malformed_and_truncated_handshake_messages_fail_safely() {
    let _guard = exclusive();

    // Random garbage of an invalid length in the message-1 position.
    let responder = create_peer(0x02, false, BOB_ID, "Bob", None, None);
    assert_eq!(
        session_process_handshake(responder.handle, &[0x5au8; 10]).unwrap_err(),
        "handshake message rejected"
    );
    assert_eq!(
        session_status(responder.handle).expect("status").stage,
        SessionStageName::Failed
    );
    session_close(responder.handle);

    // A truncated honest message 1.
    let alice = create_peer(0x01, true, ALICE_ID, "Alice", None, None);
    let responder = create_peer(0x02, false, BOB_ID, "Bob", None, None);
    let step1 = session_start_handshake(alice.handle).expect("message 1");
    let truncated = &step1.outgoing[..step1.outgoing.len() / 2];
    assert!(session_process_handshake(responder.handle, truncated).is_err());
    assert_eq!(
        session_status(responder.handle).expect("status").stage,
        SessionStageName::Failed
    );
    session_close(alice.handle);
    session_close(responder.handle);

    // Exactly-ephemeral-length garbage may parse as an ephemeral (Snow
    // accepts any 32 bytes there): it must neither panic nor grant progress.
    let responder = create_peer(0x02, false, BOB_ID, "Bob", None, None);
    let result = session_process_handshake(responder.handle, &[7u8; 32]);
    match result {
        Ok(output) => {
            assert!(!output.finished);
            assert!(output.remote_identity.is_none());
            assert_eq!(
                session_status(responder.handle).expect("status").stage,
                SessionStageName::Handshaking
            );
        }
        Err(_) => assert_eq!(
            session_status(responder.handle).expect("status").stage,
            SessionStageName::Failed
        ),
    }
    session_close(responder.handle);

    // Garbage in the initiator's message-2 position fails AEAD and poisons.
    let alice = create_peer(0x01, true, ALICE_ID, "Alice", None, None);
    let responder = create_peer(0x02, false, BOB_ID, "Bob", None, None);
    let step1 = session_start_handshake(alice.handle).expect("message 1");
    session_process_handshake(responder.handle, &step1.outgoing).expect("message 2");
    assert_eq!(
        session_process_handshake(alice.handle, &[0x33u8; 64]).unwrap_err(),
        "handshake message rejected"
    );
    assert_eq!(
        session_status(alice.handle).expect("status").stage,
        SessionStageName::Failed
    );
    session_close(alice.handle);
    session_close(responder.handle);
}

#[test]
fn oversized_and_empty_handshake_messages_are_rejected() {
    let _guard = exclusive();
    let responder = create_peer(0x02, false, BOB_ID, "Bob", None, None);

    let oversized = vec![0u8; MAX_TRANSPORT_MESSAGE_LENGTH + 64];
    assert_eq!(
        session_process_handshake(responder.handle, &oversized).unwrap_err(),
        "handshake message is too large"
    );
    assert_eq!(
        session_process_handshake(responder.handle, &[]).unwrap_err(),
        "handshake message is empty"
    );
    // Rejected before any processing: the session is untouched.
    assert_eq!(
        session_status(responder.handle).expect("status").stage,
        SessionStageName::Handshaking
    );
    session_close(responder.handle);
}

#[test]
fn pinned_key_match_is_accepted_and_mismatch_fails_closed() {
    let _guard = exclusive();

    // Matching pins on both sides: the handshake completes normally.
    let alice = create_peer(
        0x01,
        true,
        ALICE_ID,
        "Alice",
        Some(&public_hex_for(0x02)),
        None,
    );
    let bob = create_peer(
        0x02,
        false,
        BOB_ID,
        "Bob",
        Some(&public_hex_for(0x01)),
        None,
    );
    drive_handshake(&alice, &bob);
    assert_eq!(
        session_status(alice.handle).expect("status").stage,
        SessionStageName::AwaitingConfirmation
    );
    session_close(alice.handle);
    session_close(bob.handle);

    // Initiator-side mismatch: pins a key that is not the responder's.
    let eve_hex = public_hex_for(0x99);
    let alice = create_peer(0x01, true, ALICE_ID, "Alice", Some(&eve_hex), None);
    let bob = create_peer(0x02, false, BOB_ID, "Bob", None, None);
    let step1 = session_start_handshake(alice.handle).expect("message 1");
    let step2 = session_process_handshake(bob.handle, &step1.outgoing).expect("message 2");
    assert_eq!(
        session_process_handshake(alice.handle, &step2.outgoing).unwrap_err(),
        "remote static key does not match the pinned key"
    );
    assert_eq!(
        session_status(alice.handle).expect("status").stage,
        SessionStageName::Failed
    );
    assert_eq!(
        session_encrypt(alice.handle, b"blocked").unwrap_err(),
        "session has failed"
    );
    session_close(alice.handle);
    session_close(bob.handle);

    // Responder-side mismatch: detected when message 3 completes the pin.
    let alice = create_peer(0x01, true, ALICE_ID, "Alice", None, None);
    let bob = create_peer(0x02, false, BOB_ID, "Bob", Some(&eve_hex), None);
    let step1 = session_start_handshake(alice.handle).expect("message 1");
    let step2 = session_process_handshake(bob.handle, &step1.outgoing).expect("message 2");
    let step3 = session_process_handshake(alice.handle, &step2.outgoing).expect("message 3");
    assert_eq!(
        session_process_handshake(bob.handle, &step3.outgoing).unwrap_err(),
        "remote static key does not match the pinned key"
    );
    assert_eq!(
        session_status(bob.handle).expect("status").stage,
        SessionStageName::Failed
    );
    // The initiator never learns of the failure through crypto alone; the
    // responder is poisoned and its caller must tear the link down.
    assert_eq!(
        session_status(alice.handle).expect("status").stage,
        SessionStageName::AwaitingConfirmation
    );
    session_close(alice.handle);
    session_close(bob.handle);
}

#[test]
fn expected_peer_device_id_binding_is_enforced() {
    let _guard = exclusive();

    // Correct expectation completes.
    let alice = create_peer(0x01, true, ALICE_ID, "Alice", None, None);
    let bob = create_peer(0x02, false, BOB_ID, "Bob", None, Some(ALICE_ID));
    drive_handshake(&alice, &bob);
    session_close(alice.handle);
    session_close(bob.handle);

    // Wrong expectation fails closed at completion and poisons the session.
    let alice = create_peer(0x01, true, ALICE_ID, "Alice", None, None);
    let bob = create_peer(0x02, false, BOB_ID, "Bob", None, Some("wrong-device-id"));
    let step1 = session_start_handshake(alice.handle).expect("message 1");
    let step2 = session_process_handshake(bob.handle, &step1.outgoing).expect("message 2");
    let step3 = session_process_handshake(alice.handle, &step2.outgoing).expect("message 3");
    assert_eq!(
        session_process_handshake(bob.handle, &step3.outgoing).unwrap_err(),
        "remote identity does not match the expected peer"
    );
    assert_eq!(
        session_status(bob.handle).expect("status").stage,
        SessionStageName::Failed
    );
    session_close(alice.handle);
    session_close(bob.handle);
}

#[test]
fn transport_requires_explicit_confirmation() {
    let _guard = exclusive();
    let alice = create_peer(0x01, true, ALICE_ID, "Alice", None, None);
    let bob = create_peer(0x02, false, BOB_ID, "Bob", None, None);
    drive_handshake(&alice, &bob);

    // Before confirmation, encrypt and decrypt are refused on both sides.
    assert_eq!(
        session_encrypt(alice.handle, b"blocked").unwrap_err(),
        "session confirmation required"
    );
    assert_eq!(
        session_decrypt(alice.handle, &[0u8; 32]).unwrap_err(),
        "session confirmation required"
    );
    assert_eq!(
        session_encrypt(bob.handle, b"blocked").unwrap_err(),
        "session confirmation required"
    );

    // Confirming one side unlocks only that side.
    session_confirm_peer_identity(alice.handle).expect("confirm alice");
    let ciphertext = session_encrypt(alice.handle, b"ping").expect("encrypt after confirm");
    assert_eq!(
        session_decrypt(bob.handle, &ciphertext).unwrap_err(),
        "session confirmation required"
    );

    // Confirmation is a one-shot transition.
    assert_eq!(
        session_confirm_peer_identity(alice.handle).unwrap_err(),
        "session is not awaiting confirmation"
    );
    session_confirm_peer_identity(bob.handle).expect("confirm bob");
    assert_eq!(
        session_decrypt(bob.handle, &ciphertext).expect("decrypt"),
        b"ping"
    );

    // Handshake operations on a transport-ready session are refused.
    assert_eq!(
        session_start_handshake(alice.handle).unwrap_err(),
        "handshake already finished"
    );
    assert_eq!(
        session_process_handshake(alice.handle, &[0u8; 32]).unwrap_err(),
        "handshake already finished"
    );
    // Only the initiator may start a handshake at all.
    session_close(alice.handle);
    session_close(bob.handle);
    let responder = create_peer(0x02, false, BOB_ID, "Bob", None, None);
    assert_eq!(
        session_start_handshake(responder.handle).unwrap_err(),
        "only the initiator starts the handshake"
    );
    session_close(responder.handle);
}

#[test]
fn tampered_ciphertext_poisons_the_session() {
    let _guard = exclusive();

    // Bit flip in the encrypted payload area.
    let (alice, bob) = confirmed_pair(0x01, 0x02);
    let ciphertext = session_encrypt(alice.handle, b"authenticated payload").expect("encrypt");
    let mut tampered = ciphertext.clone();
    tampered[0] ^= 0x01;
    assert_eq!(
        session_decrypt(bob.handle, &tampered).unwrap_err(),
        "transport message authentication failed"
    );
    assert_eq!(
        session_status(bob.handle).expect("status").stage,
        SessionStageName::Failed
    );
    // The poisoned session cannot continue in either direction, and the
    // untampered ciphertext is refused too — no recovery without reconnect.
    assert_eq!(
        session_decrypt(bob.handle, &ciphertext).unwrap_err(),
        "session has failed"
    );
    assert_eq!(
        session_encrypt(bob.handle, b"blocked").unwrap_err(),
        "session has failed"
    );
    session_close(alice.handle);
    session_close(bob.handle);

    // Truncated ciphertext (authentication tag cut short).
    let (alice, bob) = confirmed_pair(0x01, 0x02);
    let ciphertext = session_encrypt(alice.handle, b"payload").expect("encrypt");
    assert_eq!(
        session_decrypt(bob.handle, &ciphertext[..ciphertext.len() - 1]).unwrap_err(),
        "transport message authentication failed"
    );
    assert_eq!(
        session_status(bob.handle).expect("status").stage,
        SessionStageName::Failed
    );
    session_close(alice.handle);
    session_close(bob.handle);

    // Corrupted authentication tag.
    let (alice, bob) = confirmed_pair(0x01, 0x02);
    let ciphertext = session_encrypt(alice.handle, b"payload").expect("encrypt");
    let mut tampered = ciphertext;
    let last = tampered.len() - 1;
    tampered[last] ^= 0x80;
    assert_eq!(
        session_decrypt(bob.handle, &tampered).unwrap_err(),
        "transport message authentication failed"
    );
    // The sending side is unaffected by the receiver's poisoning.
    assert_eq!(
        session_status(alice.handle).expect("status").stage,
        SessionStageName::Ready
    );
    session_close(alice.handle);
    session_close(bob.handle);
}

#[test]
fn closed_and_unknown_handles_are_rejected() {
    let _guard = exclusive();
    let (alice, bob) = confirmed_pair(0x01, 0x02);

    // Unknown handles are refused by every operation.
    let unknown = 999_999u32;
    assert_eq!(
        session_status(unknown).unwrap_err(),
        "session is closed or unknown"
    );
    assert_eq!(
        session_encrypt(unknown, b"x").unwrap_err(),
        "session is closed or unknown"
    );
    assert_eq!(
        session_decrypt(unknown, &[0u8; 32]).unwrap_err(),
        "session is closed or unknown"
    );
    assert_eq!(
        session_confirm_peer_identity(unknown).unwrap_err(),
        "session is closed or unknown"
    );
    assert_eq!(
        session_process_handshake(unknown, &[0u8; 32]).unwrap_err(),
        "session is closed or unknown"
    );
    assert!(!session_close(unknown));

    // Closing one session leaves the other fully operational.
    assert!(session_close(alice.handle));
    assert!(
        !session_close(alice.handle),
        "second close reports nothing removed"
    );
    assert_eq!(
        session_encrypt(alice.handle, b"x").unwrap_err(),
        "session is closed or unknown"
    );
    assert_eq!(
        session_status(bob.handle).expect("status").stage,
        SessionStageName::Ready
    );
    let reply = session_encrypt(bob.handle, b"still alive").expect("encrypt");
    assert_eq!(reply.len(), b"still alive".len() + 16);
    session_close(bob.handle);
}

#[test]
fn closed_handle_cannot_reach_a_replacement_session() {
    let _guard = exclusive();
    let first = create_peer(0x01, true, ALICE_ID, "Alice", None, None);
    let stale = first.handle;
    assert!(session_close(stale));

    let replacement = create_peer(0x01, true, ALICE_ID, "Alice", None, None);
    assert_ne!(replacement.handle, stale, "handles must never be recycled");

    // The stale handle is dead; the replacement is a distinct live session.
    assert_eq!(
        session_status(stale).unwrap_err(),
        "session is closed or unknown"
    );
    assert_eq!(
        session_encrypt(stale, b"x").unwrap_err(),
        "session is closed or unknown"
    );
    let step1 = session_start_handshake(replacement.handle).expect("replacement works");
    assert_eq!(step1.outgoing.len(), 32);
    session_close(replacement.handle);
}

#[test]
fn concurrent_sessions_stay_isolated_under_parallel_use() {
    let _guard = exclusive();
    let (alice_a, bob_a) = confirmed_pair(0x01, 0x02);
    let (alice_b, bob_b) = confirmed_pair(0x03, 0x04);

    let roundtrips = |initiator: u32, responder: u32, tag: &'static str| {
        for i in 0..32 {
            let outbound = format!("{tag}-{i}");
            let ciphertext = session_encrypt(initiator, outbound.as_bytes())
                .unwrap_or_else(|e| panic!("{tag} encrypt {i}: {e}"));
            let decoded = session_decrypt(responder, &ciphertext)
                .unwrap_or_else(|e| panic!("{tag} decrypt {i}: {e}"));
            assert_eq!(decoded, outbound.as_bytes(), "{tag} direction 1, round {i}");
        }
    };

    let a = (alice_a.handle, bob_a.handle);
    let b = (alice_b.handle, bob_b.handle);
    let thread_a = std::thread::spawn(move || roundtrips(a.0, a.1, "pair-a"));
    let thread_b = std::thread::spawn(move || roundtrips(b.0, b.1, "pair-b"));
    // A panicked thread surfaces here as a join error.
    thread_a.join().expect("pair-a thread must not panic");
    thread_b.join().expect("pair-b thread must not panic");

    // Counter integrity survived the interleaving on both pairs.
    assert_eq!(
        session_status(alice_a.handle).expect("status").stage,
        SessionStageName::Ready
    );
    assert_eq!(
        session_status(bob_b.handle).expect("status").stage,
        SessionStageName::Ready
    );

    // Cross-pair traffic is rejected (and poisons the receiving session).
    let cross = session_encrypt(alice_a.handle, b"wrong pair").expect("encrypt");
    assert_eq!(
        session_decrypt(bob_b.handle, &cross).unwrap_err(),
        "transport message authentication failed"
    );
    session_close(alice_a.handle);
    session_close(bob_a.handle);
    session_close(alice_b.handle);
    session_close(bob_b.handle);
}

#[test]
fn session_capacity_is_bounded_and_released_on_close() {
    let _guard = exclusive();
    let seed = vec![0x01u8; 32];
    let public_hex = derive_identity_public_key_hex(&seed).expect("derive");
    install_identity(&seed, &public_hex).expect("install");

    let mut handles = Vec::new();
    for _ in 0..MAX_SESSIONS {
        handles.push(session_create(true, ALICE_ID, "Alice", None, None).expect("create"));
    }
    assert!(
        handles.iter().copied().collect::<HashSet<_>>().len() == MAX_SESSIONS,
        "handles must be unique"
    );
    assert_eq!(
        session_create(true, ALICE_ID, "Alice", None, None).unwrap_err(),
        "too many active sessions"
    );

    // Closing one session frees exactly one slot.
    assert!(session_close(handles[0]));
    let extra = session_create(true, ALICE_ID, "Alice", None, None).expect("create after close");
    assert_eq!(
        session_create(true, ALICE_ID, "Alice", None, None).unwrap_err(),
        "too many active sessions"
    );

    // Teardown releases every slot again.
    for handle in handles.into_iter().skip(1).chain([extra]) {
        assert!(session_close(handle));
    }
    for _ in 0..MAX_SESSIONS {
        let handle = session_create(true, ALICE_ID, "Alice", None, None).expect("recreate");
        assert!(session_close(handle));
    }
}

/// Multiple simultaneous sessions must keep fully independent cipher state.
///
/// Multi-connection foundation (Phase 3): two confirmed links are live at
/// once, exactly as the runtime holds one Noise session per connected peer.
/// A ciphertext produced by one link must decrypt only on its own peer, and
/// closing one link must never disturb the other's counters or transport.
#[test]
fn concurrent_sessions_keep_independent_counters_and_ciphers() {
    let _guard = exclusive();
    let (alice_a, bob_a) = confirmed_pair(0x01, 0x02);
    let (alice_b, bob_b) = confirmed_pair(0x03, 0x04);

    // Both links are ready and hold distinct sessions.
    assert_eq!(
        session_status(alice_a.handle).expect("status").stage,
        SessionStageName::Ready
    );
    assert_eq!(
        session_status(alice_b.handle).expect("status").stage,
        SessionStageName::Ready
    );
    assert_ne!(alice_a.handle, alice_b.handle);
    assert_ne!(bob_a.handle, bob_b.handle);

    // Link A carries traffic while link B stays idle: A's counters advance.
    let a_ciphertext = session_encrypt(alice_a.handle, b"link A payload").expect("encrypt A");
    assert_eq!(
        session_decrypt(bob_a.handle, &a_ciphertext).expect("decrypt A"),
        b"link A payload"
    );

    // Link B is untouched: it can still send its own first message, which is
    // not a replay of A's (independent counters) and never cross-decrypts.
    let b_ciphertext = session_encrypt(alice_b.handle, b"link B payload").expect("encrypt B");
    assert_eq!(
        session_decrypt(bob_b.handle, &b_ciphertext).expect("decrypt B"),
        b"link B payload"
    );
    assert_ne!(a_ciphertext, b_ciphertext);

    // Closing link A leaves link B fully usable: B keeps exchanging messages
    // with its own counters intact. This mirrors the runtime rule that one
    // peer's disconnect never tears down another peer's link.
    assert!(session_close(alice_a.handle));
    assert!(session_close(bob_a.handle));
    let b_next = session_encrypt(alice_b.handle, b"link B still alive").expect("encrypt B again");
    assert_eq!(
        session_decrypt(bob_b.handle, &b_next).expect("decrypt B again"),
        b"link B still alive"
    );
    assert_ne!(a_ciphertext, b_next);

    // A ciphertext from one link must never decrypt on another link's peer.
    // This runs last because a failed decrypt deliberately poisons the
    // receiving session (proven by `tampered_ciphertext_poisons_the_session`),
    // so it would break the surviving-link checks above.
    assert_eq!(
        session_decrypt(bob_b.handle, &a_ciphertext).unwrap_err(),
        "transport message authentication failed"
    );

    assert!(session_close(alice_b.handle));
    assert!(session_close(bob_b.handle));
}

/// Closing one session must not close or reset any other session.
///
/// Mirrors the runtime rule that one peer's disconnect never tears down
/// another peer's link: the surviving sessions keep their stage, their pinned
/// remote identity and their ability to encrypt.
#[test]
fn closing_one_session_leaves_the_others_untouched() {
    let _guard = exclusive();
    let (alice_a, bob_a) = confirmed_pair(0x11, 0x12);
    let (alice_b, bob_b) = confirmed_pair(0x13, 0x14);

    // Close link A entirely.
    assert!(session_close(alice_a.handle));
    assert!(session_close(bob_a.handle));

    // Closed handles are rejected and are not reused for later sessions.
    assert!(session_encrypt(alice_a.handle, b"zombie").is_err());
    assert!(session_decrypt(bob_a.handle, b"zombie").is_err());
    assert!(session_status(alice_a.handle).is_err());

    // Link B is still confirmed, still ready, and still carries traffic.
    let report = session_status(alice_b.handle).expect("status B");
    assert_eq!(report.stage, SessionStageName::Ready);
    let ciphertext = session_encrypt(bob_b.handle, b"survivor").expect("encrypt survivor");
    assert_eq!(
        session_decrypt(alice_b.handle, &ciphertext).expect("decrypt survivor"),
        b"survivor"
    );

    assert!(session_close(alice_b.handle));
    assert!(session_close(bob_b.handle));
}

/// A fresh session must never receive a recycled handle of a closed session.
///
/// Handle reuse would let a late frame for a torn-down link be routed into an
/// unrelated peer's live session; the registry must keep every handle unique
/// for the lifetime of the process.
#[test]
fn session_handles_are_not_reused_after_close() {
    let _guard = exclusive();
    let seed = vec![0x21u8; 32];
    let public_hex = derive_identity_public_key_hex(&seed).expect("derive");
    install_identity(&seed, &public_hex).expect("install");

    let first = session_create(true, ALICE_ID, "Alice", None, None).expect("create");
    assert!(session_close(first));

    let mut seen = HashSet::new();
    seen.insert(first);
    for _ in 0..MAX_SESSIONS {
        let handle = session_create(true, ALICE_ID, "Alice", None, None).expect("create");
        assert!(
            seen.insert(handle),
            "a closed session's handle was reused for a new session"
        );
        assert!(session_close(handle));
    }
}

#[test]
fn fresh_sessions_use_fresh_ephemeral_material() {
    let _guard = exclusive();
    let seed = vec![0x01u8; 32];
    let public_hex = derive_identity_public_key_hex(&seed).expect("derive");
    install_identity(&seed, &public_hex).expect("install");

    let first = session_create(true, ALICE_ID, "Alice", None, None).expect("create");
    let message_one_a = session_start_handshake(first).expect("message 1").outgoing;
    assert!(session_close(first));

    let second = session_create(true, ALICE_ID, "Alice", None, None).expect("create");
    let message_one_b = session_start_handshake(second).expect("message 1").outgoing;
    assert!(session_close(second));

    // Same static identity, different ephemeral: message 1 must differ.
    assert_eq!(message_one_a.len(), 32);
    assert_eq!(message_one_b.len(), 32);
    assert_ne!(message_one_a, message_one_b);
}

#[test]
fn malformed_pin_and_creation_arguments_are_rejected() {
    let _guard = exclusive();
    let seed = vec![0x01u8; 32];
    let public_hex = derive_identity_public_key_hex(&seed).expect("derive");
    install_identity(&seed, &public_hex).expect("install");

    // Every malformed pin encoding fails without allocating a session.
    for pin in [
        "not-hex",
        "",
        "zz".repeat(32).as_str(),
        "00".repeat(31).as_str(),
        "00".repeat(33).as_str(),
    ] {
        assert!(
            session_create(true, ALICE_ID, "Alice", Some(pin), None).is_err(),
            "pin {pin:?} must be rejected"
        );
    }

    // Invalid local identity fields and expected-device arguments.
    assert!(session_create(true, "", "Alice", None, None).is_err());
    assert!(session_create(true, "   ", "Alice", None, None).is_err());
    assert!(session_create(true, ALICE_ID, "", None, None).is_err());
    assert!(session_create(true, ALICE_ID, "Alice", None, Some("")).is_err());
    assert!(session_create(true, ALICE_ID, "Alice", None, Some(&"d".repeat(129))).is_err());

    // The registry held none of the rejected creations.
    let handle = session_create(true, ALICE_ID, "Alice", None, None).expect("create");
    assert!(session_close(handle));
}

#[test]
fn identity_payload_limits_are_enforced_through_the_public_api() {
    let _guard = exclusive();

    // Boundary sizes encode; one byte over fails.
    assert!(encode_identity_payload(&"d".repeat(128), "Alice").is_ok());
    assert!(encode_identity_payload(&"d".repeat(129), "Alice").is_err());
    assert!(encode_identity_payload("device", &"n".repeat(64)).is_ok());
    assert!(encode_identity_payload("device", &"n".repeat(65)).is_err());

    // Well-formed encoding decodes with all fields intact.
    let encoded = encode_identity_payload(ALICE_ID, "Alice").expect("encode");
    assert!(encoded.len() <= MAX_IDENTITY_PAYLOAD_LENGTH);
    let decoded = decode_identity_payload(&encoded).expect("decode");
    assert_eq!(decoded.device_id, ALICE_ID);
    assert_eq!(decoded.display_name, "Alice");
    assert_eq!(decoded.capabilities, CAPABILITY_SECURE_TEXT);

    // Every truncation, an appended byte and a bad version are rejected.
    for len in 0..encoded.len() {
        assert!(
            decode_identity_payload(&encoded[..len]).is_err(),
            "prefix {len}"
        );
    }
    let mut trailing = encoded.clone();
    trailing.push(0);
    assert!(decode_identity_payload(&trailing).is_err());
    let mut bad_version = encoded;
    bad_version[0] = 2;
    assert!(decode_identity_payload(&bad_version).is_err());
}

#[test]
fn transport_boundaries_and_message_limits_are_enforced() {
    let _guard = exclusive();
    let (alice, bob) = confirmed_pair(0x01, 0x02);

    // Maximum-size plaintext roundtrips within one BLE transfer.
    let largest = vec![0x41u8; MAX_TRANSPORT_PLAINTEXT_LENGTH];
    let ciphertext = session_encrypt(alice.handle, &largest).expect("max encrypt");
    assert_eq!(ciphertext.len(), MAX_TRANSPORT_MESSAGE_LENGTH);
    assert_eq!(
        session_decrypt(bob.handle, &ciphertext).expect("max decrypt"),
        largest
    );

    // One byte over the plaintext limit is rejected before allocation.
    let oversized = vec![0u8; MAX_TRANSPORT_PLAINTEXT_LENGTH + 1];
    assert_eq!(
        session_encrypt(alice.handle, &oversized).unwrap_err(),
        "plaintext is too large"
    );

    // Oversized and undersized ciphertexts are rejected up front.
    let oversized_ct = vec![0u8; MAX_TRANSPORT_MESSAGE_LENGTH + 1];
    assert_eq!(
        session_decrypt(bob.handle, &oversized_ct).unwrap_err(),
        "ciphertext is too large"
    );
    assert_eq!(
        session_decrypt(bob.handle, &[0u8; 15]).unwrap_err(),
        "ciphertext is too short"
    );

    // Empty plaintext roundtrips as a tag-only message.
    let empty = session_encrypt(alice.handle, &[]).expect("empty encrypt");
    assert_eq!(empty.len(), 16);
    assert_eq!(
        session_decrypt(bob.handle, &empty).expect("empty decrypt"),
        b""
    );

    // The failed size checks left the session healthy.
    assert_eq!(
        session_status(alice.handle).expect("status").stage,
        SessionStageName::Ready
    );
    session_close(alice.handle);
    session_close(bob.handle);
}

#[test]
fn no_invalid_input_causes_a_panic() {
    let _guard = exclusive();
    let mut prng = XorShift(0x243f_6a88_85a3_08d3);

    // Random bytes into the handshake path on fresh responders.
    let seed = vec![0x02u8; 32];
    let public_hex = derive_identity_public_key_hex(&seed).expect("derive");
    install_identity(&seed, &public_hex).expect("install");
    for _ in 0..16 {
        let length = prng.next_u64() as usize % 2048;
        let garbage = prng.bytes(length);
        let responder = session_create(false, BOB_ID, "Bob", None, None).expect("create");
        // Any Ok or Err is acceptable; a panic is not.
        let _ = session_process_handshake(responder, &garbage);
        let _ = session_close(responder);
    }

    // Random bytes into the identity-payload decoder.
    for _ in 0..16 {
        let length = prng.next_u64() as usize % 600;
        let garbage = prng.bytes(length);
        let _ = decode_identity_payload(&garbage);
    }

    // Random ciphertexts against freshly confirmed sessions.
    for _ in 0..8 {
        let (alice, bob) = confirmed_pair(0x01, 0x02);
        let length = prng.next_u64() as usize % 512;
        let garbage = prng.bytes(length);
        // Length-shaped garbage reaches Snow's AEAD check; anything shorter
        // than the tag is rejected earlier without touching the session.
        // Neither may panic.
        let result = session_decrypt(bob.handle, &garbage);
        if garbage.len() >= 16 {
            assert!(result.is_err());
            assert_eq!(
                session_status(bob.handle).expect("status").stage,
                SessionStageName::Failed,
                "any failed authenticated decrypt must poison the session"
            );
        }
        session_close(alice.handle);
        session_close(bob.handle);
    }
}

#[test]
fn installed_identity_lifecycle_survives_session_use() {
    let _guard = exclusive();
    clear_installed_identity();
    assert_eq!(installed_public_key_hex().expect("query"), None);

    // Sessions cannot be created without an installed identity.
    assert_eq!(
        session_create(true, ALICE_ID, "Alice", None, None).unwrap_err(),
        "no identity is installed"
    );

    // Install, create a session, close it: the identity stays installed and
    // functional exactly as before this phase.
    let seed = vec![0x42u8; 32];
    let public_hex = derive_identity_public_key_hex(&seed).expect("derive");
    install_identity(&seed, &public_hex).expect("install");
    assert_eq!(
        installed_public_key_hex().expect("query"),
        Some(public_hex.clone())
    );
    let handle = session_create(true, ALICE_ID, "Alice", None, None).expect("create");
    assert!(session_close(handle));
    assert_eq!(
        installed_public_key_hex().expect("query"),
        Some(public_hex.clone())
    );

    // A rejected install still cannot clobber the established identity.
    assert!(install_identity(&[0x07u8; 32], &public_hex).is_err());
    assert!(installed_public_key_hex().expect("query").is_some());

    clear_installed_identity();
    assert_eq!(installed_public_key_hex().expect("query"), None);
    assert!(session_create(true, ALICE_ID, "Alice", None, None).is_err());
}

/// Small deterministic PRNG so the hostile-input tests need no extra
/// dependency. Not cryptographic; only test input variety depends on it.
struct XorShift(u64);

impl XorShift {
    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    fn bytes(&mut self, len: usize) -> Vec<u8> {
        let mut out = Vec::with_capacity(len.max(8));
        while out.len() < len {
            out.extend_from_slice(&self.next_u64().to_le_bytes());
        }
        out.truncate(len);
        out
    }
}
