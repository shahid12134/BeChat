# BeChat crypto spike

This is an isolated feasibility spike for Stage 6. It proves that Rust `snow` Noise XX/IK and `flutter_rust_bridge` can be built, tested, and called from an Android Flutter app on the existing BeChat toolchain.

It does not provide production E2EE. It is not connected to BeChat messaging, BLE, identity storage, or the BeChat database.

## Scope

- Two fresh peers performing `Noise_XX_25519_ChaChaPoly_SHA256`.
- Two pinned peers performing `Noise_IK_25519_ChaChaPoly_SHA256`.
- Two-way transport encryption/decryption.
- Tampered ciphertext rejection.
- Malformed/truncated handshake rejection.
- Fresh ephemeral material for independent sessions.
- Closed-handle and failed-session rejection.
- Android secure-storage write/read/delete probe using a test value only.
- No real private key is stored, logged, or exported to Dart.

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
| `flutter_secure_storage` | 10.3.4 |

FRB 2.13.0 requires Dart `>=3.9.2 <4.0.0`; the installed Dart 3.9.2 satisfies it.

`flutter_secure_storage` 11.2.0 was not usable with this Dart version: its Windows plugin resolves `win32 ^6.0.1`, which requires Dart `>=3.10.0`. The spike uses 10.3.4, which resolves `flutter_secure_storage_windows 4.1.0` and `win32 5.15.0`. The Flutter/Dart toolchain was not upgraded.

## Prerequisites

- Flutter 3.35.4 and Dart 3.9.2 on `PATH`.
- Android SDK 36 and NDK `27.1.12297006`.
- Rust 1.99.1 with `rustup`.
- Visual Studio 2022 Build Tools with the MSVC C++ workload and a Windows SDK on Windows.
- FRB code generator 2.13.0.

Install the pinned code generator and Android Rust targets:

```powershell
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
```

`cargo-ndk` is optional for diagnostics; Cargokit builds the example directly with the Android NDK.

On Windows, run Gradle/Cargo commands from an MSVC environment. The simplest option is to open **Developer PowerShell for VS 2022**, ensure Cargo is on `PATH`, and build from there. If invoking from a normal shell, resolve the Visual Studio installation with `vswhere` and call its `VsDevCmd.bat`; do not commit the resolved path.

## Build and run

From the repository root:

```powershell
cd tooling/crypto_spike
flutter pub get
flutter_rust_bridge_codegen generate
flutter build apk --debug
```

The generated debug APK is at `build/app/outputs/flutter-apk/app-debug.apk` and is ignored by git.

Android runtime test on a connected device or emulator:

```powershell
flutter test integration_test -d <device-id>
```

The app UI has a **Run self-test** button that runs the same Noise checks and the secure-storage probe.

## Validation performed

| Check | Command | Result |
| --- | --- | --- |
| Rust formatting | `cargo fmt --all -- --check` | Passed |
| Rust lint | `cargo clippy --all-targets -- -D warnings` | Passed |
| Rust tests | `cargo test` | 6 passed |
| Spike analyze | `flutter analyze` | No issues |
| Spike Android runtime | `flutter test integration_test -d emulator-5554` | 3 passed |
| BeChat analyze | `flutter analyze` from repo root | No issues |
| BeChat tests | `flutter test` from repo root | 175 passed |
| BeChat debug APK | `flutter build apk --debug` from repo root | Built |

Android runtime smoke was performed on emulator `Medium_Phone_API_36.0`:

- ABI: `x86_64` (`sdk_gphone64_x86_64`)
- Android: 16 / API 36
- Result: FRB loaded the native library, both Noise suites completed in memory, tamper and closed-handle checks passed, and the secure-storage probe passed.

No physical Android device was connected, so physical-device and BLE/GATT validation remain pending.

Cargokit compiled the Rust library for armv7, arm64, x86_64, and i686 during the build. The debug APK contained `arm64-v8a`, `armeabi-v7a`, and `x86_64` native libraries.

## Secure storage

See [SECURITY_REVIEW.md](SECURITY_REVIEW.md) for the detailed findings.

Short version: `flutter_secure_storage` protects data at rest with Android Keystore-backed RSA-OAEP key wrapping and AES-GCM, but `read` returns the plaintext string to Dart. It cannot keep the Noise static private key out of Dart memory by itself. The spike uses a fixed non-secret test value and deletes it after the probe.

The sample manifest sets `android:allowBackup="false"`. Production BeChat currently does not explicitly set that attribute, so backup/key-restore behavior must be addressed before adding persistent identity keys.

## Known limitations

- Not production E2EE.
- No BLE integration, wire-format change, database migration, peer repository, identity manager, rotation, or message persistence.
- No multi-hop routing.
- No local database encryption.
- No formal security audit of Snow, FRB, Cargokit, or `flutter_secure_storage`.
- Snow's internal handshake/transport state is not proven to be zeroized; only the local static private-key buffer is wrapped in `Zeroizing`.
- Noise authenticates keys but does not establish application trust. The app must verify pinned remote keys and display safety-number/OOB verification.
- The secure-storage plugin does not satisfy an opaque-key/native-keystore isolation requirement.
- Android runtime success was on an emulator, not a physical phone.
- The test harness uses only one file/transport path; production framing, session lifetime limits, rekeying, and BLE fragmentation are not covered.
