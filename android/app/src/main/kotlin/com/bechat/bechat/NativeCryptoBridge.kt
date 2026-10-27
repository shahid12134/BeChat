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
}
