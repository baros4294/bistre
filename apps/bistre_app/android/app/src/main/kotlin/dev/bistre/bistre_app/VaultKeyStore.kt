package dev.bistre.bistre_app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android half of the secret vault (ADR-0010, `SECURITY.md`).
 *
 * A non-exportable AES-256-GCM key in the Android Keystore (StrongBox when the device has one,
 * otherwise TEE) wraps a random 32-byte vault data key. Only the wrapped form is stored, in
 * `noBackupFilesDir` (never part of Auto Backup). The Rust core receives the unwrapped data key
 * through `init_runtime` and seals every vault entry with it; this class never sees API keys.
 */
object VaultKeyStore {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "bistre_vault_kek_v1"
    private const val WRAPPED_FILE = "bistre_vault.key.wrapped"
    private const val FORMAT_VERSION: Byte = 1
    private const val IV_LEN = 12
    private const val TAG_BITS = 128
    private const val DATA_KEY_LEN = 32

    /** Returns the vault data key, creating and wrapping a new one on first use. */
    fun obtainDataKey(context: Context): ByteArray {
        val kek = loadOrCreateKek()
        val file = AtomicFile(File(context.noBackupFilesDir, WRAPPED_FILE))
        val stored = if (file.baseFile.exists()) file.readFully() else null
        if (stored != null) {
            val unwrapped = runCatching { unwrap(kek, stored) }
            if (unwrapped.isSuccess) return unwrapped.getOrThrow()
            // The Keystore key changed (for example after a device restore): keep the old wrapped
            // key for manual recovery and start a new one. The Rust vault then sets its old file
            // aside the same way instead of failing.
            val setAside = file.baseFile.renameTo(
                File(context.noBackupFilesDir, "$WRAPPED_FILE.unreadable-${System.currentTimeMillis()}"),
            )
            if (!setAside) file.delete()
        }
        val dataKey = ByteArray(DATA_KEY_LEN).also { SecureRandom().nextBytes(it) }
        val wrapped = wrap(kek, dataKey)
        val out = file.startWrite()
        try {
            out.write(wrapped)
            file.finishWrite(out)
        } catch (err: Exception) {
            file.failWrite(out)
            throw err
        }
        return dataKey
    }

    private fun loadOrCreateKek(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return try {
            generateKek(strongBox = true)
        } catch (_: StrongBoxUnavailableException) {
            generateKek(strongBox = false)
        }
    }

    private fun generateKek(strongBox: Boolean): SecretKey {
        val spec = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setIsStrongBoxBacked(strongBox)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(spec)
            generateKey()
        }
    }

    private fun wrap(kek: SecretKey, dataKey: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, kek)
        val iv = cipher.iv
        require(iv.size == IV_LEN) { "unexpected GCM IV length" }
        return byteArrayOf(FORMAT_VERSION) + iv + cipher.doFinal(dataKey)
    }

    private fun unwrap(kek: SecretKey, stored: ByteArray): ByteArray {
        require(stored.size > 1 + IV_LEN && stored[0] == FORMAT_VERSION) { "unknown wrapped key format" }
        val iv = stored.copyOfRange(1, 1 + IV_LEN)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, kek, GCMParameterSpec(TAG_BITS, iv))
        val dataKey = cipher.doFinal(stored, 1 + IV_LEN, stored.size - 1 - IV_LEN)
        require(dataKey.size == DATA_KEY_LEN) { "unexpected data key length" }
        return dataKey
    }
}
