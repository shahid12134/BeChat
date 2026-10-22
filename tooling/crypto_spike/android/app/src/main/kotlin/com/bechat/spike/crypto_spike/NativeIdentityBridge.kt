package com.bechat.spike.crypto_spike

object NativeIdentityBridge {
    init {
        System.loadLibrary("bechat_crypto_spike")
    }

    external fun nativeGenerateSeed(): ByteArray?

    external fun nativePublicKeyForSeed(seed: ByteArray): String?

    external fun nativeInstallSeed(seed: ByteArray, expectedPublicKeyHex: String): Boolean

    external fun nativeClearInstalledIdentity(): Boolean

    external fun nativeInstalledPublicKeyHex(): String?
}
