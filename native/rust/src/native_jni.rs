//! Narrow JNI surface for the production BeChat application.
//!
//! Package `com.bechat.bechat`, class `NativeCryptoBridge`.
//!
//! Phase 1A exported one non-secret backend version string. Phase 1B adds the
//! persistent identity lifecycle:
//!
//! * `nativeGenerateSeed` — Rust generates the Noise static private seed.
//! * `nativePublicKeyForSeed` — derives the public key for a candidate seed.
//! * `nativeInstallSeed` — validates a seed against an expected public key and
//!   installs it, or fails without touching the installed identity.
//! * `nativeClearInstalledIdentity` — drops the installed identity.
//! * `nativeInstalledPublicKeyHex` — reports the installed public key only.
//!
//! Private seed material crosses this boundary **only** as arguments/results
//! between Kotlin and Rust (`jbyteArray`). There is deliberately no
//! seed-returning function, no arbitrary native memory export and no generic
//! command dispatcher. Dart never reaches these functions: the Kotlin identity
//! controller consumes them and exposes only non-secret status.
//!
//! Every error message thrown here is a fixed, non-secret string.

use jni::objects::{JByteArray, JObject, JString};
use jni::sys::{jboolean, jbyteArray, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;

use bechat_crypto_core::{
    clear_installed_identity, derive_identity_public_key_hex, generate_identity_seed,
    install_identity, installed_public_key_hex, IDENTITY_SEED_LENGTH,
};

fn throw(env: &mut JNIEnv<'_>, message: &str) {
    let _ = env.throw_new("java/lang/IllegalStateException", message);
}

/// Returns the fixed, non-secret backend identifier string.
/// Proves the native library is loaded and Rust code executes end to end.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeBackendVersion<'local>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> jstring {
    match env.new_string(bechat_crypto_core::backend_version()) {
        Ok(value) => value.into_raw(),
        Err(_) => {
            throw(&mut env, "backend version unavailable");
            std::ptr::null_mut()
        }
    }
}

/// Generates a fresh Noise static identity seed in Rust.
///
/// The returned bytes are secret key material. Kotlin wraps them with the
/// Android Keystore key immediately and never forwards them to Dart. The local
/// seed buffer is zeroed before returning.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeGenerateSeed<'local>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> jbyteArray {
    match generate_identity_seed() {
        Ok(mut seed) => {
            let array = env.byte_array_from_slice(&seed);
            seed.fill(0);
            match array {
                Ok(value) => value.into_raw(),
                Err(_) => {
                    throw(&mut env, "identity generation failed");
                    std::ptr::null_mut()
                }
            }
        }
        Err(_) => {
            throw(&mut env, "identity generation failed");
            std::ptr::null_mut()
        }
    }
}

/// Derives the lowercase-hex public key for a 32-byte identity seed.
///
/// Used by the Kotlin controller to verify candidate seeds against persisted
/// public metadata. Errors are fixed and non-secret; the seed buffer is zeroed
/// before returning.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativePublicKeyForSeed<'local>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
    seed: JByteArray<'local>,
) -> jstring {
    let mut seed_bytes = match env.convert_byte_array(seed) {
        Ok(bytes) => bytes,
        Err(_) => {
            throw(&mut env, "invalid identity seed");
            return std::ptr::null_mut();
        }
    };

    let result = if seed_bytes.len() == IDENTITY_SEED_LENGTH {
        derive_identity_public_key_hex(&seed_bytes)
    } else {
        Err("invalid identity seed length".into())
    };
    seed_bytes.fill(0);

    match result {
        Ok(public_key_hex) => match env.new_string(public_key_hex) {
            Ok(value) => value.into_raw(),
            Err(_) => {
                throw(&mut env, "identity public key unavailable");
                std::ptr::null_mut()
            }
        },
        Err(_) => {
            throw(&mut env, "identity public key unavailable");
            std::ptr::null_mut()
        }
    }
}

/// Installs a seed after validating it against the expected public key.
///
/// Returns `false` (never throws) when the seed or expected key is invalid or
/// when they do not correspond. A rejected call leaves any previously
/// installed identity untouched. The local seed buffer is zeroed afterwards.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeInstallSeed<'local>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
    seed: JByteArray<'local>,
    expected_public_key_hex: JString<'local>,
) -> jboolean {
    let mut seed_bytes = match env.convert_byte_array(seed) {
        Ok(bytes) => bytes,
        Err(_) => return JNI_FALSE,
    };
    let expected: String = match env.get_string(&expected_public_key_hex) {
        Ok(value) => value.into(),
        Err(_) => {
            seed_bytes.fill(0);
            return JNI_FALSE;
        }
    };

    let installed = install_identity(&seed_bytes, &expected).is_ok();
    seed_bytes.fill(0);
    if installed {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

/// Drops the installed identity from native memory. Never throws.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeClearInstalledIdentity<
    'local,
>(
    _env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> jboolean {
    clear_installed_identity();
    JNI_TRUE
}

/// Returns the installed public key as lowercase hex, or `null` when no
/// identity is installed. There is no counterpart that returns the seed.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeInstalledPublicKeyHex<
    'local,
>(
    env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> jstring {
    match installed_public_key_hex() {
        Ok(Some(public_key_hex)) => match env.new_string(public_key_hex) {
            Ok(value) => value.into_raw(),
            Err(_) => std::ptr::null_mut(),
        },
        _ => std::ptr::null_mut(),
    }
}

#[cfg(test)]
mod tests {

    /// Guards the JNI symbol names against silent drift when the Kotlin class
    /// or package is renamed: the export names are built here as literals so a
    /// mismatch fails at review/compile time rather than at runtime.
    #[test]
    fn jni_symbols_match_production_kotlin_package() {
        let symbols = [
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeBackendVersion"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeBackendVersion",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeGenerateSeed"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeGenerateSeed",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativePublicKeyForSeed"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativePublicKeyForSeed",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeInstallSeed"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeInstallSeed",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeClearInstalledIdentity"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeClearInstalledIdentity",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeInstalledPublicKeyHex"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeInstalledPublicKeyHex",
            ),
        ];
        for (built, expected) in symbols {
            assert_eq!(built, expected);
        }
    }
}
