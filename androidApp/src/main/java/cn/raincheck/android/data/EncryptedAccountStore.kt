package cn.raincheck.android.data

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import cn.raincheck.core.Account
import cn.raincheck.core.AccountRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 基于 Android Keystore (AES-256-GCM) 与原子文件替换的加密账号仓库。
 *
 * 安全设计：
 * - 密钥由 AndroidKeyStore 硬件/TEE 托管，永不落盘明文；
 * - 密文存于内部私有目录 `files/secure/accounts.enc`，并排除在云备份与 D2D 迁移之外；
 * - 全部读写与回填均在同一把 `lock` 下通过临时文件 + `fsync` + 原子重命名完成；
 * - 解析或解密失败时保留损坏备份文件并通过 [storageError] 上报，绝不静默清空用户账号；
 * - 首次启动自动迁移旧版明文 `raincheck.accounts` SharedPreferences 并彻底擦除旧明文。
 */
class EncryptedAccountStore(context: Context) : AccountRepository {

    private val appContext = context.applicationContext
    private val secureDir = File(appContext.filesDir, SECURE_DIR)
    private val storeFile = File(secureDir, STORE_FILE_NAME)

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        explicitNulls = false
        encodeDefaults = true
    }

    private val serializer = ListSerializer(Account.serializer())
    private val lock = Any()

    private val _accounts = MutableStateFlow<List<Account>>(emptyList())
    val accountsFlow: StateFlow<List<Account>> = _accounts.asStateFlow()

    private val _storageError = MutableStateFlow<String?>(null)
    val storageError: StateFlow<String?> = _storageError.asStateFlow()

    init {
        synchronized(lock) {
            migrateLegacyPlaintextIfNeededLocked()
            _accounts.value = readLocked()
        }
    }

    override fun load(): List<Account> = synchronized(lock) {
        val loaded = readLocked()
        _accounts.value = loaded
        loaded
    }

    override fun save(accounts: List<Account>) {
        synchronized(lock) {
            writeLocked(accounts)
            _accounts.value = accounts
            _storageError.value = null
        }
    }

    override fun upsert(account: Account) {
        synchronized(lock) {
            val list = readLocked().toMutableList()
            val index = list.indexOfFirst { it.id == account.id }
            if (index >= 0) list[index] = account else list.add(account)
            writeLocked(list)
            _accounts.value = list
            _storageError.value = null
        }
    }

    override fun remove(id: String) {
        synchronized(lock) {
            val next = readLocked().filterNot { it.id == id }
            writeLocked(next)
            _accounts.value = next
            _storageError.value = null
        }
    }

    /**
     * 引擎后台回填会话凭据时使用：
     * 1) 若账号在并发期间已被用户删除，绝不“复活”该账号；
     * 2) 严格保留账号库中原有的 [Account.enabled] 状态，防止指定账号/重试时误将禁用账号永久启用。
     */
    fun updateSessionPreservingEnabled(updated: Account) {
        synchronized(lock) {
            val list = readLocked().toMutableList()
            val index = list.indexOfFirst { it.id == updated.id }
            if (index < 0) return
            val existing = list[index]
            val merged = existing.copy(
                label = updated.label.takeIf { it.isNotBlank() } ?: existing.label,
                bearer = updated.bearer ?: existing.bearer,
                sessionId = updated.sessionId ?: existing.sessionId,
                csrfToken = updated.csrfToken ?: existing.csrfToken,
                lastOkAt = updated.lastOkAt ?: existing.lastOkAt,
                userId = updated.userId ?: existing.userId,
                enabled = existing.enabled,
            )
            if (merged == existing) return
            list[index] = merged
            writeLocked(list)
            _accounts.value = list
        }
    }

    fun dismissStorageError() {
        _storageError.value = null
    }

    // ------------------------------------------------------------------ 内部实现（调用方须持锁）

    private fun migrateLegacyPlaintextIfNeededLocked() {
        val legacyPrefs = appContext.getSharedPreferences(LEGACY_PREF_NAME, Context.MODE_PRIVATE)
        val raw = legacyPrefs.getString(LEGACY_KEY_ACCOUNTS, null)
        if (raw.isNullOrBlank()) {
            // 若旧文件残留但无内容，安全清理
            if (legacyPrefs.all.isNotEmpty()) clearLegacyPrefs(legacyPrefs)
            return
        }
        if (storeFile.exists() && storeFile.length() > 0L) {
            // 已有新加密库时，仅擦除残留旧明文，避免凭据长期明文留存
            clearLegacyPrefs(legacyPrefs)
            return
        }
        runCatching {
            val accounts = json.decodeFromString(serializer, raw)
            if (accounts.isNotEmpty()) {
                writeLocked(accounts)
                Log.i(TAG, "已将 ${accounts.size} 个旧版明文账号迁移至 Keystore AES-GCM 加密库")
            }
            clearLegacyPrefs(legacyPrefs)
        }.onFailure { err ->
            Log.e(TAG, "迁移旧版明文账号失败，保留旧数据避免丢失", err)
            _storageError.value = "旧版账号迁移失败：${err.message ?: err.javaClass.simpleName}"
        }
    }

    private fun clearLegacyPrefs(prefs: android.content.SharedPreferences) {
        prefs.edit().clear().commit()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            runCatching { appContext.deleteSharedPreferences(LEGACY_PREF_NAME) }
        }
    }

    private fun readLocked(): List<Account> {
        if (!storeFile.exists()) return emptyList()
        return runCatching {
            val payload = storeFile.readBytes()
            if (payload.isEmpty()) return emptyList()
            val plaintext = decrypt(payload)
            json.decodeFromString(serializer, plaintext.toString(Charsets.UTF_8))
        }.getOrElse { error ->
            val backupName = preserveCorruptedFileLocked()
            Log.e(TAG, "读取加密账号库失败，已备份至 $backupName", error)
            _storageError.value = buildString {
                append("加密账号库读取失败（")
                append(error.message ?: error.javaClass.simpleName)
                append("）")
                if (backupName != null) {
                    append("，原文件已保留备份：")
                    append(backupName)
                }
            }
            emptyList()
        }
    }

    private fun writeLocked(accounts: List<Account>) {
        if (!secureDir.exists() && !secureDir.mkdirs()) {
            throw IllegalStateException("无法创建安全存储目录：${secureDir.absolutePath}")
        }
        val plaintext = json.encodeToString(serializer, accounts).toByteArray(Charsets.UTF_8)
        val encrypted = encrypt(plaintext)

        val tmpFile = File(secureDir, "$STORE_FILE_NAME.tmp")
        FileOutputStream(tmpFile).use { fos ->
            fos.write(encrypted)
            fos.flush()
            runCatching { fos.fd.sync() }
        }
        if (!tmpFile.renameTo(storeFile)) {
            // 部分文件系统不支持覆盖 rename，先删除再重命名，最后兜底字节写入
            if (storeFile.exists()) storeFile.delete()
            if (!tmpFile.renameTo(storeFile)) {
                tmpFile.copyTo(storeFile, overwrite = true)
                tmpFile.delete()
            }
        }
    }

    private fun preserveCorruptedFileLocked(): String? {
        if (!storeFile.exists()) return null
        return runCatching {
            val backup = File(secureDir, "$STORE_FILE_NAME.corrupted.${System.currentTimeMillis()}")
            storeFile.copyTo(backup, overwrite = true)
            backup.name
        }.getOrNull()
    }

    private fun getOrCreateKey(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        val existing = ks.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing

        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()

        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER).run {
            init(spec)
            generateKey()
        }
    }

    private fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val iv = cipher.iv
        require(iv.isNotEmpty() && iv.size <= 255) { "异常的 GCM IV 长度：${iv.size}" }
        val ciphertext = cipher.doFinal(plaintext)
        val out = ByteArray(2 + iv.size + ciphertext.size)
        out[0] = FORMAT_VERSION
        out[1] = iv.size.toByte()
        System.arraycopy(iv, 0, out, 2, iv.size)
        System.arraycopy(ciphertext, 0, out, 2 + iv.size, ciphertext.size)
        return out
    }

    private fun decrypt(payload: ByteArray): ByteArray {
        require(payload.size > 16) { "密文文件长度异常" }
        val version = payload[0]
        require(version == FORMAT_VERSION) { "不支持的加密存储版本：$version" }
        val ivLen = payload[1].toInt() and 0xFF
        require(ivLen in 12..32 && payload.size > 2 + ivLen + 16) { "密文头损坏" }
        val iv = payload.copyOfRange(2, 2 + ivLen)
        val ciphertext = payload.copyOfRange(2 + ivLen, payload.size)

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return cipher.doFinal(ciphertext)
    }

    companion object {
        private const val TAG = "EncryptedAccountStore"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_ALIAS = "cn.raincheck.android.accounts.aes256gcm.v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val FORMAT_VERSION: Byte = 1
        private const val GCM_TAG_BITS = 128

        private const val SECURE_DIR = "secure"
        private const val STORE_FILE_NAME = "accounts.enc"

        private const val LEGACY_PREF_NAME = "raincheck.accounts"
        private const val LEGACY_KEY_ACCOUNTS = "accounts.v1"
    }
}
