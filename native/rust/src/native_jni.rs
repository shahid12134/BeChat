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
//! Phase 2C adds the secure-session surface (same class, so only one library
//! load and one trust boundary exist):
//!
//! * `nativeSessionCreate` — creates a Noise XX session over the **installed**
//!   identity. Never accepts a seed or any private-key bytes.
//! * `nativeSessionStartHandshake` — produces handshake message 1.
//! * `nativeSessionProcessHandshake` — consumes one inbound handshake message
//!   and reports the next outbound message, whether the handshake finished,
//!   whether explicit confirmation is still required, and the authenticated
//!   remote identity once its AEAD-protected payload arrived.
//! * `nativeSessionStatus` — non-secret stage snapshot for a live session.
//! * `nativeSessionConfirmPeerIdentity` — the explicit application
//!   authorization gate; transport stays locked until it succeeds.
//! * `nativeSessionEncrypt` / `nativeSessionDecrypt` — transport operations,
//!   refused before confirmation; a failed decrypt poisons the session in
//!   Rust. There is no plaintext fallback at this boundary.
//! * `nativeSessionClose` — releases a session; idempotent and never throws.
//!
//! Result maps are plain `java.util.HashMap`s with fixed, non-secret keys;
//! binary payloads (handshake messages, ciphertext, plaintext) travel as
//! `byte[]`, which Flutter receives as typed data. Failures throw
//! `IllegalStateException` carrying one of the session engine's fixed,
//! non-secret error strings — never a debug-formatted Rust error, never key
//! material. Null references, invalid handles, oversized inputs and bad
//! string encodings are rejected before they reach the engine.
//!
//! Private seed material crosses this boundary **only** as arguments/results
//! between Kotlin and Rust (`jbyteArray`) in the identity lifecycle above.
//! There is deliberately no seed-returning function, no arbitrary native
//! memory export and no generic command dispatcher. Dart never reaches these
//! functions: the Kotlin controllers consume them and expose only non-secret
//! state.
//!
//! Every error message thrown here is a fixed, non-secret string.

use jni::objects::{JByteArray, JObject, JString, JValue};
use jni::sys::{jboolean, jbyteArray, jint, jobject, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;

use bechat_crypto_core::{
    clear_installed_identity, derive_identity_public_key_hex, generate_identity_seed,
    install_identity, installed_public_key_hex, session_close, session_confirm_peer_identity,
    session_create, session_decrypt, session_encrypt, session_process_handshake,
    session_start_handshake, session_status, HandshakeOutput, RemoteIdentity, SessionStageName,
    SessionStatusReport, IDENTITY_SEED_LENGTH,
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

// ----------------------------------------------------------- session helpers

/// Fixed error text for malformed JNI references (null arrays/strings). The
/// Kotlin controller validates first; this is the defensive backstop.
const MISSING_INPUT: &str = "a required input is missing";
/// Fixed error text when a result value cannot be encoded for Java.
const ENCODING_FAILED: &str = "secure session result could not be encoded";

fn required_string(env: &mut JNIEnv<'_>, value: &JString<'_>) -> Result<String, String> {
    if value.is_null() {
        return Err(MISSING_INPUT.to_string());
    }
    env.get_string(value)
        .map(|owned| owned.into())
        .map_err(|_| "invalid string encoding".to_string())
}

fn optional_string(env: &mut JNIEnv<'_>, value: &JString<'_>) -> Result<Option<String>, String> {
    if value.is_null() {
        return Ok(None);
    }
    required_string(env, value).map(Some)
}

fn required_bytes(env: &mut JNIEnv<'_>, value: &JByteArray<'_>) -> Result<Vec<u8>, String> {
    if value.is_null() {
        return Err(MISSING_INPUT.to_string());
    }
    env.convert_byte_array(value)
        .map_err(|_| "invalid binary input".to_string())
}

fn to_jint_handle(handle: u32) -> Result<jint, String> {
    // Defensive: the monotonic counter would have to outlive two billion
    // session creations in one process. Close the fresh session rather than
    // handing Kotlin an unrepresentable handle.
    if handle > i32::MAX as u32 {
        let _ = session_close(handle);
        return Err("too many active sessions".to_string());
    }
    Ok(handle as jint)
}

fn from_jint_handle(handle: jint) -> Result<u32, String> {
    // Handle zero is never allocated (the counter skips it); negatives cannot
    // name a session either. Both map to the engine's unknown-handle error so
    // callers see one uniform rejection.
    if handle <= 0 {
        return Err("session is closed or unknown".to_string());
    }
    Ok(handle as u32)
}

fn new_result_map<'local>(env: &mut JNIEnv<'local>) -> Result<JObject<'local>, String> {
    env.new_object("java/util/HashMap", "()V", &[])
        .map_err(|_| ENCODING_FAILED.to_string())
}

fn put_entry<'local, 'borrow>(
    env: &mut JNIEnv<'local>,
    map: &JObject<'local>,
    key: &str,
    value: JValue<'local, 'borrow>,
) -> Result<(), String> {
    let jkey = JObject::from(
        env.new_string(key)
            .map_err(|_| ENCODING_FAILED.to_string())?,
    );
    env.call_method(
        map,
        "put",
        "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
        &[(&jkey).into(), value],
    )
    .map_err(|_| ENCODING_FAILED.to_string())?;
    Ok(())
}

fn put_string<'local>(
    env: &mut JNIEnv<'local>,
    map: &JObject<'local>,
    key: &str,
    value: Option<&str>,
) -> Result<(), String> {
    match value {
        Some(text) => {
            let jvalue = JObject::from(
                env.new_string(text)
                    .map_err(|_| ENCODING_FAILED.to_string())?,
            );
            put_entry(env, map, key, (&jvalue).into())
        }
        None => put_entry(env, map, key, (&JObject::null()).into()),
    }
}

fn put_bool<'local>(
    env: &mut JNIEnv<'local>,
    map: &JObject<'local>,
    key: &str,
    value: bool,
) -> Result<(), String> {
    // `HashMap.put(Object, Object)` needs a boxed Boolean; a raw JNI boolean
    // would not match the Object parameter signature.
    let boxed = env
        .new_object(
            "java/lang/Boolean",
            "(Z)V",
            &[JValue::Bool(if value { JNI_TRUE } else { JNI_FALSE })],
        )
        .map_err(|_| ENCODING_FAILED.to_string())?;
    put_entry(env, map, key, (&boxed).into())
}

fn put_int<'local>(
    env: &mut JNIEnv<'local>,
    map: &JObject<'local>,
    key: &str,
    value: i32,
) -> Result<(), String> {
    let boxed = env
        .new_object("java/lang/Integer", "(I)V", &[JValue::Int(value)])
        .map_err(|_| ENCODING_FAILED.to_string())?;
    put_entry(env, map, key, (&boxed).into())
}

fn put_bytes<'local>(
    env: &mut JNIEnv<'local>,
    map: &JObject<'local>,
    key: &str,
    bytes: &[u8],
) -> Result<(), String> {
    let jvalue = JObject::from(
        env.byte_array_from_slice(bytes)
            .map_err(|_| ENCODING_FAILED.to_string())?,
    );
    put_entry(env, map, key, (&jvalue).into())
}

fn stage_label(stage: SessionStageName) -> &'static str {
    match stage {
        SessionStageName::Handshaking => "handshaking",
        SessionStageName::AwaitingConfirmation => "awaiting_confirmation",
        SessionStageName::Ready => "ready",
        SessionStageName::Failed => "failed",
    }
}

/// Encodes a nested map with the authenticated remote identity. Only fields
/// the Noise handshake authenticated (or public metadata bound to them) cross
/// this boundary; there is never key material beyond the public key.
fn remote_identity_map<'local>(
    env: &mut JNIEnv<'local>,
    identity: &RemoteIdentity,
) -> Result<JObject<'local>, String> {
    let map = new_result_map(env)?;
    put_string(
        env,
        &map,
        "publicKeyHex",
        Some(&identity.static_public_key_hex),
    )?;
    put_string(env, &map, "deviceId", Some(&identity.device_id))?;
    put_string(env, &map, "displayName", Some(&identity.display_name))?;
    put_int(
        env,
        &map,
        "protocolVersion",
        i32::from(identity.protocol_version),
    )?;
    put_int(env, &map, "capabilities", i32::from(identity.capabilities))?;
    Ok(map)
}

/// Encodes one handshake step result:
/// `{outgoing: byte[], finished: bool, confirmationRequired: bool,
///   remoteIdentity: map|null}`.
fn handshake_result_map<'local>(
    env: &mut JNIEnv<'local>,
    output: HandshakeOutput,
) -> Result<JObject<'local>, String> {
    let map = new_result_map(env)?;
    put_bytes(env, &map, "outgoing", &output.outgoing)?;
    put_bool(env, &map, "finished", output.finished)?;
    put_bool(
        env,
        &map,
        "confirmationRequired",
        output.confirmation_required,
    )?;
    match &output.remote_identity {
        Some(identity) => {
            let nested = remote_identity_map(env, identity)?;
            put_entry(env, &map, "remoteIdentity", (&nested).into())?;
        }
        None => put_entry(env, &map, "remoteIdentity", (&JObject::null()).into())?,
    }
    Ok(map)
}

/// Encodes a status snapshot:
/// `{stage: string, remotePublicKeyHex: string|null,
///   remoteIdentityAvailable: bool}`.
fn status_result_map<'local>(
    env: &mut JNIEnv<'local>,
    report: SessionStatusReport,
) -> Result<JObject<'local>, String> {
    let map = new_result_map(env)?;
    put_string(env, &map, "stage", Some(stage_label(report.stage)))?;
    put_string(
        env,
        &map,
        "remotePublicKeyHex",
        report.remote_static_public_key_hex.as_deref(),
    )?;
    put_bool(
        env,
        &map,
        "remoteIdentityAvailable",
        report.remote_identity_available,
    )?;
    Ok(map)
}

// ------------------------------------------------------------ session JNI

/// Creates a session over the installed identity. Never accepts key material:
/// the local static key comes only from the identity installed by the
/// identity lifecycle. Throws a fixed, non-secret message on failure (no
/// installed identity, malformed pin, invalid fields, or capacity reached);
/// no session exists after a throw.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionCreate<'local>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
    initiator: jboolean,
    device_id: JString<'local>,
    display_name: JString<'local>,
    pinned_remote_public_key_hex: JString<'local>,
    expected_remote_device_id: JString<'local>,
) -> jint {
    let outcome = (|| {
        let device_id = required_string(&mut env, &device_id)?;
        let display_name = required_string(&mut env, &display_name)?;
        let pinned = optional_string(&mut env, &pinned_remote_public_key_hex)?;
        let expected = optional_string(&mut env, &expected_remote_device_id)?;
        let handle = session_create(
            initiator == JNI_TRUE,
            &device_id,
            &display_name,
            pinned.as_deref(),
            expected.as_deref(),
        )?;
        to_jint_handle(handle)
    })();
    match outcome {
        Ok(handle) => handle,
        Err(message) => {
            throw(&mut env, &message);
            0
        }
    }
}

/// Produces handshake message 1. Initiator sessions only. Returns the
/// handshake result map; its `remoteIdentity` is always null here because no
/// peer identity can be authenticated before message 2.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionStartHandshake<
    'local,
>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
    handle: jint,
) -> jobject {
    let outcome = (|| {
        let handle = from_jint_handle(handle)?;
        let output = session_start_handshake(handle)?;
        handshake_result_map(&mut env, output)
    })();
    match outcome {
        Ok(map) => map.into_raw(),
        Err(message) => {
            throw(&mut env, &message);
            std::ptr::null_mut()
        }
    }
}

/// Processes one inbound handshake message and returns the next outbound
/// message plus completion state and the authenticated remote identity once
/// its encrypted payload arrived. Throws on oversized, malformed or
/// out-of-order input; those failures poison the session inside the engine.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionProcessHandshake<
    'local,
>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
    handle: jint,
    incoming: JByteArray<'local>,
) -> jobject {
    let outcome = (|| {
        let handle = from_jint_handle(handle)?;
        let incoming = required_bytes(&mut env, &incoming)?;
        let output = session_process_handshake(handle, &incoming)?;
        handshake_result_map(&mut env, output)
    })();
    match outcome {
        Ok(map) => map.into_raw(),
        Err(message) => {
            throw(&mut env, &message);
            std::ptr::null_mut()
        }
    }
}

/// Returns the non-secret status snapshot for a live session. The full
/// authenticated identity is delivered exactly once, by the handshake call
/// that authenticates it; this snapshot only reports stage and availability.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionStatus<'local>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
    handle: jint,
) -> jobject {
    let outcome = (|| {
        let handle = from_jint_handle(handle)?;
        let report = session_status(handle)?;
        status_result_map(&mut env, report)
    })();
    match outcome {
        Ok(map) => map.into_raw(),
        Err(message) => {
            throw(&mut env, &message);
            std::ptr::null_mut()
        }
    }
}

/// Explicitly confirms the authenticated remote identity, unlocking transport
/// operations. The calling application layer must have reviewed the remote
/// identity first; this function never marks a peer `verified`.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionConfirmPeerIdentity<
    'local,
>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
    handle: jint,
) {
    let outcome = (|| {
        let handle = from_jint_handle(handle)?;
        session_confirm_peer_identity(handle)
    })();
    if let Err(message) = outcome {
        throw(&mut env, &message);
    }
}

/// Encrypts one plaintext payload with a confirmed session. Refused before
/// confirmation and on oversized plaintext; a write failure poisons the
/// session inside the engine.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionEncrypt<'local>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
    handle: jint,
    plaintext: JByteArray<'local>,
) -> jbyteArray {
    let outcome = (|| {
        let handle = from_jint_handle(handle)?;
        let plaintext = required_bytes(&mut env, &plaintext)?;
        session_encrypt(handle, &plaintext)
    })();
    match outcome {
        Ok(ciphertext) => match env.byte_array_from_slice(&ciphertext) {
            Ok(value) => value.into_raw(),
            Err(_) => {
                throw(&mut env, ENCODING_FAILED);
                std::ptr::null_mut()
            }
        },
        Err(message) => {
            throw(&mut env, &message);
            std::ptr::null_mut()
        }
    }
}

/// Decrypts one authenticated transport payload with a confirmed session.
/// Any authentication failure poisons the session in Rust — the caller must
/// close it and reconnect; there is no plaintext fallback.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionDecrypt<'local>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
    handle: jint,
    ciphertext: JByteArray<'local>,
) -> jbyteArray {
    let outcome = (|| {
        let handle = from_jint_handle(handle)?;
        let ciphertext = required_bytes(&mut env, &ciphertext)?;
        session_decrypt(handle, &ciphertext)
    })();
    match outcome {
        Ok(plaintext) => match env.byte_array_from_slice(&plaintext) {
            Ok(value) => value.into_raw(),
            Err(_) => {
                throw(&mut env, ENCODING_FAILED);
                std::ptr::null_mut()
            }
        },
        Err(message) => {
            throw(&mut env, &message);
            std::ptr::null_mut()
        }
    }
}

/// Closes a session, dropping its Noise state. Idempotent and never throws:
/// unknown, closed and non-positive handles simply report `false`.
#[no_mangle]
pub extern "system" fn Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionClose<'local>(
    _env: JNIEnv<'local>,
    _this: JObject<'local>,
    handle: jint,
) -> jboolean {
    match from_jint_handle(handle) {
        Ok(handle) => {
            if session_close(handle) {
                JNI_TRUE
            } else {
                JNI_FALSE
            }
        }
        Err(_) => JNI_FALSE,
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
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeSessionCreate"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionCreate",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeSessionStartHandshake"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionStartHandshake",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeSessionProcessHandshake"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionProcessHandshake",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeSessionStatus"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionStatus",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeSessionConfirmPeerIdentity"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionConfirmPeerIdentity",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeSessionEncrypt"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionEncrypt",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeSessionDecrypt"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionDecrypt",
            ),
            (
                concat!(
                    "Java_com_bechat_bechat_",
                    "NativeCryptoBridge_",
                    "nativeSessionClose"
                ),
                "Java_com_bechat_bechat_NativeCryptoBridge_nativeSessionClose",
            ),
        ];
        for (built, expected) in symbols {
            assert_eq!(built, expected);
        }
    }
}
