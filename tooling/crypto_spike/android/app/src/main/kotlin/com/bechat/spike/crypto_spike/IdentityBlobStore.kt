package com.bechat.spike.crypto_spike

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class IdentityStoreException(message: String) : Exception(message)

class KeystoreKeyUnavailableException(message: String) : Exception(message)

internal fun ByteArray.toLowerHex(): String =
    joinToString(separator = "") { byte ->
        String.format(Locale.US, "%02x", byte.toInt() and 0xff)
    }

internal fun String.lowerHexToBytes(): ByteArray {
    if (length % 2 != 0 || any { it !in '0'..'9' && it !in 'a'..'f' }) {
        throw IdentityStoreException("invalid hex value")
    }
    return ByteArray(length / 2) { index ->
        substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}

internal fun publicKeyFingerprintHex(publicKey: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(publicKey).toLowerHex()

class IdentityBlobStore(private val context: Context) {
    private companion object {
        const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        const val KEY_ALIAS = "bechat_spike_identity_wrap_v1"
        const val PREFERENCES = "bechat_spike_identity_metadata"
        const val PREF_PUBLIC_KEY = "public_key_hex"
        const val PREF_VERSION = "metadata_version"
        const val METADATA_VERSION = 1
        const val BLOB_DIRECTORY = "identity"
        const val BLOB_FILE = "identity_v1.bin"
        const val BLOB_TEMP_FILE = "identity_v1.bin.tmp"
        const val MAGIC_0: Byte = 0x42
        const val MAGIC_1: Byte = 0x43
        const val MAGIC_2: Byte = 0x53
        const val MAGIC_3: Byte = 0x49
        const val BLOB_VERSION = 1
        const val IV_LENGTH = 12
        const val SEED_LENGTH = 32
        const val TAG_LENGTH = 16
        val AAD = byteArrayOf(MAGIC_0, MAGIC_1, MAGIC_2, MAGIC_3, BLOB_VERSION.toByte())
    }

    private val metadata =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    private val noBackupDirectory =
        File(context.noBackupFilesDir, BLOB_DIRECTORY).apply { mkdirs() }

    private val blobFile = File(noBackupDirectory, BLOB_FILE)
    private val tempBlobFile = File(noBackupDirectory, BLOB_TEMP_FILE)

    fun readPublicKeyHex(): String? {
        if (!metadata.contains(PREF_PUBLIC_KEY)) {
            return null
        }
        return metadata.getString(PREF_PUBLIC_KEY, null)
    }

    fun writePublicKeyHex(publicKeyHex: String) {
        if (publicKeyHex.length != SEED_LENGTH * 2) {
            throw IdentityStoreException("invalid public identity length")
        }
        publicKeyHex.lowerHexToBytes()
        val written = metadata.edit()
            .putString(PREF_PUBLIC_KEY, publicKeyHex)
            .putInt(PREF_VERSION, METADATA_VERSION)
            .commit()
        if (!written) {
            throw IdentityStoreException("could not persist identity metadata")
        }
    }

    fun clearPublicKeyHex() {
        metadata.edit().clear().commit()
    }

    fun hasCiphertext(): Boolean = blobFile.isFile && blobFile.length() > 0

    fun hasMetadata(): Boolean = readPublicKeyHex() != null

    fun wrapAndPersist(seed: ByteArray) {
        require(seed.size == SEED_LENGTH) { "invalid identity seed length" }
        val key = getOrCreateKeystoreKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(AAD)
        val ciphertext = cipher.doFinal(seed)
        val iv = cipher.iv
        if (iv.size != IV_LENGTH || ciphertext.size != SEED_LENGTH + TAG_LENGTH) {
            throw IdentityStoreException("invalid encrypted identity output")
        }

        val output = ByteArrayOutputStream()
        output.write(AAD)
        output.write(iv.size)
        output.write(iv)
        output.write(ciphertext)

        val bytes = output.toByteArray()
        try {
            FileOutputStream(tempBlobFile, false).use { stream ->
                stream.write(bytes)
                stream.fd.sync()
            }
            if (!tempBlobFile.renameTo(blobFile)) {
                throw IdentityStoreException("could not persist encrypted identity")
            }
        } finally {
            tempBlobFile.delete()
            bytes.fill(0)
        }
    }

    fun unwrapPersisted(): ByteArray {
        val key = getExistingKeystoreKey()
        val bytes = blobFile.readBytes()
        try {
            if (bytes.size != AAD.size + 1 + IV_LENGTH + SEED_LENGTH + TAG_LENGTH) {
                throw IdentityStoreException("malformed encrypted identity blob")
            }
            if (bytes[0] != MAGIC_0 ||
                bytes[1] != MAGIC_1 ||
                bytes[2] != MAGIC_2 ||
                bytes[3] != MAGIC_3
            ) {
                throw IdentityStoreException("invalid encrypted identity header")
            }
            if ((bytes[4].toInt() and 0xff) != BLOB_VERSION) {
                throw IdentityStoreException("unsupported encrypted identity version")
            }
            val ivLength = bytes[5].toInt() and 0xff
            if (ivLength != IV_LENGTH) {
                throw IdentityStoreException("invalid encrypted identity nonce")
            }

            val ivStart = AAD.size + 1
            val ciphertextStart = ivStart + IV_LENGTH
            val iv = bytes.copyOfRange(ivStart, ciphertextStart)
            val ciphertext = bytes.copyOfRange(ciphertextStart, bytes.size)

            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
            cipher.updateAAD(AAD)
            val seed = cipher.doFinal(ciphertext)
            if (seed.size != SEED_LENGTH) {
                seed.fill(0)
                throw IdentityStoreException("invalid decrypted identity length")
            }
            return seed
        } finally {
            bytes.fill(0)
        }
    }

    fun deleteCiphertext() {
        blobFile.delete()
        tempBlobFile.delete()
    }

    fun corruptCiphertext() {
        if (!hasCiphertext()) {
            throw IdentityStoreException("encrypted identity blob is missing")
        }
        val bytes = blobFile.readBytes()
        try {
            bytes[bytes.lastIndex] = (bytes.last().toInt() xor 0x80).toByte()
            FileOutputStream(blobFile, false).use { stream ->
                stream.write(bytes)
                stream.fd.sync()
            }
        } finally {
            bytes.fill(0)
        }
    }

    fun deleteKeystoreKey() {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER)
        keyStore.load(null)
        if (keyStore.containsAlias(KEY_ALIAS)) {
            keyStore.deleteEntry(KEY_ALIAS)
        }
    }

    private fun getOrCreateKeystoreKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER)
        keyStore.load(null)
        if (!keyStore.containsAlias(KEY_ALIAS)) {
            val generator =
                KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
            generator.init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generator.generateKey()
        }
        return getExistingKeystoreKey()
    }

    private fun getExistingKeystoreKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER)
        keyStore.load(null)
        if (!keyStore.containsAlias(KEY_ALIAS)) {
            throw KeystoreKeyUnavailableException("identity wrapping key is unavailable")
        }
        return keyStore.getKey(KEY_ALIAS, null) as? SecretKey
            ?: throw KeystoreKeyUnavailableException("identity wrapping key is unavailable")
    }
}
