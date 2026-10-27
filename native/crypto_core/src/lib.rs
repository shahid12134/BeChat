//! Shared cryptographic core for the production BeChat application.
//!
//! This crate is the single home for BeChat's production Noise primitives.
//! Phase 1A wired it into the build graph; Phase 1B adds the persistent
//! Noise X25519 identity logic (`identity` module) that the production JNI
//! crate (`bechat_crypto`) exposes through the Kotlin/JNI boundary.
//!
//! The validated feasibility spike under `tooling/crypto_spike` keeps its own
//! frozen copy as regression evidence. All new production identity logic goes
//! here so only one implementation evolves: the spike is not modified and the
//! production app never links against spike code.

/// Noise handshake pattern used for BeChat's static identity work.
/// Matches the spike's suite selection exactly; semantics must not change
/// without an explicit review.
pub const NOISE_XX_PATTERN: &str = "Noise_XX_25519_ChaChaPoly_SHA256";

/// Noise handshake pattern used by the spike for initiator sessions.
pub const NOISE_IK_PATTERN: &str = "Noise_IK_25519_ChaChaPoly_SHA256";

/// Fixed, non-secret backend identifier. Contains no key material.
pub const BACKEND_VERSION: &str = "bechat-crypto-core/0.1.0 snow/0.10.0";

mod identity;

pub use identity::{
    clear_installed_identity, derive_identity_public_key, derive_identity_public_key_hex,
    generate_identity_seed, install_identity, installed_public_key_hex, IDENTITY_PUBLIC_KEY_LENGTH,
    IDENTITY_SEED_LENGTH,
};

/// Returns the non-secret backend identifier reported by the JNI smoke test.
pub fn backend_version() -> &'static str {
    BACKEND_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;
    use snow::params::NoiseParams;
    use snow::Builder;

    #[test]
    fn backend_version_is_non_secret_and_stable() {
        assert_eq!(backend_version(), BACKEND_VERSION);
        assert!(!backend_version().contains("key"));
        assert!(!backend_version().contains("seed"));
    }

    #[test]
    fn spike_suites_parse_with_pinned_snow() {
        let xx: NoiseParams = NOISE_XX_PATTERN.parse().expect("XX pattern must parse");
        let ik: NoiseParams = NOISE_IK_PATTERN.parse().expect("IK pattern must parse");
        assert_eq!(xx.name, NOISE_XX_PATTERN);
        assert_eq!(ik.name, NOISE_IK_PATTERN);
    }

    /// Proves the pinned Snow dependency compiles and executes inside the
    /// production crate graph by completing a real XX handshake and a
    /// transport-message roundtrip between two ephemeral in-memory parties.
    #[test]
    fn snow_xx_handshake_roundtrip_executes() {
        let params: NoiseParams = NOISE_XX_PATTERN.parse().expect("XX pattern must parse");

        // snow 0.10 requires an explicit local private key for patterns that
        // use a static key; generate ephemeral in-memory keypairs like the
        // spike does. These keys never leave the test process.
        let initiator_keys = Builder::new(params.clone())
            .generate_keypair()
            .expect("initiator keypair");
        let responder_keys = Builder::new(params.clone())
            .generate_keypair()
            .expect("responder keypair");

        let mut initiator = Builder::new(params.clone())
            .local_private_key(&initiator_keys.private)
            .expect("initiator key set")
            .build_initiator()
            .expect("initiator");
        let mut responder = Builder::new(params)
            .local_private_key(&responder_keys.private)
            .expect("responder key set")
            .build_responder()
            .expect("responder");

        let mut buf = [0u8; 1024];
        let mut out = [0u8; 1024];

        // Three-message XX handshake with empty payloads.
        let len = initiator.write_message(b"", &mut buf).expect("msg1");
        responder
            .read_message(&buf[..len], &mut out)
            .expect("read1");
        let len = responder.write_message(b"", &mut buf).expect("msg2");
        initiator
            .read_message(&buf[..len], &mut out)
            .expect("read2");
        let len = initiator.write_message(b"", &mut buf).expect("msg3");
        responder
            .read_message(&buf[..len], &mut out)
            .expect("read3");

        // snow keeps both sides in handshake state until explicitly converted.
        assert!(initiator.is_handshake_finished());
        assert!(responder.is_handshake_finished());
        let mut initiator = initiator
            .into_transport_mode()
            .expect("initiator transport");
        let mut responder = responder
            .into_transport_mode()
            .expect("responder transport");

        // Transport phase roundtrip of a fixed non-secret payload.
        let len = initiator.write_message(b"ping", &mut buf).expect("send");
        let n = responder.read_message(&buf[..len], &mut out).expect("recv");
        assert_eq!(&out[..n], b"ping");

        let len = responder.write_message(b"pong", &mut buf).expect("send");
        let n = initiator.read_message(&buf[..len], &mut out).expect("recv");
        assert_eq!(&out[..n], b"pong");
    }
}
