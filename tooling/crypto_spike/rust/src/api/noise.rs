use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use sha2::{Digest, Sha256};
use snow::{Builder, HandshakeState, TransportState};
use zeroize::Zeroizing;

const XX_PATTERN: &str = "Noise_XX_25519_ChaChaPoly_SHA256";
const IK_PATTERN: &str = "Noise_IK_25519_ChaChaPoly_SHA256";
const PROLOGUE: &[u8] = b"BeChat crypto spike v1";
const MAX_NOISE_MESSAGE: usize = 65535;

pub struct PublicIdentity {
    pub public_key_hex: String,
    pub fingerprint_hex: String,
}

pub struct HandshakeOutput {
    pub outgoing: Vec<u8>,
    pub finished: bool,
    pub remote_public_key_hex: Option<String>,
}

struct PeerIdentity {
    private_key: Zeroizing<Vec<u8>>,
    public_key: Vec<u8>,
}

enum SessionStage {
    Handshake(Box<HandshakeState>),
    Transport(Box<TransportState>),
    Failed,
}

struct Session {
    stage: SessionStage,
    expected_remote: Option<Vec<u8>>,
    remote_public: Option<Vec<u8>>,
}

struct Engine {
    peers: HashMap<u32, PeerIdentity>,
    sessions: HashMap<u32, Session>,
    next_handle: u32,
}

static ENGINE: OnceLock<Mutex<Engine>> = OnceLock::new();

fn engine() -> &'static Mutex<Engine> {
    ENGINE.get_or_init(|| {
        Mutex::new(Engine {
            peers: HashMap::new(),
            sessions: HashMap::new(),
            next_handle: 0,
        })
    })
}

fn with_engine<T>(operation: impl FnOnce(&mut Engine) -> Result<T, String>) -> Result<T, String> {
    let mut guard = engine().lock().map_err(|_| "crypto engine unavailable")?;
    operation(&mut guard)
}

fn next_handle(engine: &mut Engine) -> u32 {
    loop {
        engine.next_handle = engine.next_handle.wrapping_add(1);
        if engine.next_handle == 0 {
            engine.next_handle = 1;
        }
        let handle = engine.next_handle;
        if !engine.peers.contains_key(&handle) && !engine.sessions.contains_key(&handle) {
            return handle;
        }
    }
}

fn sha256_hex(value: &[u8]) -> String {
    hex::encode(Sha256::digest(value))
}

fn decode_public_key(value: &str) -> Result<Vec<u8>, String> {
    let bytes = hex::decode(value).map_err(|_| "invalid remote public key")?;
    if bytes.len() != 32 {
        return Err("invalid remote public key length".into());
    }
    Ok(bytes)
}

fn pattern_for(value: &str) -> Result<&'static str, String> {
    match value {
        "XX" => Ok(XX_PATTERN),
        "IK" => Ok(IK_PATTERN),
        _ => Err("unsupported Noise pattern".into()),
    }
}

fn verify_remote(session: &Session, remote: Option<&[u8]>) -> Result<(), String> {
    if let Some(expected) = session.expected_remote.as_deref() {
        match remote {
            Some(actual) if actual == expected => Ok(()),
            Some(_) => Err("remote static key does not match expected key".into()),
            None => Err("remote static key was not authenticated".into()),
        }
    } else {
        Ok(())
    }
}

fn finish_handshake(
    session: &mut Session,
    handshake: Box<HandshakeState>,
    remote: Option<&[u8]>,
) -> Result<TransportState, String> {
    verify_remote(session, remote)?;
    (*handshake)
        .into_transport_mode()
        .map_err(|_| "could not enter transport mode".into())
}

pub fn create_test_peer() -> Result<u32, String> {
    let builder = Builder::new(XX_PATTERN.parse().map_err(|_| "invalid Noise parameters")?);
    let keypair = builder
        .generate_keypair()
        .map_err(|_| "identity key generation failed")?;

    with_engine(|engine| {
        let handle = next_handle(engine);
        engine.peers.insert(
            handle,
            PeerIdentity {
                private_key: Zeroizing::new(keypair.private),
                public_key: keypair.public,
            },
        );
        Ok(handle)
    })
}

pub fn public_identity(peer_handle: u32) -> Result<PublicIdentity, String> {
    with_engine(|engine| {
        let peer = engine
            .peers
            .get(&peer_handle)
            .ok_or("peer is closed or unknown")?;
        Ok(PublicIdentity {
            public_key_hex: hex::encode(&peer.public_key),
            fingerprint_hex: sha256_hex(&peer.public_key),
        })
    })
}

pub fn create_session(
    peer_handle: u32,
    pattern: String,
    initiator: bool,
    expected_remote_public_key_hex: Option<String>,
) -> Result<u32, String> {
    let pattern = pattern_for(&pattern)?;
    let expected_remote = expected_remote_public_key_hex
        .as_deref()
        .map(decode_public_key)
        .transpose()?;

    if pattern == IK_PATTERN && initiator && expected_remote.is_none() {
        return Err("IK initiator requires an expected remote public key".into());
    }

    with_engine(|engine| {
        let private_key = engine
            .peers
            .get(&peer_handle)
            .ok_or("peer is closed or unknown")?
            .private_key
            .clone();

        let mut builder = Builder::new(pattern.parse().map_err(|_| "invalid Noise parameters")?)
            .local_private_key(&private_key)
            .map_err(|_| "invalid local identity key")?
            .prologue(PROLOGUE)
            .map_err(|_| "invalid Noise prologue")?;

        if pattern == IK_PATTERN && initiator {
            builder = builder
                .remote_public_key(
                    expected_remote
                        .as_deref()
                        .ok_or("IK initiator requires an expected remote public key")?,
                )
                .map_err(|_| "invalid remote static key")?;
        }

        let handshake = if initiator {
            builder.build_initiator()
        } else {
            builder.build_responder()
        }
        .map_err(|_| "could not initialize Noise handshake")?;

        let handle = next_handle(engine);
        engine.sessions.insert(
            handle,
            Session {
                stage: SessionStage::Handshake(Box::new(handshake)),
                expected_remote,
                remote_public: None,
            },
        );
        Ok(handle)
    })
}

pub fn handshake_start(session_handle: u32) -> Result<HandshakeOutput, String> {
    with_engine(|engine| {
        let session = engine
            .sessions
            .get_mut(&session_handle)
            .ok_or("session is closed or unknown")?;

        let stage = std::mem::replace(&mut session.stage, SessionStage::Failed);
        let SessionStage::Handshake(mut handshake) = stage else {
            return Err(match stage {
                SessionStage::Transport(_) => "handshake already finished",
                SessionStage::Failed => "session is failed",
                SessionStage::Handshake(_) => unreachable!(),
            }
            .into());
        };

        if !handshake.is_my_turn() {
            return Err("handshake is waiting for the remote message".into());
        }

        let mut outgoing = vec![0_u8; MAX_NOISE_MESSAGE];
        let len = match handshake.write_message(&[], &mut outgoing) {
            Ok(len) => len,
            Err(_) => return Err("could not write handshake message".into()),
        };
        outgoing.truncate(len);

        let remote = handshake.get_remote_static().map(|key| key.to_vec());
        let finished = handshake.is_handshake_finished();
        if finished {
            let transport = finish_handshake(session, handshake, remote.as_deref())?;
            session.remote_public = remote;
            session.stage = SessionStage::Transport(Box::new(transport));
        } else {
            session.stage = SessionStage::Handshake(handshake);
        }

        Ok(HandshakeOutput {
            outgoing,
            finished,
            remote_public_key_hex: session.remote_public.as_deref().map(hex::encode),
        })
    })
}

pub fn handshake_step(session_handle: u32, incoming: Vec<u8>) -> Result<HandshakeOutput, String> {
    if incoming.len() > MAX_NOISE_MESSAGE {
        return Err("handshake message is too large".into());
    }

    with_engine(|engine| {
        let session = engine
            .sessions
            .get_mut(&session_handle)
            .ok_or("session is closed or unknown")?;

        let stage = std::mem::replace(&mut session.stage, SessionStage::Failed);
        let SessionStage::Handshake(mut handshake) = stage else {
            return Err(match stage {
                SessionStage::Transport(_) => "handshake already finished",
                SessionStage::Failed => "session is failed",
                SessionStage::Handshake(_) => unreachable!(),
            }
            .into());
        };

        if handshake.is_my_turn() {
            return Err("handshake is waiting for a local message".into());
        }

        let mut payload = vec![0_u8; incoming.len()];
        if handshake.read_message(&incoming, &mut payload).is_err() {
            return Err("handshake message rejected".into());
        }

        let mut outgoing = Vec::new();
        if !handshake.is_handshake_finished() {
            if !handshake.is_my_turn() {
                return Err("unexpected handshake state".into());
            }
            outgoing.resize(MAX_NOISE_MESSAGE, 0);
            let len = match handshake.write_message(&[], &mut outgoing) {
                Ok(len) => len,
                Err(_) => return Err("could not write handshake message".into()),
            };
            outgoing.truncate(len);
        }

        let remote = handshake.get_remote_static().map(|key| key.to_vec());
        let finished = handshake.is_handshake_finished();
        if finished {
            let transport = finish_handshake(session, handshake, remote.as_deref())?;
            session.remote_public = remote;
            session.stage = SessionStage::Transport(Box::new(transport));
        } else {
            session.stage = SessionStage::Handshake(handshake);
        }

        Ok(HandshakeOutput {
            outgoing,
            finished,
            remote_public_key_hex: session.remote_public.as_deref().map(hex::encode),
        })
    })
}

pub fn encrypt(session_handle: u32, plaintext: Vec<u8>) -> Result<Vec<u8>, String> {
    if plaintext.len() > MAX_NOISE_MESSAGE {
        return Err("plaintext is too large".into());
    }

    with_engine(|engine| {
        let session = engine
            .sessions
            .get_mut(&session_handle)
            .ok_or("session is closed or unknown")?;

        let SessionStage::Transport(transport) = &mut session.stage else {
            session.stage = SessionStage::Failed;
            return Err("session is not in transport mode".into());
        };

        let mut ciphertext = vec![0_u8; plaintext.len() + 16];
        match transport.write_message(&plaintext, &mut ciphertext) {
            Ok(len) => {
                ciphertext.truncate(len);
                Ok(ciphertext)
            }
            Err(_) => {
                session.stage = SessionStage::Failed;
                Err("encryption failed".into())
            }
        }
    })
}

pub fn decrypt(session_handle: u32, ciphertext: Vec<u8>) -> Result<Vec<u8>, String> {
    if ciphertext.len() > MAX_NOISE_MESSAGE + 16 {
        return Err("ciphertext is too large".into());
    }

    with_engine(|engine| {
        let session = engine
            .sessions
            .get_mut(&session_handle)
            .ok_or("session is closed or unknown")?;

        let SessionStage::Transport(transport) = &mut session.stage else {
            session.stage = SessionStage::Failed;
            return Err("session is not in transport mode".into());
        };

        let mut plaintext = vec![0_u8; ciphertext.len()];
        match transport.read_message(&ciphertext, &mut plaintext) {
            Ok(len) => {
                plaintext.truncate(len);
                Ok(plaintext)
            }
            Err(_) => {
                session.stage = SessionStage::Failed;
                Err("authentication failed".into())
            }
        }
    })
}

pub fn close_session(session_handle: u32) -> bool {
    with_engine(|engine| Ok(engine.sessions.remove(&session_handle).is_some())).unwrap_or(false)
}

pub fn close_peer(peer_handle: u32) -> bool {
    with_engine(|engine| Ok(engine.peers.remove(&peer_handle).is_some())).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identities(a: u32, b: u32) -> (String, String) {
        (
            public_identity(a).unwrap().public_key_hex,
            public_identity(b).unwrap().public_key_hex,
        )
    }

    fn complete_xx(a: u32, b: u32) -> (u32, u32) {
        let (a_public, b_public) = identities(a, b);
        let initiator = create_session(a, "XX".into(), true, None).unwrap();
        let responder = create_session(b, "XX".into(), false, None).unwrap();

        let first = handshake_start(initiator).unwrap();
        assert!(!first.outgoing.is_empty());
        let second = handshake_step(responder, first.outgoing).unwrap();
        assert!(!second.outgoing.is_empty());
        let third = handshake_step(initiator, second.outgoing).unwrap();
        assert!(!third.outgoing.is_empty());
        assert_eq!(
            third.remote_public_key_hex.as_deref(),
            Some(b_public.as_str())
        );
        let fourth = handshake_step(responder, third.outgoing).unwrap();
        assert!(fourth.finished);
        assert_eq!(fourth.outgoing.len(), 0);
        assert_eq!(
            fourth.remote_public_key_hex.as_deref(),
            Some(a_public.as_str())
        );

        (initiator, responder)
    }

    fn complete_ik(a: u32, b: u32) -> (u32, u32) {
        let (a_public, b_public) = identities(a, b);
        let initiator = create_session(a, "IK".into(), true, Some(b_public.clone())).unwrap();
        let responder = create_session(b, "IK".into(), false, Some(a_public.clone())).unwrap();

        let first = handshake_start(initiator).unwrap();
        let second = handshake_step(responder, first.outgoing).unwrap();
        assert_eq!(
            second.remote_public_key_hex.as_deref(),
            Some(a_public.as_str())
        );
        let third = handshake_step(initiator, second.outgoing).unwrap();
        assert!(third.finished);
        assert_eq!(
            third.remote_public_key_hex.as_deref(),
            Some(b_public.as_str())
        );

        (initiator, responder)
    }

    #[test]
    fn xx_handshake_authenticates_both_identities_and_transports_both_ways() {
        let a = create_test_peer().unwrap();
        let b = create_test_peer().unwrap();
        let (initiator, responder) = complete_xx(a, b);

        let from_a = encrypt(initiator, b"hello from a".to_vec()).unwrap();
        assert_eq!(decrypt(responder, from_a).unwrap(), b"hello from a");
        let from_b = encrypt(responder, b"hello from b".to_vec()).unwrap();
        assert_eq!(decrypt(initiator, from_b).unwrap(), b"hello from b");
    }

    #[test]
    fn tampered_ciphertext_is_rejected() {
        let a = create_test_peer().unwrap();
        let b = create_test_peer().unwrap();
        let (initiator, responder) = complete_xx(a, b);
        let mut ciphertext = encrypt(initiator, b"tamper me".to_vec()).unwrap();
        let last = ciphertext.len() - 1;
        ciphertext[last] ^= 0x80;
        assert!(decrypt(responder, ciphertext).is_err());
        assert!(encrypt(responder, b"failed state".to_vec()).is_err());
    }

    #[test]
    fn malformed_handshake_is_rejected_safely() {
        let b = create_test_peer().unwrap();
        let responder = create_session(b, "XX".into(), false, None).unwrap();
        assert!(handshake_step(responder, vec![0_u8; 1]).is_err());
        assert!(handshake_step(responder, vec![1_u8; 1]).is_err());
        assert!(handshake_step(responder, vec![0_u8; MAX_NOISE_MESSAGE + 1]).is_err());
        assert!(encrypt(responder, b"not ready".to_vec()).is_err());
    }

    #[test]
    fn new_sessions_have_fresh_ephemeral_material() {
        let a = create_test_peer().unwrap();
        let b = create_test_peer().unwrap();
        let first = create_session(a, "XX".into(), true, None).unwrap();
        let second = create_session(a, "XX".into(), true, None).unwrap();
        let first_message = handshake_start(first).unwrap().outgoing;
        let second_message = handshake_start(second).unwrap().outgoing;
        assert_ne!(first_message, second_message);
        assert!(close_session(first));
        assert!(close_session(second));
        assert!(public_identity(b).is_ok());
    }

    #[test]
    fn ik_handshake_uses_trusted_static_keys_and_rejects_wrong_pins() {
        let a = create_test_peer().unwrap();
        let b = create_test_peer().unwrap();
        let (initiator, responder) = complete_ik(a, b);
        let (a_public, b_public) = identities(a, b);

        let from_a = encrypt(initiator, b"ik a".to_vec()).unwrap();
        assert_eq!(decrypt(responder, from_a).unwrap(), b"ik a");

        let c = create_test_peer().unwrap();
        let wrong_pin = public_identity(c).unwrap().public_key_hex;
        let wrong_initiator =
            create_session(a, "IK".into(), true, Some(wrong_pin.clone())).unwrap();
        let responder_b = create_session(b, "IK".into(), false, Some(a_public)).unwrap();
        let first = handshake_start(wrong_initiator).unwrap();
        assert!(handshake_step(responder_b, first.outgoing).is_err());

        let trusted_initiator =
            create_session(a, "IK".into(), true, Some(b_public.clone())).unwrap();
        let wrong_responder = create_session(b, "IK".into(), false, Some(wrong_pin)).unwrap();
        let first = handshake_start(trusted_initiator).unwrap();
        assert!(handshake_step(wrong_responder, first.outgoing).is_err());
    }

    #[test]
    fn closed_handles_are_rejected() {
        let a = create_test_peer().unwrap();
        let b = create_test_peer().unwrap();
        let (initiator, responder) = complete_xx(a, b);
        assert!(close_session(initiator));
        assert!(!close_session(initiator));
        assert!(encrypt(initiator, b"closed".to_vec()).is_err());
        assert!(handshake_step(responder, Vec::new()).is_err());
        assert!(close_peer(a));
        assert!(!close_peer(a));
    }
}
