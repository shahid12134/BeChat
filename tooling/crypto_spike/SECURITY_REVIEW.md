# Stage 6 Phase 0.6 security and architecture review

## Scope

This review covers only the isolated spike in `tooling/crypto_spike`. It does not describe BeChat production behavior and does not establish that BeChat has E2EE.

## Decision being tested

Option B was selected for the proof of concept:

- Rust generates and uses the Noise X25519 static identity.
- Android Keystore wraps the 32-byte seed with a non-exportable AES-256-GCM key.
- The encrypted blob is stored in `noBackupFilesDir`.
- A Kotlin/JNI boundary installs the seed into Rust without sending it through Dart.
- Dart receives only public identity and status data.

The primary requirement is that BeChat's long-term Noise private key is not exposed to Dart or FRB. The secondary requirement is fail-closed persistence: a missing, corrupt, undecryptable, or mismatched identity must never be silently replaced.

## Boundary

```text
Dart
  MethodChannel "bechat.spike/native_identity"
  methods: status, provision, restore, reset, test hooks
  data: public key, fingerprint, state, generic error
        |
        v
Kotlin
  NativeIdentityController
  IdentityBlobStore
  NativeIdentityBridge (JNI)
        |
        v
Rust
  installed PeerIdentity (Zeroizing private seed)
  Snow XX/IK handshake and transport
```

No FRB method accepts or returns a private seed. The JNI methods are the only path for private seed material.

### JNI methods

- `nativeGenerateSeed(): ByteArray?`
- `nativePublicKeyForSeed(seed: ByteArray): String?`
- `nativeInstallSeed(seed: ByteArray, expectedPublicKeyHex: String): Boolean`
- `nativeClearInstalledIdentity(): Boolean`
- `nativeInstalledPublicKeyHex(): String?`

JNI names escape the underscore in `crypto_spike` as `crypto_1spike`, as required by JNI symbol mangling.

### Seed handling

Provisioning:

1. Rust generates a 32-byte X25519 private seed.
2. JNI copies the seed into a Kotlin `ByteArray`.
3. Kotlin derives the public key through JNI and checks it.
4. Kotlin installs the seed into Rust through JNI.
5. Kotlin wraps the seed with AES-256-GCM under the Keystore key.
6. Kotlin zeroizes its seed buffer in `finally`.

Restore:

1. Kotlin unwraps the seed from the versioned blob.
2. Kotlin installs it into Rust with the stored public key as the expected value.
3. Rust re-derives the public key and rejects a mismatch.
4. Kotlin verifies the installed public key again and zeroizes its seed buffer.

The seed is never formatted into a string, placed in a MethodChannel result, exposed through FRB, or logged.

## Persistence format

Path: `noBackupFilesDir/identity/identity_v1.bin`

```text
"BCSI"             4 bytes
version            1 byte   (1)
IV length          1 byte   (12)
IV                 12 bytes
AES-GCM ciphertext 48 bytes (32-byte seed + 16-byte tag)
```

The 5-byte header is used as AAD. The file is written to a temporary file, synced, and renamed before metadata is committed.

Keystore alias: `bechat_spike_identity_wrap_v1`

- AES-256-GCM
- `PURPOSE_ENCRYPT | PURPOSE_DECRYPT`
- randomized encryption required
- no padding
- non-exportable private key

Metadata: `SharedPreferences` named `bechat_spike_identity_metadata`

- `public_key_hex`
- `metadata_version = 1`

`android:allowBackup="false"` is set in the spike manifest. The blob is additionally under `noBackupFilesDir`, so Android backup does not include it.

## Failure behavior

| Condition | Result | Replacement allowed? |
| --- | --- | --- |
| No metadata and no blob | `uninitialized` | Only by explicit `provision` |
| Valid blob and matching metadata | `ready` | No |
| Blob missing but metadata exists | `identity_lost` | No |
| Metadata missing but blob exists | `identity_lost` | No |
| Malformed/unsupported blob | `corrupt` | No |
| GCM authentication failure | `corrupt` | No |
| Keystore alias missing/unretrievable | `key_unavailable` | No |
| Recovered seed does not match metadata | `mismatch` | No |
| Unexpected JNI failure | `native_error` | No |
| Explicit reset | `uninitialized` | Only after reset |

`provision` refuses to run while either metadata or ciphertext exists. There is no automatic replacement path. A crash between blob and metadata commits produces `identity_lost`, not a new identity.

## Validation evidence

### Rust

- `cargo fmt --check`: passed.
- `cargo test`: 7 passed.
- `cargo clippy --all-targets -- -D warnings`: passed.
- Tests cover XX and IK round trips, wrong pinned keys, malformed handshakes, tampered ciphertext, closed handles, fresh ephemeral material, installed-identity XX/IK, reset, wrong public key, and invalid seed length.

### Android runtime

The integration suite passed on both emulators:

- `Pixel_3a`, API 30, Android 11, x86_64.
- `Medium_Phone_API_36.0`, API 36, Android 16, x86_64.

Each suite ran 5 tests:

- Native identity lifecycle.
- Spike UI render.
- Native Keystore identity self-test.
- Noise XX/IK bridge self-test.
- Secure-storage comparison probe.

The lifecycle test covered:

- Reset, uninitialized status, provision, and ready status.
- Public key and fingerprint length.
- Restore with the same public key.
- Installed identity XX handshake and transport.
- Installed identity IK handshake and wrong-pin rejection.
- Public-key mismatch rejection while the installed identity remains unchanged.
- Corrupted blob -> `corrupt`; restore remains `corrupt`.
- Reset and reprovision -> different public identity.
- Deleted blob -> `identity_lost`; restore remains `identity_lost`.
- Deleted Keystore alias -> `key_unavailable`; restore remains `key_unavailable`.
- Reset and reprovision -> different public identity.

### Process restart

On both API 30 and API 36:

1. The app provisioned an identity.
2. `adb shell am force-stop` was run; `pidof` returned no process.
3. The activity was relaunched.
4. The app displayed `Native identity: ready` with the same public key and fingerprint.

API 30 required a temporary Impeller-disabled build because the emulator's default GLES renderer failed to link a shader and left the launch screen visible. That override was not retained. The API 36 check used the final build. The identity path was identical in both cases.

### Backup and storage

- `bmgr backupnow com.bechat.spike.crypto_spike` returned `Backup is not allowed`.
- Package flags did not include `ALLOW_BACKUP`.
- The encrypted blob was 66 bytes at `no_backup/identity/identity_v1.bin` with mode `0600`.
- No identity material was found under `files/`.

## Threat analysis

### Covered

- **Dart/FRB exposure:** no private seed crosses FRB or a Dart API.
- **At-rest plaintext:** only ciphertext is persisted; the wrapping key is in Android Keystore.
- **Blob tampering:** AES-GCM authentication fails closed as `corrupt`.
- **Wrong public metadata:** seed re-derivation is compared to metadata; failure is `mismatch`.
- **Silent identity replacement:** provisioning is blocked while any identity state exists.
- **Accidental backup of ciphertext:** backup is disabled and the blob is in `noBackupFilesDir`.
- **Crash between writes:** state becomes `identity_lost`; no replacement.
- **Wrong remote key:** IK pins and XX expected keys are checked against Snow's authenticated static key.

### Not covered

- Compromised app process, rooted device, or runtime instrumentation.
- JVM/GC remnants, native allocator remnants, or provider-internal copies of the seed.
- Snow internal state zeroization.
- Hardware-backed Keystore/TEE/StrongBox guarantees.
- Locked-device or user-authentication requirements.
- Multi-process access and file-lock races.
- Android backup/device-transfer edge cases on physical devices.
- Rollback, replay, session lifetime, rekeying, and resource exhaustion policy.
- Remote-key pin-change UX, safety-number verification, and application trust.
- BLE framing, fragmentation, and production database integration.
- Physical-device timing, memory, power, and side-channel behavior.

## Residual risks

1. **Seed exists briefly in Kotlin memory.** This is inherent to Option B's JNI design. `ByteArray.fill(0)` and Rust `Zeroizing` reduce exposure but cannot prove the JVM or Keystore provider discarded every copy.
2. **Keystore is not doing the Noise operation.** The Keystore key only wraps/unwraps. Rust still needs a usable private seed for Snow. A future design could keep the key entirely in native/Keystore-backed code, but that is not demonstrated here.
3. **No hardware-backing proof.** The emulator does not establish TEE/StrongBox behavior. A production design should inspect `KeyInfo` and define behavior when hardware backing is absent.
4. **Key invalidation is fatal by design.** Losing the Keystore alias makes the identity unrecoverable. The product must present a clear re-enrollment path and must not treat this as silent recovery.
5. **Metadata is not part of the GCM AAD.** Tampering is detected through seed/public-key comparison, but a future format should authenticate metadata with the blob.
6. **No multi-process coordination.** The sample's synchronized singleton controller assumes one process. Production must define ownership and file locking.
7. **Metadata version is not validated on restore.** The version is written, but blob version and public-key hex are the values currently checked. A future format should reject unsupported metadata versions explicitly.
8. **No physical-device validation.** All runtime results are emulator results.

## Production prerequisites

- Review whether Kotlin holding the seed during provision/restore is acceptable.
- Define backup, device-transfer, reinstall, and identity-loss policy.
- Add explicit reset/re-enrollment UX and user-visible key-loss messaging.
- Define hardware-backed-key requirements and behavior when absent.
- Add session lifetime, rekeying, replay/resource limits, and BLE framing limits.
- Validate on physical Android 11 and Android 16 devices.
- Add remote-key pin-change policy and safety-number verification.
- Perform an independent review of the JNI/FFI surface and Snow zeroization.

## Conclusion

The Option B spike satisfies the core boundary requirement for this phase: the Noise private seed is generated, wrapped, unwrapped, and installed through native code, and Dart receives only public identity and status. Persistence is fail-closed, reset is explicit, and XX/IK work with the installed identity on both required emulator API levels.

The remaining risks are real but bounded for a spike: temporary Kotlin/JVM copies, unverified hardware backing, no physical-device testing, and an intentionally non-recoverable key-loss path. The result supports a **conditional GO for Phase 1 integration planning**, not a production E2EE or hardware-isolation claim.
