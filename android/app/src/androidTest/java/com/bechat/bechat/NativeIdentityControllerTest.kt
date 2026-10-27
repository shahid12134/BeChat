package com.bechat.bechat

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.security.KeyStore
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * On-device lifecycle tests for [NativeIdentityController].
 *
 * Covers first provisioning, restart/restore stability, concurrent callers,
 * every fail-closed state, explicit reset and interrupted provisioning — using
 * the production classes only, since the app exposes no test-only hooks.
 */
class NativeIdentityControllerTest {

    private lateinit var context: Context
    private lateinit var store: IdentityBlobStore

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        store = IdentityBlobStore(context)
        NativeIdentityController.attach(context)
        NativeIdentityController.reset(context, true)
        NativeIdentityController.forgetCachedStatus()
    }

    @After
    fun tearDown() {
        NativeIdentityController.reset(context, true)
        NativeIdentityController.forgetCachedStatus()
    }

    private fun initialize(): NativeIdentityStatus = NativeIdentityController.initialize(context)

    private fun status(): NativeIdentityStatus = NativeIdentityController.status(context)

    private fun keystoreHasAlias(): Boolean {
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)
        return keyStore.containsAlias("bechat_identity_wrap_v1")
    }

    private fun assertReady(status: NativeIdentityStatus) {
        assertEquals(NativeIdentityController.STATE_READY, status.state)
        assertNotNull(status.publicKeyHex)
        assertEquals(64, status.publicKeyHex!!.length)
        assertTrue(status.publicKeyHex!!.matches(Regex("^[0-9a-f]{64}$")))
        assertEquals(64, status.fingerprintHex?.length)
        assertNull(status.message)
    }

    // ------------------------------------------------------------- provisioning

    @Test
    fun firstInitializeProvisionsAndInstallsAUsableIdentity() {
        val status = initialize()

        assertReady(status)
        assertTrue("encrypted envelope must exist", store.hasBlob())
        assertTrue("public metadata must exist", store.hasMetadata())
        assertEquals(68L, store.blobFile.length())
        assertEquals(status.publicKeyHex, store.readMetadata()!!.publicKeyHex)
        assertEquals(
            "native identity must be installed",
            status.publicKeyHex,
            NativeCryptoBridge.nativeInstalledPublicKeyHex(),
        )

        // The persisted envelope really does recover that identity's seed.
        val recovered = store.unwrapPersisted(status.publicKeyHex!!)
        try {
            assertEquals(32, recovered.size)
            assertEquals(
                status.publicKeyHex,
                NativeCryptoBridge.nativePublicKeyForSeed(recovered),
            )
        } finally {
            recovered.fill(0)
        }
    }

    @Test
    fun repeatedInitializationRestoresTheSameIdentityInsteadOfRegenerating() {
        val first = initialize()
        assertReady(first)

        val second = initialize()
        assertReady(second)
        assertEquals("restart must not rotate the identity", first.publicKeyHex, second.publicKeyHex)

        val reported = status()
        assertReady(reported)
        assertEquals(first.publicKeyHex, reported.publicKeyHex)
    }

    @Test
    fun concurrentInitializationProvisionsExactlyOneIdentity() {
        val pool = Executors.newFixedThreadPool(4)
        try {
            val tasks = (0 until 4).map {
                Callable { NativeIdentityController.initialize(context) }
            }
            val results = pool.invokeAll(tasks, 60, TimeUnit.SECONDS).map { it.get() }

            for (result in results) {
                assertReady(result)
            }
            val distinctKeys = results.mapNotNull { it.publicKeyHex }.toSet()
            assertEquals("all concurrent callers must agree", 1, distinctKeys.size)

            // The stored envelope must still round-trip for that identity.
            val recovered = store.unwrapPersisted(distinctKeys.first())
            recovered.fill(0)
        } finally {
            pool.shutdownNow()
        }
    }

    @Test
    fun statusNeverProvisionsOnAFreshInstallation() {
        val reported = status()

        assertEquals(NativeIdentityController.STATE_UNINITIALIZED, reported.state)
        assertFalse("status must not create an envelope", store.hasBlob())
        assertFalse("status must not create metadata", store.hasMetadata())
        assertFalse("status must not create a Keystore key", keystoreHasAlias())
    }

    // ------------------------------------------------------------ fail-closed

    @Test
    fun corruptedEnvelopeFailsClosedAndIsNeverReplaced() {
        val first = initialize()
        assertReady(first)

        val bytes = store.blobFile.readBytes()
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 0x80).toByte()
        store.blobFile.writeBytes(bytes)
        val corrupted = store.blobFile.readBytes()
        NativeIdentityController.forgetCachedStatus()

        val failed = initialize()
        assertEquals(NativeIdentityController.STATE_BLOB_CORRUPT, failed.state)
        assertEquals(
            "public metadata must survive a corrupt envelope",
            first.publicKeyHex,
            store.readMetadata()!!.publicKeyHex,
        )

        val failedAgain = initialize()
        assertEquals(NativeIdentityController.STATE_BLOB_CORRUPT, failedAgain.state)
        assertNull("a damaged identity exposes no public key", failedAgain.publicKeyHex)
        assertTrue(
            "the damaged envelope must be left as it is, not regenerated",
            corrupted.contentEquals(store.blobFile.readBytes()),
        )
    }

    @Test
    fun missingEnvelopeFailsClosed() {
        initialize()
        store.deleteBlob()
        NativeIdentityController.forgetCachedStatus()

        assertEquals(NativeIdentityController.STATE_BLOB_MISSING, initialize().state)
    }

    @Test
    fun unsupportedEnvelopeVersionFailsClosedDistinctly() {
        initialize()
        val bytes = store.blobFile.readBytes()
        bytes[4] = 2
        store.blobFile.writeBytes(bytes)
        NativeIdentityController.forgetCachedStatus()

        assertEquals(NativeIdentityController.STATE_BLOB_UNSUPPORTED, initialize().state)
    }

    @Test
    fun malformedEnvelopeFailsClosed() {
        initialize()
        store.blobFile.writeBytes(store.blobFile.readBytes().copyOfRange(0, 40))
        NativeIdentityController.forgetCachedStatus()

        assertEquals(NativeIdentityController.STATE_BLOB_CORRUPT, initialize().state)
    }

    @Test
    fun missingKeystoreKeyFailsClosed() {
        initialize()
        store.deleteKeystoreKey()
        NativeIdentityController.forgetCachedStatus()

        assertEquals(NativeIdentityController.STATE_KEY_UNAVAILABLE, initialize().state)
    }

    @Test
    fun inconsistentMetadataFailsClosed() {
        initialize()
        store.metadataFile.writeText("bechat-identity-meta/1\npublic_key=zz\n")
        NativeIdentityController.forgetCachedStatus()

        assertEquals(NativeIdentityController.STATE_METADATA_INVALID, initialize().state)

        // A missing metadata file with an envelope present is also inconsistent.
        store.deleteMetadata()
        NativeIdentityController.forgetCachedStatus()
        assertEquals(NativeIdentityController.STATE_METADATA_INVALID, initialize().state)
    }

    @Test
    fun interruptedProvisioningLeavesAnOrphanEnvelopeThatFailsClosedAndIsNotReplaced() {
        // Simulates a process death between persisting the envelope and writing
        // the metadata: only the encrypted blob exists.
        val seed = NativeCryptoBridge.nativeGenerateSeed()!!
        val publicKeyHex = NativeCryptoBridge.nativePublicKeyForSeed(seed)!!
        store.wrapAndPersist(seed, publicKeyHex)
        seed.fill(0)
        assertFalse(store.hasMetadata())

        val orphanBytes = store.blobFile.readBytes()
        NativeIdentityController.forgetCachedStatus()

        val assessment = status()
        assertEquals(NativeIdentityController.STATE_METADATA_INVALID, assessment.state)
        assertTrue("the orphan envelope must be left untouched", orphanBytes.contentEquals(store.blobFile.readBytes()))

        val initialized = initialize()
        assertEquals(NativeIdentityController.STATE_METADATA_INVALID, initialized.state)
        assertTrue("initialize must not replace the orphan envelope", orphanBytes.contentEquals(store.blobFile.readBytes()))

        // Only an explicit reset clears it, after which provisioning is allowed.
        assertEquals(NativeIdentityController.STATE_UNINITIALIZED, NativeIdentityController.reset(context, true).state)
        NativeIdentityController.forgetCachedStatus()
        assertFalse(store.hasBlob())
        assertReady(initialize())
    }

    @Test
    fun persistenceFailureRollsBackWithoutLeavingPartialState() {
        val tempBlob = File(store.blobFile.parentFile, "identity.blob.tmp")
        tempBlob.delete()
        assertTrue(tempBlob.mkdirs())

        try {
            val failed = initialize()
            assertEquals(NativeIdentityController.STATE_STORE_FAILED, failed.state)
            assertFalse("no envelope may survive a failed provisioning", store.hasBlob())
            assertFalse("no metadata may survive a failed provisioning", store.hasMetadata())
            assertNull(
                "no native identity may survive a failed provisioning",
                NativeCryptoBridge.nativeInstalledPublicKeyHex(),
            )
        } finally {
            tempBlob.delete()
        }

        // Once storage is writable again, provisioning succeeds.
        assertReady(initialize())
    }

    // ------------------------------------------------------------------- reset

    @Test
    fun resetWithoutConfirmationIsRefusedAndChangesNothing() {
        val first = initialize()
        assertReady(first)

        try {
            NativeIdentityController.reset(context, false)
            fail("reset without confirmation must be refused")
        } catch (error: Throwable) {
            assertTrue(error is ResetNotConfirmedException)
        }

        assertEquals(NativeIdentityController.STATE_READY, status().state)
        assertTrue(store.hasBlob())
        assertTrue(store.hasMetadata())
        assertEquals(first.publicKeyHex, NativeCryptoBridge.nativeInstalledPublicKeyHex())
    }

    @Test
    fun resetClearsIdentityAndReinitializationCreatesANewOne() {
        val first = initialize()
        assertReady(first)

        val reset = NativeIdentityController.reset(context, true)

        assertEquals(NativeIdentityController.STATE_UNINITIALIZED, reset.state)
        assertNull(reset.publicKeyHex)
        assertFalse("envelope must be deleted", store.hasBlob())
        assertFalse("metadata must be deleted", store.hasMetadata())
        assertFalse("Keystore alias must be deleted", keystoreHasAlias())
        assertNull(
            "native identity must be cleared",
            NativeCryptoBridge.nativeInstalledPublicKeyHex(),
        )
        assertEquals(NativeIdentityController.STATE_UNINITIALIZED, status().state)

        val second = initialize()
        assertReady(second)
        assertNotEquals(
            "a fresh provisioning after reset must create a new identity",
            first.publicKeyHex,
            second.publicKeyHex,
        )
    }

    // ---------------------------------------------------------- Dart boundary

    @Test
    fun dartFacingStatusContainsOnlyNonSecretFields() {
        val status = initialize()
        assertReady(status)

        val map = status.toMap()
        assertEquals(
            setOf("state", "publicKeyHex", "fingerprintHex", "message"),
            map.keys,
        )
        for ((key, value) in map) {
            assertFalse(
                "Dart-facing field $key must not carry secret material",
                key.contains("private") || key.contains("seed") || key.contains("wrapped"),
            )
            if (value is String) {
                assertFalse(value.contains("private"))
            }
        }

        val failed = NativeIdentityStatus(
            state = NativeIdentityController.STATE_BLOB_CORRUPT,
            message = "Encrypted identity could not be recovered.",
        ).toMap()
        assertNull(failed["publicKeyHex"])
        assertNull(failed["fingerprintHex"])
    }
}
