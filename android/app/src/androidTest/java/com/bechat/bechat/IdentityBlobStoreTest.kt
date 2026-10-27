package com.bechat.bechat

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * On-device tests for the production Keystore blob store.
 *
 * These run against the real Android Keystore and the real filesystem, so they
 * cover what JVM unit tests cannot: authenticated wrapping, atomic persistence,
 * envelope validation and the failure states the controller maps to Dart.
 */
class IdentityBlobStoreTest {

    private lateinit var context: Context
    private lateinit var store: IdentityBlobStore

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        store = IdentityBlobStore(context)
        cleanStorage()
    }

    @After
    fun tearDown() {
        cleanStorage()
    }

    private fun cleanStorage() {
        NativeCryptoBridge.nativeClearInstalledIdentity()
        store.deleteBlob()
        store.deleteMetadata()
        runCatching { store.deleteKeystoreKey() }
        store.blobFile.parentFile?.listFiles()?.forEach { it.delete() }
    }

    private fun newSeedAndKey(): Pair<ByteArray, String> {
        val seed = NativeCryptoBridge.nativeGenerateSeed()
        if (seed == null) {
            fail("seed generation failed")
            throw IllegalStateException("seed generation failed")
        }
        val publicKeyHex = NativeCryptoBridge.nativePublicKeyForSeed(seed)
        if (publicKeyHex == null) {
            seed.fill(0)
            fail("public key derivation failed")
            throw IllegalStateException("public key derivation failed")
        }
        return seed to publicKeyHex
    }

    private fun expectStoreFailure(
        description: String,
        expected: Class<out IdentityStoreException>,
        block: () -> Unit,
    ) {
        try {
            block()
            fail("$description: expected ${expected.simpleName}")
        } catch (error: Throwable) {
            assertTrue(
                "$description: expected ${expected.simpleName}, got ${error::class.java.simpleName}",
                expected.isInstance(error),
            )
        }
    }

    private fun blobBytes(): ByteArray = store.blobFile.readBytes()

    private fun mutateBlob(offset: Int, value: Byte) {
        val bytes = blobBytes()
        bytes[offset] = value
        store.blobFile.writeBytes(bytes)
    }

    // ------------------------------------------------------------- happy paths

    @Test
    fun wrapAndPersist_writesProductionEnvelopeAndRoundTrips() {
        val (seed, publicKeyHex) = newSeedAndKey()

        store.wrapAndPersist(seed, publicKeyHex)
        store.writeMetadata(publicKeyHex)

        assertTrue(store.hasBlob())
        assertTrue(store.hasMetadata())

        val blob = blobBytes()
        assertEquals("envelope length", 68, blob.size)
        assertEquals("magic B", 0x42.toByte(), blob[0])
        assertEquals("magic C", 0x43.toByte(), blob[1])
        assertEquals("magic I", 0x49.toByte(), blob[2])
        assertEquals("magic D", 0x44.toByte(), blob[3])
        assertEquals("envelope version", 1, blob[4].toInt())
        assertEquals("algorithm id", 1, blob[5].toInt())
        assertEquals("iv length", 12, blob[6].toInt())
        assertEquals("seed length", 32, blob[7].toInt())

        val recovered = store.unwrapPersisted(publicKeyHex)
        try {
            assertArrayEquals("recovered seed", seed, recovered)
        } finally {
            recovered.fill(0)
            seed.fill(0)
        }

        val metadata = store.readMetadata()
        assertNotNull(metadata)
        assertEquals(publicKeyHex, metadata!!.publicKeyHex)
        assertEquals("noise-x25519-chachapoly-sha256", metadata.algorithm)
        assertTrue(metadata.createdAt.endsWith("Z"))
    }

    @Test
    fun sameSeedWrappedTwiceUsesFreshNonceAndCiphertext() {
        val (seed, publicKeyHex) = newSeedAndKey()

        store.wrapAndPersist(seed, publicKeyHex)
        val first = blobBytes()
        store.wrapAndPersist(seed, publicKeyHex)
        val second = blobBytes()
        seed.fill(0)

        assertFalse("IV/nonce must not be reused", first.copyOfRange(8, 20).contentEquals(second.copyOfRange(8, 20)))
        assertFalse("ciphertext must change with a fresh nonce", first.contentEquals(second))
    }

    @Test
    fun plaintextSeedIsNotPresentInThePersistedEnvelope() {
        val (seed, publicKeyHex) = newSeedAndKey()

        store.wrapAndPersist(seed, publicKeyHex)

        val blob = blobBytes()
        assertFalse("ciphertext must not contain the raw seed", containsSequence(blob, seed))
        seed.fill(0)
    }

    // ------------------------------------------------------- envelope validation

    @Test
    fun unknownVersionIsRejected() {
        val (seed, publicKeyHex) = newSeedAndKey()
        store.wrapAndPersist(seed, publicKeyHex)
        seed.fill(0)

        mutateBlob(4, 2)
        expectStoreFailure("unknown version", BlobUnsupportedException::class.java) {
            store.unwrapPersisted(publicKeyHex)
        }
    }

    @Test
    fun unknownAlgorithmIsRejected() {
        val (seed, publicKeyHex) = newSeedAndKey()
        store.wrapAndPersist(seed, publicKeyHex)
        seed.fill(0)

        mutateBlob(5, 2)
        expectStoreFailure("unknown algorithm", BlobUnsupportedException::class.java) {
            store.unwrapPersisted(publicKeyHex)
        }
    }

    @Test
    fun wrongMagicIsRejected() {
        val (seed, publicKeyHex) = newSeedAndKey()
        store.wrapAndPersist(seed, publicKeyHex)
        seed.fill(0)

        mutateBlob(0, 0x00)
        expectStoreFailure("wrong magic", BlobCorruptException::class.java) {
            store.unwrapPersisted(publicKeyHex)
        }
    }

    @Test
    fun truncatedAndOversizedBlobsAreRejected() {
        val (seed, publicKeyHex) = newSeedAndKey()
        store.wrapAndPersist(seed, publicKeyHex)
        seed.fill(0)

        store.blobFile.writeBytes(blobBytes().copyOfRange(0, 60))
        expectStoreFailure("truncated blob", BlobCorruptException::class.java) {
            store.unwrapPersisted(publicKeyHex)
        }

        val (freshSeed, _) = newSeedAndKey()
        store.wrapAndPersist(freshSeed, publicKeyHex)
        freshSeed.fill(0)
        store.blobFile.writeBytes(blobBytes() + byteArrayOf(0))
        expectStoreFailure("oversized blob", BlobCorruptException::class.java) {
            store.unwrapPersisted(publicKeyHex)
        }
    }

    @Test
    fun invalidDeclaredLengthsAreRejected() {
        val (seed, publicKeyHex) = newSeedAndKey()
        store.wrapAndPersist(seed, publicKeyHex)
        seed.fill(0)

        mutateBlob(6, 8)
        expectStoreFailure("bad iv length", BlobCorruptException::class.java) {
            store.unwrapPersisted(publicKeyHex)
        }

        val (secondSeed, secondKey) = newSeedAndKey()
        store.wrapAndPersist(secondSeed, secondKey)
        secondSeed.fill(0)
        mutateBlob(7, 16)
        expectStoreFailure("bad seed length", BlobCorruptException::class.java) {
            store.unwrapPersisted(secondKey)
        }
    }

    @Test
    fun corruptedCiphertextAndTagFailAuthentication() {
        val (seed, publicKeyHex) = newSeedAndKey()
        store.wrapAndPersist(seed, publicKeyHex)
        seed.fill(0)

        val bytes = blobBytes()
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 0x80).toByte()
        store.blobFile.writeBytes(bytes)

        expectStoreFailure("flipped tag byte", BlobCorruptException::class.java) {
            store.unwrapPersisted(publicKeyHex)
        }
    }

    @Test
    fun expectedPublicKeyIsBoundIntoTheAuthenticatedData() {
        val (seed, publicKeyHex) = newSeedAndKey()
        store.wrapAndPersist(seed, publicKeyHex)
        seed.fill(0)

        val (otherSeed, otherPublicKeyHex) = newSeedAndKey()
        otherSeed.fill(0)

        expectStoreFailure("different public key", BlobCorruptException::class.java) {
            store.unwrapPersisted(otherPublicKeyHex)
        }

        // Replacing the metadata public key cannot make the wrong key decrypt
        // the envelope: the AAD would change and authentication would fail.
        store.writeMetadata(otherPublicKeyHex)
        assertEquals(otherPublicKeyHex, store.readMetadata()!!.publicKeyHex)
        expectStoreFailure("rewritten metadata key", BlobCorruptException::class.java) {
            store.unwrapPersisted(otherPublicKeyHex)
        }
    }

    @Test
    fun missingBlobIsReportedAsBlobMissing() {
        val (seed, publicKeyHex) = newSeedAndKey()
        store.wrapAndPersist(seed, publicKeyHex)
        store.writeMetadata(publicKeyHex)
        seed.fill(0)

        store.deleteBlob()

        expectStoreFailure("missing blob", BlobMissingException::class.java) {
            store.unwrapPersisted(publicKeyHex)
        }
    }

    @Test
    fun missingKeystoreAliasIsReportedAsKeyUnavailable() {
        val (seed, publicKeyHex) = newSeedAndKey()
        store.wrapAndPersist(seed, publicKeyHex)
        seed.fill(0)

        store.deleteKeystoreKey()

        expectStoreFailure("keystore key gone", KeystoreKeyUnavailableException::class.java) {
            store.unwrapPersisted(publicKeyHex)
        }
    }

    // -------------------------------------------------------- metadata validation

    @Test
    fun metadataIsStrictlyValidated() {
        val (seed, publicKeyHex) = newSeedAndKey()
        seed.fill(0)

        expectStoreFailure("invalid public key", MetadataInvalidException::class.java) {
            store.unwrapPersisted("not-hex")
        }

        val valid = listOf(
            "bechat-identity-meta/1",
            "public_key=$publicKeyHex",
            "algorithm=noise-x25519-chachapoly-sha256",
            "created_at=2026-01-01T00:00:00Z",
        ).joinToString("\n") + "\n"

        store.metadataFile.parentFile?.mkdirs()
        store.metadataFile.writeText(valid)
        assertNotNull(store.readMetadata())

        val invalidDocuments = mapOf(
            "garbage" to "not a document\n",
            "wrong header" to valid.replace("bechat-identity-meta/1", "bechat-identity-meta/2"),
            "uppercase key" to valid.replace(publicKeyHex, publicKeyHex.uppercase()),
            "short key" to valid.replace(publicKeyHex, publicKeyHex.dropLast(2)),
            "wrong algorithm" to valid.replace("noise-x25519-chachapoly-sha256", "noise-xx-other"),
            "missing created_at" to valid.lines().dropLast(2).joinToString("\n") + "\n",
            "bad created_at" to valid.replace("2026-01-01T00:00:00Z", "yesterday"),
        )

        for ((description, document) in invalidDocuments) {
            store.metadataFile.writeText(document)
            expectStoreFailure("metadata: $description", MetadataInvalidException::class.java) {
                store.readMetadata()
            }
        }
    }

    @Test
    fun metadataIsWrittenAtomicallyAndReplacesPreviousContent() {
        val (seed, publicKeyHex) = newSeedAndKey()
        seed.fill(0)
        val (otherSeed, otherPublicKeyHex) = newSeedAndKey()
        otherSeed.fill(0)

        store.writeMetadata(publicKeyHex)
        store.writeMetadata(otherPublicKeyHex)

        assertEquals(otherPublicKeyHex, store.readMetadata()!!.publicKeyHex)
        val leftovers = store.metadataFile.parentFile!!.listFiles()!!
            .filter { it.name.endsWith(".tmp") }
        assertTrue("no temporary metadata file may remain", leftovers.isEmpty())
    }

    // ---------------------------------------------------- persistence failures

    @Test
    fun persistenceFailureIsWrappedAndLeavesNoIdentityBehind() {
        val (seed, publicKeyHex) = newSeedAndKey()
        val tempBlob = File(store.blobFile.parentFile, "identity.blob.tmp")

        // A directory where the temporary file belongs makes the write fail.
        tempBlob.delete()
        assertTrue(tempBlob.mkdirs())

        try {
            expectStoreFailure("unwritable destination", IdentityStoreException::class.java) {
                store.wrapAndPersist(seed, publicKeyHex)
            }
            assertFalse("no envelope may be left behind", store.hasBlob())
        } finally {
            tempBlob.delete()
            seed.fill(0)
        }

        // With the obstruction removed a fresh attempt succeeds.
        val (retrySeed, retryKey) = newSeedAndKey()
        store.wrapAndPersist(retrySeed, retryKey)
        retrySeed.fill(0)
        assertTrue(store.hasBlob())
    }

    // ------------------------------------------------------------- seed storage

    @Test
    fun plaintextSeedIsNotWrittenToSqlitePreferencesOrOrdinaryFiles() {
        val (seed, publicKeyHex) = newSeedAndKey()
        store.wrapAndPersist(seed, publicKeyHex)
        store.writeMetadata(publicKeyHex)

        val scanned = mutableListOf<String>()
        try {
            val roots = listOf(context.noBackupFilesDir, context.filesDir, context.dataDir)
            for (root in roots.filter { it.isDirectory }) {
                for (file in root.walkTopDown().filter { it.isFile }) {
                    if (file.length() > MAX_SCANNED_FILE_BYTES) {
                        continue
                    }
                    scanned.add(file.absolutePath)
                    assertFalse(
                        "plaintext seed found in ${file.absolutePath}",
                        containsSequence(file.readBytes(), seed),
                    )
                }
            }
            assertTrue("the encrypted envelope must have been scanned", scanned.any { it.endsWith("identity.blob") })
        } finally {
            seed.fill(0)
        }
    }

    @Test
    fun seedLengthAndPublicKeyMismatchAreRejectedByTheNativeLayer() {
        val (seed, publicKeyHex) = newSeedAndKey()

        // Invalid seed length never derives a key.
        val shortSeedAccepted = runCatching {
            NativeCryptoBridge.nativePublicKeyForSeed(ByteArray(31))
        }.getOrNull()
        assertEquals(null, shortSeedAccepted)

        // A mismatched expected key is refused and installs nothing.
        val wrongKey = publicKeyHex.map { if (it == 'a') 'b' else 'a' }.joinToString("")
        assertFalse(NativeCryptoBridge.nativeInstallSeed(seed, wrongKey))
        assertEquals(null, NativeCryptoBridge.nativeInstalledPublicKeyHex())

        // The correct pair installs, and a later mismatch must not clobber it.
        assertTrue(NativeCryptoBridge.nativeInstallSeed(seed, publicKeyHex))
        assertEquals(publicKeyHex, NativeCryptoBridge.nativeInstalledPublicKeyHex())
        assertFalse(NativeCryptoBridge.nativeInstallSeed(seed, wrongKey))
        assertEquals(publicKeyHex, NativeCryptoBridge.nativeInstalledPublicKeyHex())

        seed.fill(0)
        NativeCryptoBridge.nativeClearInstalledIdentity()
        assertEquals(null, NativeCryptoBridge.nativeInstalledPublicKeyHex())
    }

    private companion object {
        const val MAX_SCANNED_FILE_BYTES = 8L * 1024L * 1024L

        fun containsSequence(haystack: ByteArray, needle: ByteArray): Boolean {
            if (needle.isEmpty() || haystack.size < needle.size) {
                return false
            }
            outer@ for (start in 0..haystack.size - needle.size) {
                for (offset in needle.indices) {
                    if (haystack[start + offset] != needle[offset]) {
                        continue@outer
                    }
                }
                return true
            }
            return false
        }
    }
}
