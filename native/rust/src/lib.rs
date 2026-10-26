//! Production BeChat native crypto backend.
//!
//! Phase 1A exposes only a non-secret JNI smoke test that proves the packaged
//! `libbechat_crypto.so` loads inside the production Android app and can
//! execute Rust code. Identity provisioning and secret-bearing entry points
//! are added in a later phase.

mod native_jni;
