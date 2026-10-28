package com.bechat.bechat

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * On-device tests for the production JNI/Kotlin secure-session bridge:
 * [SecureSessionController] over `bechat/secure_session` down through
 * [NativeCryptoBridge] into the Rust Noise XX session engine.
 *
 * The tests drive the real MethodChannel path (validation, serial executor,
 * main-thread result delivery) with a capturing [MethodChannel.Result].
 *
 * Identity caveat: the production engine creates every session from the one
 * installed application identity — there is deliberately no API to inject a
 * second key pair. Handshake/transport tests below therefore run both Noise
 * roles with the *same* static identity: they are **bridge smoke tests** of
 * the JNI/controller path, not distinct-device authentication tests.
 * Distinct-identity XX authentication and wrong-pin semantics at the
 * cryptographic level are proven by the Rust engine's own suite
 * (`native/crypto_core/tests/session_engine.rs`); this suite proves the same
 * engine reachable through JNI behaves identically (pin mismatch, poisoning,
 * confirmation gating, capacity, handle hygiene).
 */
class SecureSessionControllerTest {

    private lateinit var context: Context
    private lateinit var store: IdentityBlobStore

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        store = IdentityBlobStore(context)
        NativeIdentityController.attach(context)
        NativeIdentityController.reset(context, true)
        NativeIdentityController.forgetCachedStatus()
        SecureSessionController.closeAllSessions()
        assertEquals(NativeIdentityController.STATE_READY, initializeIdentity().state)
    }

    @After
    fun tearDown() {
        SecureSessionController.closeAllSessions()
        NativeIdentityController.reset(context, true)
        NativeIdentityController.forgetCachedStatus()
    }

    private fun initializeIdentity(): NativeIdentityStatus =
        NativeIdentityController.initialize(context)

    private fun installedKeyHex(): String =
        NativeCryptoBridge.nativeInstalledPublicKeyHex()!!

    // ------------------------------------------------------- channel driving

    /** Captures one MethodChannel response delivered on the main thread. */
    private class CapturingResult : MethodChannel.Result {
        val latch = CountDownLatch(1)

        @Volatile var value: Any? = null
        @Volatile var errorCode: String? = null
        @Volatile var errorMessage: String? = null
        @Volatile var notImplemented = false

        override fun success(result: Any?) {
            value = result
            latch.countDown()
        }

        // `errorCode` is `@NonNull` in the current Flutter embedding, so the
        // override must take a non-null `code`.
        override fun error(code: String, message: String?, details: Any?) {
            errorCode = code
            errorMessage = message
            latch.countDown()
        }

        override fun notImplemented() {
            notImplemented = true
            latch.countDown()
        }
    }

    private fun call(method: String, arguments: Map<String, Any?>): CapturingResult {
        val result = CapturingResult()
        SecureSessionController.onMethodCall(MethodCall(method, arguments), result)
        assertTrue("timed out waiting for $method", result.latch.await(30, TimeUnit.SECONDS))
        return result
    }

    @Suppress("UNCHECKED_CAST")
    private fun callMap(method: String, arguments: Map<String, Any?>): Map<String, Any?> {
        val result = call(method, arguments)
        assertNull("unexpected error ${result.errorCode}: ${result.errorMessage}", result.errorCode)
        return result.value as Map<String, Any?>
    }

    private fun callError(method: String, arguments: Map<String, Any?>): CapturingResult {
        val result = call(method, arguments)
        assertNull("expected an error, got ${result.value}", result.value)
        return result
    }

    private fun createSession(
        initiator: Boolean,
        pinnedRemotePublicKeyHex: String? = null,
        expectedRemoteDeviceId: String? = null,
        deviceId: String = DEVICE_ID,
        displayName: String = LOCAL_NAME,
    ): Int = (callMap(
        "createSession",
        mapOf(
            "initiator" to initiator,
            "deviceId" to deviceId,
            "displayName" to displayName,
            "pinnedRemotePublicKeyHex" to pinnedRemotePublicKeyHex,
            "expectedRemoteDeviceId" to expectedRemoteDeviceId,
        ),
    )["handle"] as Int)

    private fun startHandshake(handle: Int): Map<String, Any?> =
        callMap("startHandshake", mapOf("handle" to handle))

    private fun processHandshake(handle: Int, incoming: ByteArray): Map<String, Any?> =
        callMap(
            "processHandshake",
            mapOf("handle" to handle, "incoming" to incoming),
        )

    private fun statusOf(handle: Int): Map<String, Any?> =
        callMap("getSessionStatus", mapOf("handle" to handle))

    private fun confirm(handle: Int) {
        callMap("confirmPeerIdentity", mapOf("handle" to handle))
    }

    private fun encrypt(handle: Int, plaintext: ByteArray): ByteArray =
        callMap("encrypt", mapOf("handle" to handle, "plaintext" to plaintext))["ciphertext"] as ByteArray

    private fun decrypt(handle: Int, ciphertext: ByteArray): ByteArray =
        callMap("decrypt", mapOf("handle" to handle, "ciphertext" to ciphertext))["plaintext"] as ByteArray

    private fun close(handle: Int): Boolean =
        callMap("closeSession", mapOf("handle" to handle))["closed"] as Boolean

    private fun assertStage(handle: Int, expected: String) {
        assertEquals("session stage for #$handle", expected, statusOf(handle)["stage"])
    }

    /**
     * Drives a complete XX handshake through the bridge.
     *
     * Both roles use the single installed identity (see the class doc): this
     * smoke-tests the JNI path end to end without claiming distinct-device
     * authentication.
     */
    private fun driveHandshake(initiator: Int, responder: Int): Map<*, *> {
        val step1 = startHandshake(initiator)
        val messageOne = step1["outgoing"] as ByteArray
        assertEquals("message 1 is the bare ephemeral", 32, messageOne.size)
        assertEquals(false, step1["finished"])
        assertNull(step1["remoteIdentity"])

        val step2 = processHandshake(responder, messageOne)
        val messageTwo = step2["outgoing"] as ByteArray
        assertTrue("message 2 must carry encrypted material", messageTwo.size > 32)
        assertEquals(false, step2["finished"])

        val step3 = processHandshake(initiator, messageTwo)
        val messageThree = step3["outgoing"] as ByteArray
        assertTrue(messageThree.isNotEmpty())
        assertEquals(true, step3["finished"])
        assertEquals(true, step3["confirmationRequired"])

        val finish = processHandshake(responder, messageThree)
        assertTrue((finish["outgoing"] as ByteArray).isEmpty())
        assertEquals(true, finish["finished"])
        assertEquals(true, finish["confirmationRequired"])
        return finish
    }

    private fun remoteIdentityOf(step: Map<*, *>): Map<*, *> =
        step["remoteIdentity"] as Map<*, *>

    // -------------------------------------------------------------- tests

    @Test
    fun sessionCreationSucceedsAfterIdentityInitialization() {
        val handle = createSession(initiator = true)

        assertTrue("handle must be positive", handle > 0)
        assertEquals(1, SecureSessionController.trackedSessionCount())
        assertStage(handle, SecureSessionController.STAGE_HANDSHAKING)
        val report = statusOf(handle)
        assertNull("no remote key before any handshake", report["remotePublicKeyHex"])
        assertEquals(false, report["remoteIdentityAvailable"])
    }

    @Test
    fun sessionCreationFailsCleanlyWithoutAnInstalledIdentity() {
        NativeIdentityController.reset(context, true)

        val result = callError(
            "createSession",
            mapOf(
                "initiator" to true,
                "deviceId" to DEVICE_ID,
                "displayName" to LOCAL_NAME,
                "pinnedRemotePublicKeyHex" to null,
                "expectedRemoteDeviceId" to null,
            ),
        )
        assertEquals(SecureSessionController.ERROR_NATIVE, result.errorCode)
        assertEquals("no identity is installed", result.errorMessage)
        assertEquals(
            "a failed creation must not leak into the registry",
            0,
            SecureSessionController.trackedSessionCount(),
        )
    }

    @Test
    fun handshakeOperationsAreCallableThroughTheBridge() {
        val initiator = createSession(initiator = true)
        val responder = createSession(initiator = false)

        val step1 = startHandshake(initiator)
        val messageOne = step1["outgoing"] as ByteArray
        assertEquals(32, messageOne.size)
        assertStage(responder, SecureSessionController.STAGE_HANDSHAKING)

        // A responder cannot *start* the handshake, only consume messages.
        val refused = callError("startHandshake", mapOf("handle" to responder))
        assertEquals(SecureSessionController.ERROR_NATIVE, refused.errorCode)
        assertEquals("only the initiator starts the handshake", refused.errorMessage)

        val step2 = processHandshake(responder, messageOne)
        assertTrue((step2["outgoing"] as ByteArray).isNotEmpty())
    }

    @Test
    fun authenticatedRemoteIdentityIsReportedAfterTheHandshake() {
        val initiator = createSession(initiator = true)
        val responder = createSession(initiator = false)

        val finish = driveHandshake(initiator, responder)

        // The responder learns the initiator's identity from message 3; it is
        // bound to the authenticated static key the engine reported.
        val identity = remoteIdentityOf(finish)
        assertEquals(DEVICE_ID, identity["deviceId"])
        assertEquals(LOCAL_NAME, identity["displayName"])
        assertEquals(installedKeyHex(), identity["publicKeyHex"])
        assertEquals(1, identity["protocolVersion"])
        assertEquals(
            SecureSessionController.CAPABILITY_SECURE_TEXT_MASK,
            (identity["capabilities"] as Int) and SecureSessionController.CAPABILITY_SECURE_TEXT_MASK,
        )

        assertStage(initiator, SecureSessionController.STAGE_AWAITING_CONFIRMATION)
        assertStage(responder, SecureSessionController.STAGE_AWAITING_CONFIRMATION)
        assertEquals(true, statusOf(responder)["remoteIdentityAvailable"])
        assertEquals(installedKeyHex(), statusOf(responder)["remotePublicKeyHex"])
    }

    @Test
    fun pinnedKeyMismatchFailsClosedAndCannotBeConfirmed() {
        val wrongPin = "11".repeat(32)
        assertNotEquals(installedKeyHex(), wrongPin)

        val initiator = createSession(initiator = true, pinnedRemotePublicKeyHex = wrongPin)
        val responder = createSession(initiator = false)

        val step1 = startHandshake(initiator)
        val step2 = processHandshake(responder, step1["outgoing"] as ByteArray)

        // The pin check fires when the initiator authenticates the responder's
        // static key inside message 2: the fixed engine error surfaces here.
        val pinFailure = callError(
            "processHandshake",
            mapOf("handle" to initiator, "incoming" to step2["outgoing"] as ByteArray),
        )
        assertEquals(SecureSessionController.ERROR_NATIVE, pinFailure.errorCode)
        assertEquals(
            "remote static key does not match the pinned key",
            pinFailure.errorMessage,
        )

        // The mismatched session is poisoned: no confirmation, no transport.
        assertStage(initiator, SecureSessionController.STAGE_FAILED)
        val confirmFailure = callError("confirmPeerIdentity", mapOf("handle" to initiator))
        assertEquals("session has failed", confirmFailure.errorMessage)
        val encryptFailure = callError(
            "encrypt",
            mapOf("handle" to initiator, "plaintext" to ByteArray(4)),
        )
        assertEquals("session has failed", encryptFailure.errorMessage)
    }

    @Test
    fun explicitConfirmationIsRequiredBeforeTransport() {
        val initiator = createSession(initiator = true)
        val responder = createSession(initiator = false)
        driveHandshake(initiator, responder)

        // Confirming mid-handshake is refused as well.
        val early = createSession(initiator = true)
        val earlyConfirm = callError("confirmPeerIdentity", mapOf("handle" to early))
        assertEquals("session is not awaiting confirmation", earlyConfirm.errorMessage)
        close(early)

        val encryptResult = callError(
            "encrypt",
            mapOf("handle" to initiator, "plaintext" to "blocked".toByteArray()),
        )
        assertEquals(SecureSessionController.ERROR_NATIVE, encryptResult.errorCode)
        assertEquals("session confirmation required", encryptResult.errorMessage)

        val decryptResult = callError(
            "decrypt",
            mapOf("handle" to responder, "ciphertext" to ByteArray(32)),
        )
        assertEquals("session confirmation required", decryptResult.errorMessage)

        // Confirming one side unlocks only that side.
        confirm(initiator)
        assertStage(initiator, SecureSessionController.STAGE_READY)
        val stillLocked = callError(
            "decrypt",
            mapOf("handle" to responder, "ciphertext" to ByteArray(32)),
        )
        assertEquals("session confirmation required", stillLocked.errorMessage)
    }

    @Test
    fun encryptedPayloadRoundTripWorksThroughTheBridge() {
        val initiator = createSession(initiator = true)
        val responder = createSession(initiator = false)
        driveHandshake(initiator, responder)
        confirm(initiator)
        confirm(responder)

        val plaintext = "ping over the bridge".toByteArray()
        val ciphertext = encrypt(initiator, plaintext)
        assertEquals(
            "ciphertext must add exactly the 16-byte tag",
            plaintext.size + SecureSessionController.AUTHENTICATION_TAG_BYTES,
            ciphertext.size,
        )
        assertArrayEquals(plaintext, decrypt(responder, ciphertext))

        // Multi-byte UTF-8 in the reverse direction.
        val reply = "pong \u2603".toByteArray()
        val replyCiphertext = encrypt(responder, reply)
        assertArrayEquals(reply, decrypt(initiator, replyCiphertext))
    }

    @Test
    fun tamperedCiphertextFailsAndTheSessionBecomesUnusable() {
        val initiator = createSession(initiator = true)
        val responder = createSession(initiator = false)
        driveHandshake(initiator, responder)
        confirm(initiator)
        confirm(responder)

        val ciphertext = encrypt(initiator, "authenticated payload".toByteArray())
        val tampered = ciphertext.copyOf()
        tampered[0] = (tampered[0].toInt() xor 0x01).toByte()

        val failed = callError(
            "decrypt",
            mapOf("handle" to responder, "ciphertext" to tampered),
        )
        assertEquals(SecureSessionController.ERROR_NATIVE, failed.errorCode)
        assertEquals("transport message authentication failed", failed.errorMessage)

        // The poisoned session refuses everything until it is closed.
        assertStage(responder, SecureSessionController.STAGE_FAILED)
        val reuse = callError("decrypt", mapOf("handle" to responder, "ciphertext" to ciphertext))
        assertEquals("session has failed", reuse.errorMessage)
        val send = callError(
            "encrypt",
            mapOf("handle" to responder, "plaintext" to ByteArray(3)),
        )
        assertEquals("session has failed", send.errorMessage)

        // The untampered sender side is unaffected.
        assertStage(initiator, SecureSessionController.STAGE_READY)
    }

    @Test
    fun unknownAndClosedHandlesAreRejected() {
        // A handle that was never issued.
        val unknown = callError("getSessionStatus", mapOf("handle" to 424_242))
        assertEquals(SecureSessionController.ERROR_NATIVE, unknown.errorCode)
        assertEquals("session is closed or unknown", unknown.errorMessage)

        // A real session, closed once — then every operation on it is
        // rejected with the same fixed engine error.
        val handle = createSession(initiator = true)
        assertTrue(close(handle))
        assertEquals(0, SecureSessionController.trackedSessionCount())

        assertFalse("second close is a no-op", close(handle))

        val status = callError("getSessionStatus", mapOf("handle" to handle))
        assertEquals("session is closed or unknown", status.errorMessage)
        val handshake = callError("startHandshake", mapOf("handle" to handle))
        assertEquals("session is closed or unknown", handshake.errorMessage)
        val confirmFailure = callError("confirmPeerIdentity", mapOf("handle" to handle))
        assertEquals("session is closed or unknown", confirmFailure.errorMessage)
        val encryptFailure = callError(
            "encrypt",
            mapOf("handle" to handle, "plaintext" to ByteArray(4)),
        )
        assertEquals("session is closed or unknown", encryptFailure.errorMessage)
    }

    @Test
    fun closingASessionReleasesItsRegistrySlot() {
        // Fill the engine's four-slot session registry.
        val sessions = (0 until 4).map { createSession(initiator = it % 2 == 0) }
        assertEquals(4, SecureSessionController.trackedSessionCount())

        val overflow = callError(
            "createSession",
            mapOf(
                "initiator" to true,
                "deviceId" to DEVICE_ID,
                "displayName" to LOCAL_NAME,
                "pinnedRemotePublicKeyHex" to null,
                "expectedRemoteDeviceId" to null,
            ),
        )
        assertEquals(SecureSessionController.ERROR_NATIVE, overflow.errorCode)
        assertEquals("too many active sessions", overflow.errorMessage)
        assertEquals(4, SecureSessionController.trackedSessionCount())

        // Closing one session frees exactly one slot for a replacement.
        assertTrue(close(sessions[1]))
        val replacement = createSession(initiator = false)
        assertTrue("replacement session must be creatable", replacement > 0)
        assertEquals(4, SecureSessionController.trackedSessionCount())
    }

    @Test
    fun concurrentSessionsDoNotExchangeState() {
        val initiatorA = createSession(initiator = true)
        val responderA = createSession(initiator = false)
        val initiatorB = createSession(initiator = true)
        val responderB = createSession(initiator = false)

        // Two independent handshakes, interleaved step by step.
        val msgA1 = startHandshake(initiatorA)["outgoing"] as ByteArray
        val msgB1 = startHandshake(initiatorB)["outgoing"] as ByteArray
        val msgA2 = processHandshake(responderA, msgA1)["outgoing"] as ByteArray
        val msgB2 = processHandshake(responderB, msgB1)["outgoing"] as ByteArray
        val msgA3 = processHandshake(initiatorA, msgA2)["outgoing"] as ByteArray
        val msgB3 = processHandshake(initiatorB, msgB2)["outgoing"] as ByteArray
        processHandshake(responderA, msgA3)
        processHandshake(responderB, msgB3)

        confirm(initiatorA)
        confirm(responderA)
        confirm(initiatorB)
        confirm(responderB)

        // Each pair completes its own transport round trip.
        val payloadA = "pair A payload".toByteArray()
        assertArrayEquals(
            payloadA,
            decrypt(responderA, encrypt(initiatorA, payloadA)),
        )
        val payloadB = "pair B payload".toByteArray()
        assertArrayEquals(
            payloadB,
            decrypt(responderB, encrypt(initiatorB, payloadB)),
        )

        // A ciphertext produced inside pair A authenticates only inside pair
        // A: pair B's independent session keys reject it. This is the
        // cross-session isolation guarantee of the Noise transport.
        val crossPair = encrypt(initiatorA, "does not belong to pair B".toByteArray())
        val rejected = callError(
            "decrypt",
            mapOf("handle" to responderB, "ciphertext" to crossPair),
        )
        assertEquals(SecureSessionController.ERROR_NATIVE, rejected.errorCode)
        assertEquals("transport message authentication failed", rejected.errorMessage)

        // The failed cross-decrypt poisoned only pair B's receiver; pair A
        // and pair B's sending side are untouched. Pair A still round trips
        // in the reverse direction, whose Noise nonce sequence is intact
        // (transport counters are strictly ordered per sending session).
        assertStage(responderB, SecureSessionController.STAGE_FAILED)
        assertStage(initiatorA, SecureSessionController.STAGE_READY)
        val stillAlive = "pair A still alive".toByteArray()
        assertArrayEquals(
            stillAlive,
            decrypt(initiatorA, encrypt(responderA, stillAlive)),
        )
    }

    @Test
    fun malformedAndOversizedHandshakeInputIsRejected() {
        // Oversized input never crosses JNI: the channel contract rejects it
        // first, and the target session is untouched.
        val oversizedTarget = createSession(initiator = false)
        val oversized = callError(
            "processHandshake",
            mapOf("handle" to oversizedTarget, "incoming" to ByteArray(2000)),
        )
        assertEquals(SecureSessionController.ERROR_INVALID_ARGUMENT, oversized.errorCode)
        assertTrue(
            "fixed validation message expected, got ${oversized.errorMessage}",
            oversized.errorMessage!!.contains("incoming"),
        )
        assertStage(oversizedTarget, SecureSessionController.STAGE_HANDSHAKING)

        // Empty input reaches the engine and gets its fixed error.
        val emptyTarget = createSession(initiator = false)
        val empty = callError(
            "processHandshake",
            mapOf("handle" to emptyTarget, "incoming" to ByteArray(0)),
        )
        assertEquals(SecureSessionController.ERROR_NATIVE, empty.errorCode)
        assertEquals("handshake message is empty", empty.errorMessage)

        // Ten zero bytes cannot be a Noise message; the engine rejects the
        // parse and, by design, poisons the session that saw protocol
        // garbage.
        val garbageTarget = createSession(initiator = false)
        val garbage = callError(
            "processHandshake",
            mapOf("handle" to garbageTarget, "incoming" to ByteArray(10)),
        )
        assertEquals(SecureSessionController.ERROR_NATIVE, garbage.errorCode)
        assertEquals("handshake message rejected", garbage.errorMessage)
        assertStage(garbageTarget, SecureSessionController.STAGE_FAILED)
    }

    @Test
    fun errorsAndResultsNeverContainPrivateKeyMaterial() {
        // Recover the installed private seed only inside this test, through
        // the on-device store — the session surface never exposes it.
        val seed = store.unwrapPersisted(installedKeyHex())
        try {
            assertEquals(32, seed.size)
            val seedHex = seed.joinToString("") { "%02x".format(it) }
            val strings = mutableListOf<String>()
            val arrays = mutableListOf<ByteArray>()

            // Collects every string and byte array reachable from a result
            // map, including nested identity maps.
            fun record(value: Any?) {
                when (value) {
                    null -> Unit
                    is String -> strings += value
                    is ByteArray -> arrays += value
                    is Map<*, *> -> value.values.forEach { record(it) }
                    else -> Unit
                }
            }

            val initiator = createSession(initiator = true)
            val responder = createSession(initiator = false)

            val step1 = startHandshake(initiator)
            record(step1)
            val messageOne = step1["outgoing"] as ByteArray

            val step2 = processHandshake(responder, messageOne)
            record(step2)
            val messageTwo = step2["outgoing"] as ByteArray

            val step3 = processHandshake(initiator, messageTwo)
            record(step3)
            val messageThree = step3["outgoing"] as ByteArray

            record(processHandshake(responder, messageThree))
            confirm(initiator)
            confirm(responder)
            record(statusOf(initiator))
            record(statusOf(responder))
            arrays += encrypt(initiator, "sealed payload".toByteArray())

            // Fixed engine errors are string literals; none of them may carry
            // the seed either.
            val unknownHandle = callError("getSessionStatus", mapOf("handle" to 999_999))
            unknownHandle.errorCode?.let { strings += it }
            unknownHandle.errorMessage?.let { strings += it }

            val wrongPinInitiator = createSession(
                initiator = true,
                pinnedRemotePublicKeyHex = "11".repeat(32),
            )
            val wrongPinResponder = createSession(initiator = false)
            val wrongPinStep1 = startHandshake(wrongPinInitiator)
            record(wrongPinStep1)
            val wrongPinStep2 = processHandshake(
                wrongPinResponder,
                wrongPinStep1["outgoing"] as ByteArray,
            )
            record(wrongPinStep2)
            val pinFailure = callError(
                "processHandshake",
                mapOf(
                    "handle" to wrongPinInitiator,
                    "incoming" to wrongPinStep2["outgoing"] as ByteArray,
                ),
            )
            pinFailure.errorCode?.let { strings += it }
            pinFailure.errorMessage?.let { strings += it }

            for (value in strings) {
                assertFalse(
                    "result text must not contain the private seed",
                    value.contains(seedHex, ignoreCase = true),
                )
            }
            for (array in arrays) {
                assertFalse(
                    "no returned array may equal the private seed",
                    array.contentEquals(seed),
                )
            }
        } finally {
            seed.fill(0)
        }
    }

    @Test
    fun existingIdentityLifecycleRemainsIntactAfterSessionUse() {
        val keyBefore = installedKeyHex()

        // Use the session surface end to end...
        val initiator = createSession(initiator = true)
        val responder = createSession(initiator = false)
        driveHandshake(initiator, responder)
        confirm(initiator)
        confirm(responder)
        assertArrayEquals(
            "lifecycle".toByteArray(),
            decrypt(responder, encrypt(initiator, "lifecycle".toByteArray())),
        )
        assertTrue(close(initiator))
        assertTrue(close(responder))

        // ...then every identity API behaves exactly as before.
        assertEquals(keyBefore, installedKeyHex())
        val status = NativeIdentityController.initialize(context)
        assertEquals(NativeIdentityController.STATE_READY, status.state)
        assertEquals(keyBefore, status.publicKeyHex)

        val cleared = NativeIdentityController.reset(context, true)
        assertEquals(NativeIdentityController.STATE_UNINITIALIZED, cleared.state)
        assertEquals(0, SecureSessionController.trackedSessionCount())

        // After a reset, session creation fails closed with the fixed error.
        val refused = callError(
            "createSession",
            mapOf(
                "initiator" to true,
                "deviceId" to DEVICE_ID,
                "displayName" to LOCAL_NAME,
                "pinnedRemotePublicKeyHex" to null,
                "expectedRemoteDeviceId" to null,
            ),
        )
        assertEquals(SecureSessionController.ERROR_NATIVE, refused.errorCode)
        assertEquals("no identity is installed", refused.errorMessage)

        // Re-provisioning restores a working session surface (the reset
        // deleted the old blob, so this installs a fresh identity).
        assertEquals(NativeIdentityController.STATE_READY, initializeIdentity().state)
        assertTrue(createSession(initiator = true) > 0)
    }

    @Test
    fun invalidChannelArgumentsAreRejectedBeforeNative() {
        fun invalidSession(overrides: Map<String, Any?>): CapturingResult {
            val arguments = mutableMapOf<String, Any?>(
                "initiator" to true,
                "deviceId" to DEVICE_ID,
                "displayName" to LOCAL_NAME,
                "pinnedRemotePublicKeyHex" to null,
                "expectedRemoteDeviceId" to null,
            )
            arguments.putAll(overrides)
            val result = callError("createSession", arguments)
            assertEquals(SecureSessionController.ERROR_INVALID_ARGUMENT, result.errorCode)
            return result
        }

        assertTrue(
            invalidSession(mapOf("deviceId" to "   ")).errorMessage!!.contains("deviceId"),
        )
        assertTrue(
            invalidSession(mapOf("deviceId" to "a".repeat(129)))
                .errorMessage!!.contains("deviceId"),
        )
        assertTrue(
            invalidSession(mapOf("displayName" to "n".repeat(65)))
                .errorMessage!!.contains("displayName"),
        )
        assertTrue(
            invalidSession(mapOf("pinnedRemotePublicKeyHex" to "zz".repeat(32)))
                .errorMessage!!.contains("pinnedRemotePublicKeyHex"),
        )
        assertTrue(
            invalidSession(mapOf("pinnedRemotePublicKeyHex" to "abc"))
                .errorMessage!!.contains("pinnedRemotePublicKeyHex"),
        )
        assertTrue(
            invalidSession(mapOf("deviceId" to null)).errorMessage!!.contains("deviceId"),
        )

        // Transport-size limits are enforced on the channel contract too.
        val handle = createSession(initiator = true)
        val oversizePlaintext = callError(
            "encrypt",
            mapOf(
                "handle" to handle,
                "plaintext" to ByteArray(SecureSessionController.MAX_TRANSPORT_PLAINTEXT_BYTES + 1),
            ),
        )
        assertEquals(SecureSessionController.ERROR_INVALID_ARGUMENT, oversizePlaintext.errorCode)
        assertTrue(oversizePlaintext.errorMessage!!.contains("plaintext"))

        val oversizeHandshake = callError(
            "processHandshake",
            mapOf(
                "handle" to handle,
                "incoming" to ByteArray(SecureSessionController.MAX_HANDSHAKE_MESSAGE_BYTES + 1),
            ),
        )
        assertEquals(SecureSessionController.ERROR_INVALID_ARGUMENT, oversizeHandshake.errorCode)

        // Ciphertext must at least carry the authentication tag.
        val shortCiphertext = callError(
            "decrypt",
            mapOf("handle" to handle, "ciphertext" to ByteArray(8)),
        )
        assertEquals(SecureSessionController.ERROR_INVALID_ARGUMENT, shortCiphertext.errorCode)
        assertTrue(shortCiphertext.errorMessage!!.contains("ciphertext"))

        // Handles are validated before any native call.
        for (badHandle in listOf(0, -1)) {
            val result = callError("getSessionStatus", mapOf("handle" to badHandle))
            assertEquals(SecureSessionController.ERROR_INVALID_ARGUMENT, result.errorCode)
            assertTrue(result.errorMessage!!.contains("handle"))
        }
        val missing = callError("closeSession", mapOf<String, Any?>())
        assertEquals(SecureSessionController.ERROR_INVALID_ARGUMENT, missing.errorCode)

        // Unknown methods are never dispatched to the executor at all.
        val unknownMethod = call("toggleQuantumMode", mapOf<String, Any?>())
        assertTrue(unknownMethod.notImplemented)
        assertNull(unknownMethod.value)

        // None of the rejected calls created or poisoned a session.
        assertEquals(1, SecureSessionController.trackedSessionCount())
        assertStage(handle, SecureSessionController.STAGE_HANDSHAKING)
    }

    @Test
    fun closeAllSessionsCleansUpTrackedLifecycle() {
        val first = createSession(initiator = true)
        val second = createSession(initiator = false)
        assertEquals(2, SecureSessionController.trackedSessionCount())

        SecureSessionController.closeAllSessions()
        assertEquals(0, SecureSessionController.trackedSessionCount())

        // Every cleaned-up handle is dead, and re-closing is a no-op.
        val firstAfter = callError("getSessionStatus", mapOf("handle" to first))
        assertEquals("session is closed or unknown", firstAfter.errorMessage)
        val secondAfter = callError("getSessionStatus", mapOf("handle" to second))
        assertEquals("session is closed or unknown", secondAfter.errorMessage)

        val reclosed = call("closeSession", mapOf("handle" to first))
        assertNull(reclosed.errorCode)
        assertEquals(false, (reclosed.value as Map<*, *>)["closed"])
    }

    private companion object {
        // Stable, non-secret test identity fields. Both Noise roles share the
        // single installed identity (see the class doc): these values only
        // feed the engine's authenticated identity payload.
        const val DEVICE_ID = "3f1d9a80-3f1e-4a2c-9d6b-8e5f2c7a1b40"
        const val LOCAL_NAME = "BeChat Bridge Test"
    }
}
