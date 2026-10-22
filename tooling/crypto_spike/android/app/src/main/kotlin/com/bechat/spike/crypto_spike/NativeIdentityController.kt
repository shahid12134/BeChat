package com.bechat.spike.crypto_spike

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.GeneralSecurityException
import javax.crypto.AEADBadTagException

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

object NativeIdentityController : MethodChannel.MethodCallHandler {
    const val CHANNEL = "bechat.spike/native_identity"

    private const val STATE_UNINITIALIZED = "uninitialized"
    private const val STATE_READY = "ready"
    private const val STATE_IDENTITY_LOST = "identity_lost"
    private const val STATE_CORRUPT = "corrupt"
    private const val STATE_KEY_UNAVAILABLE = "key_unavailable"
    private const val STATE_MISMATCH = "mismatch"
    private const val STATE_NATIVE_ERROR = "native_error"

    private var store: IdentityBlobStore? = null
    private var status = NativeIdentityStatus(STATE_UNINITIALIZED)

    @Synchronized
    fun initialize(context: Context) {
        if (store == null) {
            store = IdentityBlobStore(context.applicationContext)
            status = restoreLocked()
        }
    }

    @Synchronized
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (store == null) {
            result.error("identity_error", "identity controller is not initialized", null)
            return
        }

        try {
            when (call.method) {
                "status" -> result.success(status.toMap())
                "provision" -> result.success(provisionLocked().toMap())
                "restore" -> result.success(restoreLocked().toMap())
                "reset" -> result.success(resetLocked().toMap())
                "debugDeleteBlob" -> {
                    store!!.deleteCiphertext()
                    clearNativeIdentity()
                    result.success(restoreLocked().toMap())
                }
                "debugCorruptBlob" -> {
                    store!!.corruptCiphertext()
                    clearNativeIdentity()
                    result.success(restoreLocked().toMap())
                }
                "debugDeleteKeystoreKey" -> {
                    store!!.deleteKeystoreKey()
                    clearNativeIdentity()
                    result.success(restoreLocked().toMap())
                }
                "verifyPublicKeyMismatchRejected" -> {
                    val rejected = verifyPublicKeyMismatchRejectedLocked()
                    result.success(
                        linkedMapOf(
                            "rejected" to rejected,
                            "status" to status.toMap(),
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        } catch (error: IdentityStoreException) {
            result.error("identity_error", error.message ?: "identity operation failed", null)
        } catch (error: KeystoreKeyUnavailableException) {
            result.error("identity_error", error.message ?: "identity key unavailable", null)
        } catch (error: GeneralSecurityException) {
            result.error("identity_error", "identity cryptography failed", null)
        } catch (error: Exception) {
            result.error("identity_error", "identity operation failed", null)
        }
    }

    private fun provisionLocked(): NativeIdentityStatus {
        val blobStore = store ?: throw IdentityStoreException("identity store unavailable")
        if (blobStore.hasMetadata() || blobStore.hasCiphertext()) {
            throw IdentityStoreException("identity exists; explicit reset is required")
        }

        val seed = NativeIdentityBridge.nativeGenerateSeed()
            ?: throw IdentityStoreException("identity generation failed")
        var installed = false
        try {
            val publicKeyHex = NativeIdentityBridge.nativePublicKeyForSeed(seed)
                ?: throw IdentityStoreException("identity public key derivation failed")
            if (publicKeyHex.length != 64) {
                throw IdentityStoreException("invalid derived public identity")
            }

            installed = NativeIdentityBridge.nativeInstallSeed(seed, publicKeyHex)
            if (!installed) {
                throw IdentityStoreException("identity installation failed")
            }

            try {
                blobStore.wrapAndPersist(seed)
                blobStore.writePublicKeyHex(publicKeyHex)
            } catch (error: Exception) {
                blobStore.deleteCiphertext()
                blobStore.clearPublicKeyHex()
                clearNativeIdentity()
                installed = false
                throw error
            }

            status = readyStatus(publicKeyHex)
            return status
        } finally {
            seed.fill(0)
            if (!installed) {
                clearNativeIdentity()
            }
        }
    }

    private fun restoreLocked(): NativeIdentityStatus {
        val blobStore = store ?: throw IdentityStoreException("identity store unavailable")
        val publicKeyHex = blobStore.readPublicKeyHex()
        if (publicKeyHex == null) {
            clearNativeIdentity()
            if (blobStore.hasCiphertext()) {
                status = NativeIdentityStatus(
                    STATE_IDENTITY_LOST,
                    message = "encrypted identity exists without public metadata",
                )
            } else {
                status = NativeIdentityStatus(STATE_UNINITIALIZED)
            }
            return status
        }

        clearNativeIdentity()
        val publicKeyBytes = try {
            publicKeyHex.lowerHexToBytes()
        } catch (_: IdentityStoreException) {
            status = NativeIdentityStatus(
                STATE_CORRUPT,
                message = "public identity metadata is malformed",
            )
            return status
        }
        if (publicKeyBytes.size != 32) {
            status = NativeIdentityStatus(
                STATE_CORRUPT,
                message = "public identity metadata has an invalid length",
            )
            return status
        }

        if (!blobStore.hasCiphertext()) {
            status = NativeIdentityStatus(
                STATE_IDENTITY_LOST,
                message = "encrypted identity blob is missing",
            )
            return status
        }

        val seed = try {
            blobStore.unwrapPersisted()
        } catch (_: KeystoreKeyUnavailableException) {
            status = NativeIdentityStatus(
                STATE_KEY_UNAVAILABLE,
                message = "identity wrapping key is unavailable",
            )
            return status
        } catch (_: AEADBadTagException) {
            status = NativeIdentityStatus(
                STATE_CORRUPT,
                message = "encrypted identity authentication failed",
            )
            return status
        } catch (_: GeneralSecurityException) {
            status = NativeIdentityStatus(
                STATE_CORRUPT,
                message = "encrypted identity could not be decrypted",
            )
            return status
        } catch (_: Exception) {
            status = NativeIdentityStatus(
                STATE_CORRUPT,
                message = "encrypted identity blob is invalid",
            )
            return status
        }

        try {
            val installed = NativeIdentityBridge.nativeInstallSeed(seed, publicKeyHex)
            if (!installed) {
                clearNativeIdentity()
                status = NativeIdentityStatus(
                    STATE_MISMATCH,
                    message = "recovered identity does not match public metadata",
                )
                return status
            }
            val installedPublic = NativeIdentityBridge.nativeInstalledPublicKeyHex()
            if (installedPublic != publicKeyHex) {
                clearNativeIdentity()
                status = NativeIdentityStatus(
                    STATE_MISMATCH,
                    message = "installed identity does not match public metadata",
                )
                return status
            }
            status = readyStatus(publicKeyHex)
            return status
        } catch (_: Throwable) {
            clearNativeIdentity()
            status = NativeIdentityStatus(
                STATE_NATIVE_ERROR,
                message = "native identity installation failed",
            )
            return status
        } finally {
            seed.fill(0)
        }
    }

    private fun resetLocked(): NativeIdentityStatus {
        val blobStore = store ?: throw IdentityStoreException("identity store unavailable")
        clearNativeIdentity()
        blobStore.deleteCiphertext()
        blobStore.clearPublicKeyHex()
        try {
            blobStore.deleteKeystoreKey()
        } catch (_: Exception) {
            // The blob and metadata are already gone; a later provision can still
            // create a fresh wrapping key if the old alias cannot be deleted.
        }
        status = NativeIdentityStatus(STATE_UNINITIALIZED)
        return status
    }

    private fun verifyPublicKeyMismatchRejectedLocked(): Boolean {
        val blobStore = store ?: return false
        val expectedPublicKey = blobStore.readPublicKeyHex() ?: return false
        if (!blobStore.hasCiphertext()) {
            return false
        }

        val seed = try {
            blobStore.unwrapPersisted()
        } catch (_: Exception) {
            return false
        }

        return try {
            val wrongPublicKey = "00".repeat(32)
            val accepted = NativeIdentityBridge.nativeInstallSeed(seed, wrongPublicKey)
            !accepted &&
                NativeIdentityBridge.nativeInstalledPublicKeyHex() == expectedPublicKey
        } catch (_: Throwable) {
            false
        } finally {
            seed.fill(0)
        }
    }

    private fun readyStatus(publicKeyHex: String): NativeIdentityStatus {
        val publicKeyBytes = publicKeyHex.lowerHexToBytes()
        return NativeIdentityStatus(
            state = STATE_READY,
            publicKeyHex = publicKeyHex,
            fingerprintHex = publicKeyFingerprintHex(publicKeyBytes),
        )
    }

    private fun clearNativeIdentity() {
        try {
            NativeIdentityBridge.nativeClearInstalledIdentity()
        } catch (_: Throwable) {
            // A missing native library or a JNI failure must not fall back to
            // accepting identity material in another layer.
        }
    }
}
