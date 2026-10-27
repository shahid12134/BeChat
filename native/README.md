# Production Rust crypto backend (Stage 6, Phase 1A + 1B)

This directory integrates the production BeChat Rust crypto backend into the
Android application.

* **Phase 1A** — build integration and a non-secret native smoke test.
* **Phase 1B** — persistent Noise X25519 identity: Rust key generation and
  validation, Android Keystore AES-256-GCM wrapping, atomic no-backup blob
  persistence, strict envelope validation, fail-closed recovery and a
  non-secret Dart-facing status API.

**Production BLE messaging is still unencrypted.** Provisioning a Noise
identity does not encrypt anything: there is no handshake, no message or ACK
encryption, no database encryption and no multi-hop routing. SQLite integration
of the public identity, peer trust state and application bootstrap wiring are
deliberately **not** part of this phase.

## Layout

| Path | Crate / package | Purpose |
| --- | --- | --- |
| `crypto_core/` | `bechat_crypto_core` | Shared cryptographic core: Noise suite constants, Snow handshake tests and the persistent identity module (`src/identity.rs`). |
| `rust/` | `bechat_crypto` | Production `cdylib` packaged as `libbechat_crypto.so`; JNI exports in `src/native_jni.rs`. |
| `rust_builder/` | `bechat_crypto` (Flutter plugin) | Cargokit Gradle wiring that compiles `rust/` for the app's Android ABIs during the normal Gradle build. |

The feasibility spike under `tooling/crypto_spike/` is untouched and remains
the frozen, validated reference (its own `BCSI` envelope and debug hook set are
not reused). All new production logic lives in `crypto_core`, so only one
implementation evolves.

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

## Identity architecture (Option B)

Rust owns the Noise static private seed; Kotlin owns Android Keystore wrapping
and encrypted-blob persistence; a narrow JNI surface is the only path private
seed bytes travel.

```
Dart  NativeIdentityService        (public status only)
  |   MethodChannel bechat/native_identity
Kotlin NativeIdentityController    (state machine, provisioning, recovery, reset)
  |   IdentityBlobStore            (Keystore AES-256-GCM, atomic no-backup files)
  |   NativeCryptoBridge           (JNI declarations)
JNI   Java_com_bechat_bechat_NativeCryptoBridge_*
Rust  bechat_crypto_core::identity (generate, derive, validate, install, clear)
```

### Native operations (JNI)

| Kotlin (`NativeCryptoBridge`) | Rust behavior |
| --- | --- |
| `nativeBackendVersion()` | Fixed non-secret backend identifier. |
| `nativeGenerateSeed()` | Snow X25519 static seed (32 bytes) for `Noise_XX_25519_ChaChaPoly_SHA256`. |
| `nativePublicKeyForSeed(seed)` | Lowercase-hex public key; rejects any length but 32. |
| `nativeInstallSeed(seed, expectedHex)` | Derives, compares and installs; returns `false` without touching the installed identity on mismatch. |
| `nativeClearInstalledIdentity()` | Drops the installed identity (zeroizing storage). |
| `nativeInstalledPublicKeyHex()` | Installed public key only — **no seed accessor exists**. |

Private seed bytes cross JNI only as arguments/results between Kotlin and Rust.
They never enter Dart, Flutter Rust Bridge, MethodChannel results, logs or
exceptions.

### Keystore and storage

* Alias: `bechat_identity_wrap_v1` (AES-256-GCM, 256-bit, randomized
  encryption required, non-exportable).
* Directory: `<noBackupFilesDir>/bechat_identity/`.
* Files: `identity.blob` (encrypted envelope), `identity.meta` (non-secret
  metadata). Both are written to a temporary file, flushed (`fd.sync()`), then
  renamed into place.
* The metadata document is strictly validated:

  ```
  bechat-identity-meta/1
  public_key=<64 lowercase hex>
  algorithm=noise-x25519-chachapoly-sha256
  created_at=<UTC ISO-8601>
  ```

  Anything else (unknown header version, uppercase/short key, unknown algorithm,
  malformed timestamp, extra/missing lines) is rejected. A later phase can move
  this document into SQLite without touching the cryptographic core: only
  `IdentityBlobStore` knows where it lives.

### Envelope format (`BCID`, version 1)

| Offset | Length | Field |
| --- | --- | --- |
| 0 | 4 | magic `0x42 0x43 0x49 0x44` (`BCID`) |
| 4 | 1 | envelope version (`1`) |
| 5 | 1 | algorithm id (`1` = AES-256-GCM, 128-bit tag) |
| 6 | 1 | IV length (`12`) |
| 7 | 1 | seed length (`32`) |
| 8 | 12 | IV/nonce (Keystore randomized encryption; never reused per wrap) |
| 20 | 48 | ciphertext (32-byte seed) followed by the 16-byte GCM tag |

Total length is exactly 68 bytes. AAD is the 8-byte header followed by the 64
ASCII characters of the lowercase-hex public key, so the expected public
identity, algorithm and version are authenticated; after decryption the derived
public key is verified against the metadata again before installation.

This is a production-specific format. The spike's `BCSI`/version-1 envelope has
a different layout and is not reinterpreted: an unknown magic is corrupt, and
an unknown version or algorithm is reported as unsupported.

Rejected: wrong magic, malformed/truncated/oversized blobs, invalid declared
IV or seed length, unsupported version, unsupported algorithm, failed GCM
authentication, invalid decrypted seed length.

### Lifecycle and failure states

States reported to Dart (`NativeIdentityService.state`):

| State | Meaning |
| --- | --- |
| `uninitialized` | No identity exists on this installation. |
| `ready` | Identity installed; public key and fingerprint available. |
| `blob_missing` | Metadata exists but the encrypted envelope is gone. |
| `blob_corrupt` | Malformed envelope or failed authenticated decryption. |
| `blob_unsupported` | Unsupported envelope version or algorithm. |
| `key_unavailable` | Keystore wrapping key missing or invalidated. |
| `metadata_invalid` | Metadata malformed, or an orphan envelope without metadata. |
| `mismatch` | Recovered seed does not match the expected public key. |
| `native_error` | Native identity backend failed. |
| `store_failed` | Identity could not be persisted or read. |

* **First installation** — `initialize` provisions only when neither metadata
  nor envelope exists: Rust generates the seed, Kotlin installs it natively,
  wraps and persists the envelope, then writes the metadata. Failures roll the
  partial state back and clear the native identity.
* **Restart** — `initialize` restores the same identity; it never rotates.
  Concurrent callers are serialized and inherit the same identity.
* **Interrupted provisioning** — if the process dies between envelope and
  metadata, the orphan envelope is reported as `metadata_invalid` and left
  untouched; automatic recovery never regenerates a key, and only an explicit
  reset clears it.
* **Identity loss** — missing, corrupt, unsupported or mismatched material
  produces the matching state above and installs nothing.
* **Reset** — `reset(confirm: true)` only: clears the native identity, deletes
  the envelope, the metadata and the Keystore alias. The device UUID, peers,
  chats, messages and block state are untouched because no database code runs
  in this phase. `reset(confirm: false)` is refused before any platform traffic.

Nothing provisions an identity at application startup: `MainActivity` only
attaches the store, so provisioning happens when application code calls
`initialize`.

### Backup, reinstall and key loss

* The envelope lives in `noBackupFilesDir`, so Android Auto Backup and
  device-transfer do not carry it. Chat history backup policy is untouched.
* Even if the envelope were copied, it is useless without the Keystore wrapping
  key, which is non-exportable and device-bound.
* Reinstall or device migration therefore loses the identity and requires a new
  provisioning or an explicit reset; user data in SQLite is unaffected.

### Memory and isolation limitations

* Rust zeroizes the seed buffers it owns (`zeroize`), and Kotlin clears the
  arrays it holds before returning.
* Kotlin/JVM, crypto-provider and native allocator copies cannot all be
  guaranteed erased; this is not claimed.
* Option B protects the seed at rest. It does **not** guarantee hardware-backed
  key isolation (the wrapping key may be software-backed depending on device)
  and does not defend against a fully compromised application process,
  rooted devices, or memory inspection at runtime.
* Physical-device validation (hardware-backed Keystore behaviour, Keystore
  invalidation, locked-device behaviour) is still outstanding; results so far
  come from emulators.

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

# On-device identity tests (emulator or device attached)
flutter test integration_test/native_identity_lifecycle_test.dart -d <device-id>
cd android && ./gradlew :app:connectedDebugAndroidTest
```

Runtime expectations: `NativeCryptoBackend().backendVersion()` returns
`bechat-crypto-core/0.1.0 snow/0.10.0`, and
`NativeIdentityService().initialize()` reaches `ready` with a 64-character
hex public key and fingerprint.

## Scope boundaries

* No SQLite schema changes, no `IdentityRepository`/`PeerRepository` changes,
  no bootstrap provisioning, no BLE protocol or message changes.
* No private-key bytes through Dart, MethodChannel, logs or exceptions.
* Android-only: unsupported platforms report the backend as unavailable.
