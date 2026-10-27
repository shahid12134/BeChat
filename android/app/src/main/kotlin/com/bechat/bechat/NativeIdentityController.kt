package com.bechat.bechat

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Non-secret identity status reported to Dart.
 *
 * Contains only public identity information and fixed status text. There is no
 * field for a seed, a wrapping key, ciphertext or any other native memory.
 */
data class NativeIdentityStatus(
    val state: String,
    val publicKeyHex: String? = null,
    val fingerprintHex: String? = null,
    val message: String? = null,
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "state" to state,
        "publicKeyHex" to publicKeyHex,
        "fingerprintHex" to fingerprintHex,
        "message" to message,
    )
}

/** Raised when a destructive identity reset is attempted without confirmation. */
class ResetNotConfirmedException : Exception("identity reset requires explicit confirmation")

/**
 * Coordinates the production Noise identity lifecycle.
 *
 * Responsibilities:
 *
 * * provision a first identity (Rust generates the seed, Kotlin wraps and
 *   persists it through [IdentityBlobStore]);
 * * restore an existing identity, failing closed when any part of it is
 *   missing, corrupt, unsupported or inconsistent;
 * * report only non-secret status;
 * * perform an explicit, confirmation-gated destructive reset.
 *
 * Deliberately **not** responsible for: application bootstrap provisioning,
 * SQLite/peer integration, BLE handshakes or message encryption. Nothing here
 * provisions an identity until Dart calls `initialize`, and nothing here ever
 * regenerates an identity that is known to have existed.
 *
 * All state transitions are `@Synchronized`, so concurrent UI/background
 * callers cannot provision two different identities.
 */
object NativeIdentityController : MethodChannel.MethodCallHandler {
    const val CHANNEL = "bechat/native_identity"

    const val STATE_UNINITIALIZED = "uninitialized"
    const val STATE_READY = "ready"
    const val STATE_BLOB_MISSING = "blob_missing"
    const val STATE_BLOB_CORRUPT = "blob_corrupt"
    const val STATE_BLOB_UNSUPPORTED = "blob_unsupported"
    const val STATE_KEY_UNAVAILABLE = "key_unavailable"
    const val STATE_METADATA_INVALID = "metadata_invalid"
    const val STATE_MISMATCH = "mismatch"
    const val STATE_NATIVE_ERROR = "native_error"
    const val STATE_STORE_FAILED = "store_failed"

    private const val METHOD_STATUS = "status"
    private const val METHOD_INITIALIZE = "initialize"
    private const val METHOD_RESET = "reset"
    private const val ARG_CONFIRM = "confirm"

    private const val ERROR_CONTROLLER_UNAVAILABLE = "IDENTITY_UNAVAILABLE"
    private const val ERROR_RESET_NOT_CONFIRMED = "RESET_NOT_CONFIRMED"

    private var store: IdentityBlobStore? = null
    private var cachedStatus: NativeIdentityStatus? = null

    /**
     * Creates the on-device store for this process. This performs no file,
     * Keystore or native work: nothing is provisioned or restored until Dart
     * asks for it.
     */
    @Synchronized
    fun attach(context: Context) {
        if (store == null) {
            store = IdentityBlobStore(context.applicationContext)
        }
    }

    /**
     * Provisions a first identity when nothing exists yet, otherwise restores
     * the existing identity. Never silently replaces an established identity.
     */
    @Synchronized
    fun initialize(context: Context): NativeIdentityStatus {
        attach(context)
        val status = initializeLocked()
        cachedStatus = status
        return status
    }

    /**
     * Reports the current state without provisioning anything.
     *
     * The first call performs a read-only assessment of persisted state (and,
     * for an established identity, an authenticated restore attempt).
     */
    @Synchronized
    fun status(context: Context): NativeIdentityStatus {
        attach(context)
        val status = cachedStatus ?: assessLocked()
        cachedStatus = status
        return status
    }

    /**
     * Destructively resets the identity: clears the installed native identity,
     * deletes the encrypted blob, deletes the non-secret metadata and deletes
     * the Keystore wrapping key.
     *
     * [confirmed] must be `true`; the caller (ultimately a user-confirmed UI
     * action) decides that. Application data such as peers, chats, messages
     * and the device UUID is untouched: this phase never touches the database.
     */
    @Synchronized
    fun reset(context: Context, confirmed: Boolean): NativeIdentityStatus {
        if (!confirmed) {
            throw ResetNotConfirmedException()
        }
        attach(context)
        val status = resetLocked()
        cachedStatus = status
        return status
    }

    @Synchronized
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (store == null) {
            result.error(
                ERROR_CONTROLLER_UNAVAILABLE,
                "The native identity service is unavailable.",
                null,
            )
            return
        }

        try {
            when (call.method) {
                METHOD_INITIALIZE -> {
                    val status = initializeLocked()
                    cachedStatus = status
                    result.success(status.toMap())
                }

                METHOD_STATUS -> {
                    val status = cachedStatus ?: assessLocked()
                    cachedStatus = status
                    result.success(status.toMap())
                }

                METHOD_RESET -> {
                    if (call.argument<Boolean>(ARG_CONFIRM) != true) {
                        result.error(
                            ERROR_RESET_NOT_CONFIRMED,
                            "Resetting the cryptographic identity requires explicit confirmation.",
                            null,
                        )
                        return
                    }
                    val status = resetLocked()
                    cachedStatus = status
                    result.success(status.toMap())
                }

                else -> result.notImplemented()
            }
        } catch (_: ResetNotConfirmedException) {
            result.error(
                ERROR_RESET_NOT_CONFIRMED,
                "Resetting the cryptographic identity requires explicit confirmation.",
                null,
            )
        } catch (_: Throwable) {
            // Fixed, non-secret error: no native or provider detail is exposed.
            result.error(
                ERROR_CONTROLLER_UNAVAILABLE,
                "The native identity service is unavailable.",
                null,
            )
        }
    }

    /** Only used by tests and tooling to drop cached status. */
    @Synchronized
    fun forgetCachedStatus() {
        cachedStatus = null
    }

    // --------------------------------------------------------------- lifecycle

    private fun initializeLocked(): NativeIdentityStatus {
        val identityStore = requireStore()
        val hasMetadata = identityStore.hasMetadata()
        val hasBlob = identityStore.hasBlob()

        return when {
            // Fresh installation: nothing at all exists yet.
            !hasMetadata && !hasBlob -> provisionLocked()

            // Orphaned encrypted blob without the public metadata that
            // authenticates it. Fail closed: never regenerate silently.
            !hasMetadata -> fail(
                STATE_METADATA_INVALID,
                "Public identity metadata is missing for an existing encrypted identity.",
            )

            // Established identity (with or without its blob): restore.
            else -> restoreLocked()
        }
    }

    /** Read-only assessment: identical to [initializeLocked] minus provisioning. */
    private fun assessLocked(): NativeIdentityStatus {
        val identityStore = requireStore()
        val hasMetadata = identityStore.hasMetadata()
        val hasBlob = identityStore.hasBlob()

        return when {
            !hasMetadata && !hasBlob -> NativeIdentityStatus(STATE_UNINITIALIZED)
            !hasMetadata -> fail(
                STATE_METADATA_INVALID,
                "Public identity metadata is missing for an existing encrypted identity.",
            )
            else -> restoreLocked()
        }
    }

    private fun provisionLocked(): NativeIdentityStatus {
        val identityStore = requireStore()

        // Fail closed if anything appeared since the caller checked.
        if (identityStore.hasMetadata() || identityStore.hasBlob()) {
            return restoreLocked()
        }

        val seed = try {
            NativeCryptoBridge.nativeGenerateSeed()
        } catch (_: Throwable) {
            null
        } ?: return fail(STATE_NATIVE_ERROR, "Identity generation failed.")

        var committed = false
        try {
            val publicKeyHex = try {
                NativeCryptoBridge.nativePublicKeyForSeed(seed)
            } catch (_: Throwable) {
                null
            } ?: return fail(STATE_NATIVE_ERROR, "Identity public key derivation failed.")

            if (publicKeyHex.length != 64) {
                return fail(STATE_NATIVE_ERROR, "Identity public key derivation failed.")
            }

            val installed = try {
                NativeCryptoBridge.nativeInstallSeed(seed, publicKeyHex)
            } catch (_: Throwable) {
                false
            }
            if (!installed) {
                return fail(STATE_NATIVE_ERROR, "Identity installation failed.")
            }

            try {
                identityStore.wrapAndPersist(seed, publicKeyHex)
                identityStore.writeMetadata(publicKeyHex)
                committed = true
            } catch (error: Throwable) {
                // Roll back partial provisioning so a retry starts clean. An
                // interrupted process (not an exception) leaves an orphan blob
                // that recovery treats as fail-closed metadata_invalid.
                identityStore.deleteBlob()
                identityStore.deleteMetadata()
                return fail(stateForStoreFailure(error), "Identity could not be persisted.")
            }

            return readyStatus(publicKeyHex)
        } finally {
            seed.fill(0)
            if (!committed) {
                clearNativeIdentity()
            }
        }
    }

    private fun restoreLocked(): NativeIdentityStatus {
        val identityStore = requireStore()

        if (!identityStore.hasMetadata()) {
            clearNativeIdentity()
            return fail(
                STATE_METADATA_INVALID,
                "Public identity metadata is missing for an existing encrypted identity.",
            )
        }

        val metadata = try {
            identityStore.readMetadata()
        } catch (error: Throwable) {
            clearNativeIdentity()
            return fail(stateForStoreFailure(error), "Identity metadata is not usable.")
        } ?: run {
            clearNativeIdentity()
            return fail(STATE_METADATA_INVALID, "Identity metadata is missing.")
        }

        clearNativeIdentity()

        if (!identityStore.hasBlob()) {
            return fail(STATE_BLOB_MISSING, "Encrypted identity blob is missing.")
        }

        val seed = try {
            identityStore.unwrapPersisted(metadata.publicKeyHex)
        } catch (error: Throwable) {
            return fail(stateForStoreFailure(error), "Encrypted identity could not be recovered.")
        }

        try {
            val installed = try {
                NativeCryptoBridge.nativeInstallSeed(seed, metadata.publicKeyHex)
            } catch (_: Throwable) {
                false
            }
            if (!installed) {
                clearNativeIdentity()
                return fail(STATE_MISMATCH, "Recovered identity does not match its public key.")
            }

            val installedPublicKey = try {
                NativeCryptoBridge.nativeInstalledPublicKeyHex()
            } catch (_: Throwable) {
                null
            }
            if (installedPublicKey != metadata.publicKeyHex) {
                clearNativeIdentity()
                return fail(STATE_MISMATCH, "Recovered identity does not match its public key.")
            }

            return readyStatus(metadata.publicKeyHex)
        } finally {
            seed.fill(0)
        }
    }

    private fun resetLocked(): NativeIdentityStatus {
        val identityStore = requireStore()

        clearNativeIdentity()
        identityStore.deleteBlob()
        identityStore.deleteMetadata()
        try {
            identityStore.deleteKeystoreKey()
        } catch (_: Throwable) {
            // Blob and metadata are already gone; a later provision can create
            // a fresh wrapping key if the stale alias cannot be removed.
        }
        return NativeIdentityStatus(STATE_UNINITIALIZED)
    }

    private fun readyStatus(publicKeyHex: String): NativeIdentityStatus {
        val fingerprint = try {
            publicKeyFingerprintHex(publicKeyHex)
        } catch (_: Throwable) {
            null
        }
        return NativeIdentityStatus(
            state = STATE_READY,
            publicKeyHex = publicKeyHex,
            fingerprintHex = fingerprint,
        )
    }

    private fun fail(state: String, message: String): NativeIdentityStatus =
        NativeIdentityStatus(state = state, message = message)

    private fun stateForStoreFailure(error: Throwable): String = when (error) {
        is KeystoreKeyUnavailableException -> STATE_KEY_UNAVAILABLE
        is BlobUnsupportedException -> STATE_BLOB_UNSUPPORTED
        is BlobMissingException -> STATE_BLOB_MISSING
        is BlobCorruptException -> STATE_BLOB_CORRUPT
        is MetadataInvalidException -> STATE_METADATA_INVALID
        is IdentityStoreException -> STATE_STORE_FAILED
        else -> STATE_STORE_FAILED
    }

    private fun requireStore(): IdentityBlobStore =
        store ?: throw IdentityStoreException("identity store is unavailable")

    private fun clearNativeIdentity() {
        try {
            NativeCryptoBridge.nativeClearInstalledIdentity()
        } catch (_: Throwable) {
            // A missing native library must never fall back to accepting
            // identity material somewhere else.
        }
    }
}
