# BeChat crypto spike

This is an isolated feasibility spike for Stage 6. It proves that Rust `snow` Noise XX/IK, `flutter_rust_bridge`, Android Keystore, and a Kotlin/JNI boundary can be built and exercised on the existing BeChat toolchain.

It is not production E2EE. It is not connected to BeChat messaging, BLE, identity storage, the BeChat database, or the production Android configuration.

## What this phase validates

- A persistent X25519 static identity can be generated in Rust.
- The identity can be wrapped by a non-exportable Android Keystore AES-256-GCM key.
- The encrypted blob is stored in `noBackupFilesDir`, not ordinary app storage.
- Restore is fail-closed for missing, corrupt, undecryptable, or mismatched state.
- Reset is explicit and destroys the encrypted blob, metadata, and Keystore alias.
- The installed identity works with `Noise_XX_25519_ChaChaPoly_SHA256` and `Noise_IK_25519_ChaChaPoly_SHA256`.
- Dart receives only the public key, fingerprint, and status. It never receives the private seed.
- The identity survives a real process force-stop and relaunch.

The existing `flutter_secure_storage` probe remains as a comparison. It demonstrates why that plugin is not used for the Noise private key: its API returns plaintext values to Dart.

## Architecture

```text
Rust / snow
  generate X25519 seed
  derive public key
  install seed into native installed-identity slot
        |
        | JNI only
        v
Kotlin NativeIdentityBridge
        |
        +-- Android Keystore alias: bechat_spike_identity_wrap_v1
        |     AES-256-GCM, non-exportable wrapping key
        |
        +-- noBackupFilesDir/identity/identity_v1.bin
        +-- SharedPreferences: bechat_spike_identity_metadata
        |
        | MethodChannel: bechat.spike/native_identity
        v
Dart NativeIdentityService
  public key, fingerprint, state, generic error messages only
```

### Native API

The Kotlin/JNI surface is:

- `nativeGenerateSeed()`
- `nativePublicKeyForSeed(seed)`
- `nativeInstallSeed(seed, expectedPublicKeyHex)`
- `nativeClearInstalledIdentity()`
- `nativeInstalledPublicKeyHex()`

No private seed is passed through FRB, Dart, MethodChannel, UI state, preferences, or logs.

### Installed Rust API

The FRB-visible Rust API now includes:

- `installedPublicIdentity()`
- `createInstalledSession(pattern, initiator, expectedRemotePublicKeyHex)`

Sessions created from the installed identity use the same Snow XX/IK implementation and expected-remote-key checks as the in-memory test peers.

## Encrypted blob format

Path: `noBackupFilesDir/identity/identity_v1.bin`

```text
"BCSI"            4 bytes   magic
version           1 byte    0x01
IV length         1 byte    0x0c
IV                12 bytes
AES-GCM ciphertext 48 bytes 32-byte seed + 16-byte tag
```

Total: 66 bytes. The 5-byte header is also used as AES-GCM AAD. The public key and metadata version are stored separately in the sample app's `SharedPreferences`.

Persistence is written to a temporary file, synced, then renamed. Metadata is committed only after the blob write. A crash between those steps leaves a state that fails closed rather than silently provisioning a replacement identity.

## Identity states

| State | Meaning |
| --- | --- |
| `uninitialized` | No public metadata and no ciphertext. |
| `ready` | Blob unwrapped, installed, and matches metadata. |
| `identity_lost` | Metadata and blob are inconsistent, or the blob is missing. |
| `corrupt` | Invalid blob, unsupported format, failed GCM authentication, or malformed metadata. |
| `key_unavailable` | Keystore alias is missing or the wrapping key cannot be retrieved. |
| `mismatch` | The recovered seed does not match the stored public key. |
| `native_error` | Unexpected JNI/native failure. |

Missing or invalid state never triggers automatic replacement. Provisioning is refused while any metadata or ciphertext exists; the user must explicitly reset first.

## Pinned versions

| Component | Version |
| --- | --- |
| Flutter | 3.35.4 |
| Dart | 3.9.2 |
| Android SDK | 36 |
| Android NDK | 27.1.12297006 |
| AGP | 8.9.1 |
| Gradle wrapper | 8.12 |
| Rust | 1.99.1 |
| `flutter_rust_bridge` | 2.13.0 |
| `snow` | 0.10.0 |
| `sha2` | 0.11.1 |
| `zeroize` | 1.9.1 |
| `jni` | 0.21.1 |
| `flutter_secure_storage` | 10.3.4 |

The Flutter/Dart/Java/Gradle/NDK toolchain was not upgraded.

## Prerequisites

- Flutter 3.35.4 and Dart 3.9.2 on `PATH`.
- Android SDK 36 and NDK `27.1.12297006`.
- Rust 1.99.1 with `rustup`.
- Visual Studio 2022 Build Tools with the MSVC C++ workload and a Windows SDK on Windows.
- FRB code generator 2.13.0.
- Android Rust targets: `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android`, `i686-linux-android`.

On Windows, run Gradle/Cargo commands from an MSVC environment. Cargo is not necessarily on the default `PATH`; prepend `%USERPROFILE%\.cargo\bin` after calling `VsDevCmd.bat`.

## Build and test

From the repository root:

```powershell
cd tooling/crypto_spike
flutter pub get
flutter_rust_bridge_codegen generate
flutter analyze
flutter build apk --debug
```

Rust checks:

```powershell
cd tooling/crypto_spike/rust
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```

Android runtime tests, run separately on each emulator:

```powershell
flutter test integration_test -d emulator-5554
```

The generated debug APK is at `build/app/outputs/flutter-apk/app-debug.apk`.

## Validation performed

| Check | Result |
| --- | --- |
| Rust formatting | Passed |
| Rust lint, all targets, warnings denied | Passed |
| Rust unit tests | 7 passed |
| Spike `flutter analyze` | No issues |
| API 30 `Pixel_3a` integration suite | 5 passed |
| API 36 `Medium_Phone_API_36.0` integration suite | 5 passed |
| API 30 force-stop and relaunch | Same public identity restored; `ready` |
| API 36 force-stop and relaunch | Same public identity restored; `ready` |
| Corrupt ciphertext | `corrupt`; restore remains `corrupt` |
| Missing ciphertext with metadata | `identity_lost`; restore remains `identity_lost` |
| Missing Keystore alias with ciphertext | `key_unavailable`; restore remains `key_unavailable` |
| Public metadata/mismatch probe | Rejected; installed identity unchanged |
| Reset then re-provision | New public identity; old state not reused |
| Android backup | `Backup is not allowed`; package flags do not include `ALLOW_BACKUP` |
| Encrypted file location | `no_backup/identity/identity_v1.bin`, mode `0600`, 66 bytes |
| Plaintext in `files/` | No identity material found |

The Android integration suite includes the lifecycle test (`native_identity_lifecycle_test.dart`), the existing Noise bridge tests, and the secure-storage comparison probe.

### Restart evidence

On both emulators, the identity was provisioned, the process was force-stopped (`pidof` returned nothing), the activity was relaunched, and the UI reported `ready` with the same public key and fingerprint.

On the API 30 emulator, the default Impeller renderer failed to link a GLES shader and left the UI on the launch screen. The force-stop/relaunch identity check there used a temporary Impeller-disabled build; that override was not retained. The identity implementation was unchanged. The API 36 restart check used the final build.

The API 30 and API 36 checks are emulator results. No physical Android device was connected, so physical Keystore/TEE, backup transport, memory, timing, and BLE behavior remain unverified.

## Security boundaries and limitations

- Android Keystore protects the wrapping key from extraction, but this design does not make the Noise private key opaque to native code. Kotlin must briefly hold the seed to wrap/unwrap it and pass it to Rust through JNI.
- The seed is zeroized in Kotlin `ByteArray`s, JNI copies, and Rust `Zeroizing` storage where practical. JVM garbage collection, provider internals, or native allocator copies may retain remnants. Zeroization is best-effort, not a formal guarantee.
- Snow's internal handshake and transport state is not proven to be zeroized.
- The sample does not require user authentication or unlocked-device binding for the Keystore key.
- Hardware-backed Keystore/TEE/StrongBox behavior was not verified; the emulator may use software-backed keys.
- Backup is disabled in the sample and the blob is in `noBackupFilesDir`. A production backup/key-restore policy still has to be designed before adopting this design.
- A missing or invalidated Keystore key is unrecoverable by design. The product needs an explicit identity-loss/re-enrollment UX.
- The public key in `SharedPreferences` is not secret, but it is not independently authenticated by the blob. The recovered seed is re-derived and compared against it, so tampering fails closed with `mismatch`. The metadata version is stored but not yet validated on restore.
- `BM`/`BP` race and multi-process access were not tested. The sample assumes one app process and uses synchronized controller methods.
- No physical-device, BLE, database, crash-reporter, rooted-device, rollback, or side-channel testing was performed.
- Not production E2EE. Noise authenticates keys but does not establish application trust; pinning, safety-number verification, rotation, and authorization remain application responsibilities.

## Production follow-up

Before production integration:

1. Move the controller/blob store into a reviewed production identity component, not the spike.
2. Decide whether Kotlin/JVM seed copies are acceptable or whether Rust must perform Keystore wrapping directly through NDK/Keystore APIs.
3. Add explicit identity-loss, key-invalidation, reinstall, and reset UX.
4. Define backup policy and test Android Auto Backup/device-transfer behavior.
5. Test on physical Android 11 and Android 16 devices, including Keystore invalidation and locked-device behavior.
6. Add session rekeying, lifetime/resource limits, BLE framing limits, and remote-key pin-change policy.
7. Perform a formal review of Snow, Snow's zeroization, the JNI surface, and the Rust/Android attack surface.

## See also

- [SECURITY_REVIEW.md](SECURITY_REVIEW.md)
