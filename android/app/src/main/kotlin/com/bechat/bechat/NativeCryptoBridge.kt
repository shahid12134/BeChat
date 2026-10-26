package com.bechat.bechat

/**
 * Narrow Kotlin-to-Rust boundary for the production BeChat crypto backend.
 *
 * The shared library [libbechat_crypto] is built from `native/rust` by the
 * cargokit Gradle plugin declared in `native/rust_builder`. JNI symbol names
 * derive from this package and class name, so renaming either requires a
 * matching change in `native/rust/src/native_jni.rs`.
 *
 * Phase 1A exposes only a non-secret backend version string used as a load
 * smoke test. Seed generation, key material and other secret-bearing entry
 * points are deliberately absent here.
 */
object NativeCryptoBridge {
    init {
        System.loadLibrary("bechat_crypto")
    }

    /** Fixed, non-secret identifier proving the native library is loaded. */
    external fun nativeBackendVersion(): String
}
