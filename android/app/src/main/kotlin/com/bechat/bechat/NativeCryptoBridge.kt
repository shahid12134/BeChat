package com.bechat.bechat

/**
 * Narrow Kotlin-to-Rust boundary for the production BeChat crypto backend.
 *
 * The shared library [libbechat_crypto] is built from `native/rust` by the
 * cargokit Gradle plugin declared in `native/rust_builder`. JNI symbol names
 * derive from this package and class name, so renaming either requires a
 * matching change in `native/rust/src/native_jni.rs`.
 *
 * The identity functions below are the only path private seed material can
 * take: Kotlin passes a seed to Rust (or receives one for wrapping) directly
 * through JNI. Nothing on this object returns the installed private seed, and
 * none of it is reachable from Dart except through [NativeIdentityController],
 * which exposes only non-secret status.
 */
object NativeCryptoBridge {
    init {
        System.loadLibrary("bechat_crypto")
    }

    /** Fixed, non-secret identifier proving the native library is loaded. */
    external fun nativeBackendVersion(): String

    /**
     * Generates a fresh Noise static identity seed in Rust.
     *
     * Returns secret seed bytes. Callers must wrap them immediately with the
     * Android Keystore key and must never hand them to Dart.
     */
    external fun nativeGenerateSeed(): ByteArray?

    /** Derives the lowercase-hex public key for a candidate seed. */
    external fun nativePublicKeyForSeed(seed: ByteArray): String?

    /**
     * Validates a seed against [expectedPublicKeyHex] and installs it.
     *
     * Returns `false` without changing the installed identity when the seed,
     * the expected key, or their correspondence is invalid.
     */
    external fun nativeInstallSeed(seed: ByteArray, expectedPublicKeyHex: String): Boolean

    /** Drops the installed identity from native memory. */
    external fun nativeClearInstalledIdentity(): Boolean

    /** Returns the installed public key as lowercase hex, or `null`. */
    external fun nativeInstalledPublicKeyHex(): String?

    // ------------------------------------------------------- secure sessions
    //
    // Phase 2C session surface. Every session operation uses the identity
    // already installed by the lifecycle above: there is no parameter for a
    // seed or any private-key bytes, and no result contains key material
    // beyond public keys. Structured results arrive as `java.util.HashMap`
    // with fixed, non-secret keys; binary payloads (handshake messages,
    // ciphertext, plaintext) travel as `ByteArray`. Failures throw
    // `IllegalStateException` with one of the Rust session engine's fixed,
    // non-secret error strings.

    /**
     * Creates a Noise XX session over the installed identity.
     *
     * @param initiator `true` when this side sends handshake message 1.
     * @param pinnedRemotePublicKeyHex optional expected peer static key
     *   (lowercase-hex X25519); a mismatch fails the handshake closed.
     * @param expectedRemoteDeviceId optional device UUID the peer's
     *   authenticated identity payload must assert.
     * @return the opaque session handle (`> 0`).
     */
    external fun nativeSessionCreate(
        initiator: Boolean,
        deviceId: String,
        displayName: String,
        pinnedRemotePublicKeyHex: String?,
        expectedRemoteDeviceId: String?,
    ): Int

    /**
     * Produces handshake message 1 (initiator sessions only).
     *
     * Result map: `outgoing: ByteArray`, `finished: Boolean`,
     * `confirmationRequired: Boolean`, `remoteIdentity: Map?`.
     */
    external fun nativeSessionStartHandshake(handle: Int): HashMap<String, Any?>

    /**
     * Processes one inbound handshake message and returns the next outbound
     * message in the same result-map shape as
     * [nativeSessionStartHandshake]. The authenticated remote identity is
     * reported in the step that decrypts its payload.
     */
    external fun nativeSessionProcessHandshake(
        handle: Int,
        incoming: ByteArray,
    ): HashMap<String, Any?>

    /**
     * Non-secret status snapshot: `stage: String`, `remotePublicKeyHex:
     * String?`, `remoteIdentityAvailable: Boolean`.
     */
    external fun nativeSessionStatus(handle: Int): HashMap<String, Any?>

    /**
     * Explicitly confirms the authenticated remote identity, unlocking
     * [nativeSessionEncrypt]/[nativeSessionDecrypt]. Never marks a peer
     * `verified`: that stays an out-of-band, application-layer decision.
     */
    external fun nativeSessionConfirmPeerIdentity(handle: Int)

    /** Encrypts one plaintext payload with a confirmed session. */
    external fun nativeSessionEncrypt(handle: Int, plaintext: ByteArray): ByteArray

    /**
     * Decrypts one authenticated transport payload. A failed decrypt poisons
     * the session in Rust; the caller must close it and reconnect.
     */
    external fun nativeSessionDecrypt(handle: Int, ciphertext: ByteArray): ByteArray

    /** Closes a session. Idempotent; unknown or closed handles return `false`. */
    external fun nativeSessionClose(handle: Int): Boolean
}
