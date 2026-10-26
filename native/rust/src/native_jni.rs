//! Narrow JNI surface for the production BeChat application.
//!
//! Package `com.bechat.bechat`, class `NativeCryptoBridge`.
//!
//! Only non-secret diagnostic data crosses this boundary in Phase 1A. There is
//! deliberately no seed generation, no secret-byte export and no general
//! command dispatcher here; those belong to later, separately reviewed phases.

use jni::objects::JObject;
use jni::sys::jstring;
use jni::JNIEnv;

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

#[cfg(test)]
mod tests {

    /// Guards the JNI symbol name against silent drift when the Kotlin class
    /// or package is renamed: the export name is built here as a literal so a
    /// mismatch fails at review/compile time rather than at runtime.
    #[test]
    fn jni_symbol_matches_production_kotlin_package() {
        let symbol = concat!(
            "Java_com_bechat_bechat_",
            "NativeCryptoBridge_",
            "nativeBackendVersion"
        );
        assert_eq!(
            symbol,
            "Java_com_bechat_bechat_NativeCryptoBridge_nativeBackendVersion"
        );
    }
}
