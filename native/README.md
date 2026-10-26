# Production Rust crypto backend (Stage 6, Phase 1A)

This directory integrates the production BeChat Rust crypto backend into the
Android application. Phase 1A covers **build integration and a non-secret
native smoke test only** — there is no identity provisioning, no Keystore blob
store and no encrypted BLE messaging yet.

## Layout

| Path | Crate / package | Purpose |
| --- | --- | --- |
| `crypto_core/` | `bechat_crypto_core` | Shared cryptographic core: Noise suite constants and Snow unit tests. Later phases move the canonical identity logic here. |
| `rust/` | `bechat_crypto` | Production `cdylib` packaged as `libbechat_crypto.so`. Phase 1A exposes one JNI function: a fixed backend version string. |
| `rust_builder/` | `bechat_crypto` (Flutter plugin) | Cargokit Gradle wiring that compiles `rust/` for the app's Android ABIs during the normal Gradle build. |

The feasibility spike under `tooling/crypto_spike/` is untouched and remains
the frozen, validated reference. To avoid two independently evolving copies,
`crypto_core` is the single home for production cryptographic logic; the
spike's identity functions are consolidated there in a later phase.

## How the build works

1. `pubspec.yaml` depends on `bechat_crypto: path: native/rust_builder`.
2. The plugin's `android/build.gradle` applies `cargokit/gradle/plugin.gradle`
   with `manifestDir = "../../rust"` and `libname = "bechat_crypto"`.
3. Before `merge<BuildType>NativeLibs`, cargokit runs
   `cargokit/run_build_tool.cmd build-gradle`, which invokes `cargo build` for
   the requested Android ABIs and writes the `.so` files into the plugin's
   `jniLibs/<buildType>` directory.
4. Gradle packages them into the APK; Kotlin loads the library with
   `System.loadLibrary("bechat_crypto")`
   (`android/app/src/main/kotlin/com/bechat/bechat/NativeCryptoBridge.kt`).

## Smoke test path

Dart `NativeCryptoBackend.backendVersion()` → MethodChannel
`bechat/native_crypto` → `MainActivity` handler →
`NativeCryptoBridge.nativeBackendVersion()` (Kotlin `external`) → JNI
`Java_com_bechat_bechat_NativeCryptoBridge_nativeBackendVersion` → returns
`bechat_crypto_core::backend_version()`, a fixed non-secret string.

No function on this path accepts or returns private-key material.

## Commands

From the repository root:

```bash
# Rust: format, tests, clippy (repeat for native/rust)
cargo fmt   --manifest-path native/crypto_core/Cargo.toml -- --check
cargo test  --manifest-path native/crypto_core/Cargo.toml
cargo clippy --manifest-path native/crypto_core/Cargo.toml --all-targets -- -D warnings

cargo fmt   --manifest-path native/rust/Cargo.toml -- --check
cargo test  --manifest-path native/rust/Cargo.toml
cargo clippy --manifest-path native/rust/Cargo.toml --all-targets -- -D warnings

# Flutter
flutter pub get
flutter analyze
flutter test

# Android debug APK (requires Android SDK, NDK 27.1.12297006 and cargo)
flutter build apk --debug
```

Runtime smoke test on an emulator or device: install the debug APK, launch the
app, and call `NativeCryptoBackend().backendVersion()`; it must return
`bechat-crypto-core/0.1.0 snow/0.10.0`.

## Scope boundaries

- No database schema changes, no identity provisioning, no BLE changes.
- No private-key bytes through Dart, MethodChannel, logs or exceptions.
- Android-only: unsupported platforms report the backend as unavailable.
