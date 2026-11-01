package com.bechat.bechat

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Fixed-code failure raised by [SecureSessionController]. */
class SecureSessionException(val code: String, message: String) : Exception(message)

/**
 * MethodChannel controller for the production Rust Noise XX session engine.
 *
 * Channel `bechat/secure_session`. This controller is the Kotlin half of the
 * secure transport boundary: it validates inputs, serializes native calls on
 * a single background executor, maps the engine's fixed errors onto typed
 * MethodChannel errors, and tracks the sessions it created for lifecycle
 * cleanup. It never touches SQLite, peers, the BLE runtime or Dart-side
 * message state — the later integration layer owns link-to-session mapping.
 *
 * Security properties preserved here:
 *
 * * Sessions are created from the **installed** identity only. There is no
 *   parameter, method or result carrying a seed or private-key bytes, and a
 *   missing/invalid identity fails session creation closed.
 * * A completed handshake does not unlock transport: [confirmPeerIdentity]
 *   must succeed first, mirroring the engine's explicit-confirmation gate.
 *   This controller never marks a peer `verified`.
 * * All native failures carry the engine's fixed, non-secret messages; no
 *   debug-formatted Rust output, payload bytes or key material ever reaches
 *   a MethodChannel result or error.
 *
 * Threading: every operation runs on one bounded serial executor, which
 * preserves per-session call ordering (handshake steps, encrypt/decrypt
 * pairs) without holding Android's main thread across native crypto. Results
 * are completed on the platform thread as MethodChannel requires. A saturated
 * queue fails fast with [ERROR_BUSY] instead of growing without bound.
 */
object SecureSessionController : MethodChannel.MethodCallHandler {
    const val CHANNEL = "bechat/secure_session"

    /** Engine stages, as reported by `getSessionStatus` and handshake steps. */
    const val STAGE_HANDSHAKING = "handshaking"
    const val STAGE_AWAITING_CONFIRMATION = "awaiting_confirmation"
    const val STAGE_READY = "ready"
    const val STAGE_FAILED = "failed"

    const val ERROR_INVALID_ARGUMENT = "SESSION_INVALID_ARGUMENT"
    const val ERROR_NATIVE = "SESSION_NATIVE_ERROR"
    const val ERROR_BUSY = "SESSION_BUSY"

    // Input bounds mirrored from `native/crypto_core/src/session.rs`. Kotlin
    // rejects oversized or malformed input before it crosses JNI; the Rust
    // engine re-validates every value on its side (fail closed in both).
    const val MAX_DEVICE_ID_LENGTH = 128
    const val MAX_DISPLAY_NAME_LENGTH = 64
    const val MAX_HANDSHAKE_MESSAGE_BYTES = 1024
    const val MAX_TRANSPORT_MESSAGE_BYTES = 8192
    const val MAX_TRANSPORT_PLAINTEXT_BYTES = MAX_TRANSPORT_MESSAGE_BYTES - 16

    private const val METHOD_CREATE_SESSION = "createSession"
    private const val METHOD_START_HANDSHAKE = "startHandshake"
    private const val METHOD_PROCESS_HANDSHAKE = "processHandshake"
    private const val METHOD_GET_SESSION_STATUS = "getSessionStatus"
    private const val METHOD_CONFIRM_PEER_IDENTITY = "confirmPeerIdentity"
    private const val METHOD_ENCRYPT = "encrypt"
    private const val METHOD_DECRYPT = "decrypt"
    private const val METHOD_CLOSE_SESSION = "closeSession"

    private const val ARG_HANDLE = "handle"
    private const val ARG_INITIATOR = "initiator"
    private const val ARG_DEVICE_ID = "deviceId"
    private const val ARG_DISPLAY_NAME = "displayName"
    private const val ARG_PINNED_REMOTE_PUBLIC_KEY_HEX = "pinnedRemotePublicKeyHex"
    private const val ARG_EXPECTED_REMOTE_DEVICE_ID = "expectedRemoteDeviceId"
    private const val ARG_INCOMING = "incoming"
    private const val ARG_PLAINTEXT = "plaintext"
    private const val ARG_CIPHERTEXT = "ciphertext"

    private const val KEY_HANDLE = "handle"
    private const val KEY_CLOSED = "closed"
    private const val KEY_CIPHERTEXT = "ciphertext"
    private const val KEY_PLAINTEXT = "plaintext"
    private const val KEY_STAGE = "stage"

    /**
     * Capacity of the serial crypto-operation queue.
     *
     * The executor stays single-threaded: native calls are never parallelized,
     * because the Rust engine's per-session state and the Dart session TX/RX
     * queues already serialize work per session and running crypto on multiple
     * threads would buy nothing while complicating that ordering. Only the
     * queue depth changed for multi-connection: with up to 8 simultaneous
     * links, a single peer's message round can occupy several slots at once
     * (encrypt, decrypt, acknowledgement), so the old depth of 32 could be
     * exhausted by legitimate cross-peer traffic and fail healthy links with
     * SESSION_BUSY. 64 gives headroom for all links draining concurrently
     * while still bounding memory and failing fast when saturated.
     */
    private const val MAX_QUEUED_OPERATIONS = 64

    /** Every transport message carries at least the ChaChaPoly tag. */
    const val AUTHENTICATION_TAG_BYTES = 16

    /** Mirrors the engine's `CAPABILITY_SECURE_TEXT` bit (`0b0000_0001`). */
    const val CAPABILITY_SECURE_TEXT_MASK = 0x01

    private val HANDLED_METHODS = setOf(
        METHOD_CREATE_SESSION,
        METHOD_START_HANDSHAKE,
        METHOD_PROCESS_HANDSHAKE,
        METHOD_GET_SESSION_STATUS,
        METHOD_CONFIRM_PEER_IDENTITY,
        METHOD_ENCRYPT,
        METHOD_DECRYPT,
        METHOD_CLOSE_SESSION,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = ThreadPoolExecutor(
        1,
        1,
        0L,
        TimeUnit.MILLISECONDS,
        LinkedBlockingQueue(MAX_QUEUED_OPERATIONS),
    )

    /** Handles this controller created and not yet closed. Cleanup aid only:
     * the native registry stays the source of truth for liveness. */
    private val openSessions = LinkedHashSet<Int>()

    // -------------------------------------------------------- channel entry

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in HANDLED_METHODS) {
            result.notImplemented()
            return
        }
        try {
            executor.execute {
                val response = try {
                    dispatch(call)
                } catch (error: SecureSessionException) {
                    mainHandler.post { result.error(error.code, error.message, null) }
                    return@execute
                } catch (_: Throwable) {
                    // Fixed, non-secret error: never forward native details.
                    mainHandler.post {
                        result.error(
                            ERROR_NATIVE,
                            "The secure session service is unavailable.",
                            null,
                        )
                    }
                    return@execute
                }
                mainHandler.post { result.success(response) }
            }
        } catch (_: RejectedExecutionException) {
            // The bounded queue is full: fail fast rather than grow forever.
            result.error(ERROR_BUSY, "The secure session service is busy.", null)
        } catch (_: Throwable) {
            result.error(ERROR_NATIVE, "The secure session service is unavailable.", null)
        }
    }

    private fun dispatch(call: MethodCall): Any? = when (call.method) {
        METHOD_CREATE_SESSION -> {
            val pinned = optionalBoundedString(
                call.argument<Any>(ARG_PINNED_REMOTE_PUBLIC_KEY_HEX),
                "pinnedRemotePublicKeyHex",
                HEX_32_PATTERN,
            )
            val expected = optionalBoundedString(
                call.argument<Any>(ARG_EXPECTED_REMOTE_DEVICE_ID),
                "expectedRemoteDeviceId",
                null,
                MAX_DEVICE_ID_LENGTH,
            )
            createSession(
                initiator = call.argument<Boolean>(ARG_INITIATOR) == true,
                deviceId = requireString(call, ARG_DEVICE_ID, MAX_DEVICE_ID_LENGTH),
                displayName = requireString(call, ARG_DISPLAY_NAME, MAX_DISPLAY_NAME_LENGTH),
                pinnedRemotePublicKeyHex = pinned,
                expectedRemoteDeviceId = expected,
            )
        }

        METHOD_START_HANDSHAKE -> startHandshake(requireHandle(call))

        METHOD_PROCESS_HANDSHAKE -> processHandshake(
            requireHandle(call),
            requireBytes(call, ARG_INCOMING, MAX_HANDSHAKE_MESSAGE_BYTES),
        )

        METHOD_GET_SESSION_STATUS -> getSessionStatus(requireHandle(call))

        METHOD_CONFIRM_PEER_IDENTITY -> {
            confirmPeerIdentity(requireHandle(call))
            linkedMapOf("confirmed" to true)
        }

        METHOD_ENCRYPT -> {
            val handle = requireHandle(call)
            val plaintext = requireBytes(call, ARG_PLAINTEXT, MAX_TRANSPORT_PLAINTEXT_BYTES)
            linkedMapOf(KEY_CIPHERTEXT to encrypt(handle, plaintext))
        }

        METHOD_DECRYPT -> {
            val handle = requireHandle(call)
            val ciphertext = requireBytes(
                call,
                ARG_CIPHERTEXT,
                MAX_TRANSPORT_MESSAGE_BYTES,
                minBytes = AUTHENTICATION_TAG_BYTES,
            )
            linkedMapOf(KEY_PLAINTEXT to decrypt(handle, ciphertext))
        }

        METHOD_CLOSE_SESSION -> linkedMapOf(KEY_CLOSED to closeSession(requireHandle(call)))

        else -> null
    }

    // ------------------------------------------------------ direct surface

    /**
     * Creates a session over the installed native identity.
     *
     * Fails closed (fixed code and message) on absent identity, malformed
     * pin, invalid fields or exhausted session capacity. Never generates or
     * replaces an identity.
     */
    @Synchronized
    fun createSession(
        initiator: Boolean,
        deviceId: String,
        displayName: String,
        pinnedRemotePublicKeyHex: String?,
        expectedRemoteDeviceId: String?,
    ): Map<String, Any> {
        val handle = withNative {
            NativeCryptoBridge.nativeSessionCreate(
                initiator,
                deviceId,
                displayName,
                pinnedRemotePublicKeyHex,
                expectedRemoteDeviceId,
            )
        }
        openSessions.add(handle)
        return linkedMapOf(KEY_HANDLE to handle)
    }

    /** Produces handshake message 1 (initiator sessions only). */
    @Synchronized
    fun startHandshake(handle: Int): Map<String, Any?> = withNative {
        NativeCryptoBridge.nativeSessionStartHandshake(handle)
    }

    /** Consumes one inbound handshake message; returns the next outbound one. */
    @Synchronized
    fun processHandshake(handle: Int, incoming: ByteArray): Map<String, Any?> = withNative {
        NativeCryptoBridge.nativeSessionProcessHandshake(handle, incoming)
    }

    /** Non-secret stage snapshot for a live session. */
    @Synchronized
    fun getSessionStatus(handle: Int): Map<String, Any?> = withNative {
        NativeCryptoBridge.nativeSessionStatus(handle)
    }

    /**
     * Explicit authorization gate. The caller must have reviewed the
     * authenticated remote identity from the handshake result before this
     * succeeds; only then do encrypt/decrypt become available.
     */
    @Synchronized
    fun confirmPeerIdentity(handle: Int) {
        withNative { NativeCryptoBridge.nativeSessionConfirmPeerIdentity(handle) }
    }

    /** Encrypts one plaintext payload with a confirmed session. */
    @Synchronized
    fun encrypt(handle: Int, plaintext: ByteArray): ByteArray = withNative {
        NativeCryptoBridge.nativeSessionEncrypt(handle, plaintext)
    }

    /** Decrypts one authenticated payload; failure poisons the session. */
    @Synchronized
    fun decrypt(handle: Int, ciphertext: ByteArray): ByteArray = withNative {
        NativeCryptoBridge.nativeSessionDecrypt(handle, ciphertext)
    }

    /** Closes one session. Idempotent: an already-closed handle is not an error. */
    @Synchronized
    fun closeSession(handle: Int): Boolean {
        val closed = try {
            NativeCryptoBridge.nativeSessionClose(handle)
        } catch (_: Throwable) {
            false
        }
        openSessions.remove(handle)
        return closed
    }

    /**
     * Closes every session this controller still tracks. Called when the
     * hosting activity is genuinely finishing, so half-open Noise state does
     * not outlive the process UI; routine activity recreation never calls it.
     */
    @Synchronized
    fun closeAllSessions() {
        for (handle in openSessions.toList()) {
            try {
                NativeCryptoBridge.nativeSessionClose(handle)
            } catch (_: Throwable) {
                // Best effort: the native registry drops everything at
                // process exit regardless.
            }
        }
        openSessions.clear()
    }

    /** Test aid: number of sessions this controller still tracks. */
    @Synchronized
    fun trackedSessionCount(): Int = openSessions.size

    // ------------------------------------------------------------ validation

    private fun requireHandle(call: MethodCall): Int {
        val handle = (call.argument<Any>(ARG_HANDLE) as? Number)?.toInt()
            ?: throw invalid("A session handle is required.")
        if (handle <= 0) {
            throw invalid("The session handle is not valid.")
        }
        return handle
    }

    private fun requireString(call: MethodCall, key: String, maxLength: Int): String {
        val value = (call.argument<Any>(key) as? String)
            ?: throw invalid("A value is required for $key.")
        validateBoundedText(value, key, null, maxLength)
        return value
    }

    private fun optionalBoundedString(
        raw: Any?,
        key: String,
        pattern: Regex?,
        maxLength: Int = 64,
    ): String? {
        if (raw == null) return null
        val value = raw as? String ?: throw invalid("The value for $key is not correctly formatted.")
        validateBoundedText(value, key, pattern, maxLength)
        return value
    }

    private fun validateBoundedText(
        value: String,
        key: String,
        pattern: Regex?,
        maxLength: Int,
    ) {
        if (value.isBlank()) {
            throw invalid("The value for $key must not be blank.")
        }
        // Rust bounds field lengths in UTF-8 bytes; measure the same way so
        // Kotlin and the engine always agree on what "too long" means.
        if (value.toByteArray(Charsets.UTF_8).size > maxLength) {
            throw invalid("The value for $key is too long.")
        }
        if (pattern != null && !pattern.matches(value)) {
            throw invalid("The value for $key is not correctly formatted.")
        }
    }

    private fun requireBytes(
        call: MethodCall,
        key: String,
        maxBytes: Int,
        minBytes: Int = 0,
    ): ByteArray {
        val value = call.argument<ByteArray>(key)
            ?: throw invalid("A value is required for $key.")
        if (value.size < minBytes) {
            throw invalid("The value for $key is too small.")
        }
        if (value.size > maxBytes) {
            throw invalid("The value for $key is too large.")
        }
        return value
    }

    private fun invalid(message: String) = SecureSessionException(ERROR_INVALID_ARGUMENT, message)

    /**
     * Runs one native call, converting its `IllegalStateException` (the fixed,
     * non-secret engine error strings) into a typed controller error. The
     * engine's messages are string literals by contract, so none of them can
     * carry key material or payload bytes.
     */
    private inline fun <T> withNative(block: () -> T): T = try {
        block()
    } catch (error: SecureSessionException) {
        throw error
    } catch (error: IllegalStateException) {
        throw SecureSessionException(ERROR_NATIVE, error.message ?: NATIVE_FALLBACK_MESSAGE)
    } catch (_: Throwable) {
        throw SecureSessionException(ERROR_NATIVE, NATIVE_FALLBACK_MESSAGE)
    }

    private const val NATIVE_FALLBACK_MESSAGE = "The secure session operation failed."
    private val HEX_32_PATTERN = Regex("^[0-9a-f]{64}$")
}
