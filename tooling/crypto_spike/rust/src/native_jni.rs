use jni::objects::{JByteArray, JObject, JString};
use jni::sys::{jboolean, jbyteArray, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;

use crate::api::noise;

fn throw(env: &mut JNIEnv<'_>, message: &str) {
    let _ = env.throw_new("java/lang/IllegalStateException", message);
}

#[no_mangle]
pub extern "system" fn Java_com_bechat_spike_crypto_1spike_NativeIdentityBridge_nativeGenerateSeed<
    'local,
>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> jbyteArray {
    match noise::generate_identity_seed() {
        Ok(mut seed) => {
            let result = env.byte_array_from_slice(&seed);
            seed.fill(0);
            match result {
                Ok(array) => array.into_raw(),
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

#[no_mangle]
pub extern "system" fn Java_com_bechat_spike_crypto_1spike_NativeIdentityBridge_nativePublicKeyForSeed<
    'local,
>(
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

    let result = if seed_bytes.len() == 32 {
        noise::derive_identity_public_key(&seed_bytes)
    } else {
        Err("invalid identity seed length".into())
    };
    seed_bytes.fill(0);

    match result {
        Ok(public_key) => match env.new_string(hex::encode(public_key)) {
            Ok(value) => value.into_raw(),
            Err(_) => {
                throw(&mut env, "identity public key unavailable");
                std::ptr::null_mut()
            }
        },
        Err(message) => {
            throw(&mut env, &message);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_com_bechat_spike_crypto_1spike_NativeIdentityBridge_nativeInstallSeed<
    'local,
>(
    mut env: JNIEnv<'local>,
    _this: JObject<'local>,
    seed: JByteArray<'local>,
    expected_public_key_hex: JString<'local>,
) -> jboolean {
    let mut seed_bytes = match env.convert_byte_array(seed) {
        Ok(bytes) => bytes,
        Err(_) => return JNI_FALSE,
    };
    let expected_public_key: String = match env.get_string(&expected_public_key_hex) {
        Ok(value) => value.into(),
        Err(_) => {
            seed_bytes.fill(0);
            return JNI_FALSE;
        }
    };

    let installed = noise::install_identity(&seed_bytes, &expected_public_key).is_ok();
    seed_bytes.fill(0);
    if installed {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

#[no_mangle]
pub extern "system" fn Java_com_bechat_spike_crypto_1spike_NativeIdentityBridge_nativeClearInstalledIdentity<
    'local,
>(
    _env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> jboolean {
    noise::clear_installed_identity();
    JNI_TRUE
}

#[no_mangle]
pub extern "system" fn Java_com_bechat_spike_crypto_1spike_NativeIdentityBridge_nativeInstalledPublicKeyHex<
    'local,
>(
    env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> jstring {
    match noise::installed_public_key_hex() {
        Ok(Some(public_key_hex)) => match env.new_string(public_key_hex) {
            Ok(value) => value.into_raw(),
            Err(_) => std::ptr::null_mut(),
        },
        _ => std::ptr::null_mut(),
    }
}
