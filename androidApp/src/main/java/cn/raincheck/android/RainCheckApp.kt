package cn.raincheck.android

import android.app.Application
import android.util.Log
import cn.raincheck.android.data.EncryptedAccountStore
import cn.raincheck.android.data.FallbackProfile
import cn.raincheck.core.LoginService
import cn.raincheck.core.ProtocolProfile
import cn.raincheck.core.RainCheckApi
import cn.raincheck.core.SignInEngine

/**
 * 进程级单例容器：协议配置、HTTP 客户端、登录服务、Keystore 加密账号仓库。
 *
 * 网络客户端随进程存活，Activity 配置变更或切后台时不关闭，
 * 配合 `ViewModel` + `viewModelScope` 保证签到协程稳定执行完并实时回填会话。
 */
class RainCheckApp : Application() {

    lateinit var profile: ProtocolProfile
        private set
    lateinit var api: RainCheckApi
        private set
    lateinit var loginService: LoginService
        private set
    lateinit var accountStore: EncryptedAccountStore
        private set

    /** assets 里的协议配置解析失败、退回内置完整配置时为 true。 */
    var usedFallbackProfile: Boolean = false
        private set

    override fun onCreate() {
        super.onCreate()
        instanceRef = this
        accountStore = EncryptedAccountStore(this)
        profile = loadProfile()
        api = RainCheckApi(profile)
        loginService = LoginService(api, profile)
        Log.i(
            TAG,
            "profile=${profile.name} editions=${profile.editions.size} endpoints=${profile.endpoints.size} " +
                "strategies=${profile.strategies.size} fallback=$usedFallbackProfile",
        )
    }

    /** 构造绑定当前进程账号池回填回调的签到引擎（严格保留原有 enabled 状态）。 */
    fun engineWith(log: (String) -> Unit): SignInEngine = SignInEngine(
        api = api,
        profile = profile,
        onAccountUpdated = { updated -> accountStore.updateSessionPreservingEnabled(updated) },
        log = log,
    )

    private fun loadProfile(): ProtocolProfile {
        val parsed = runCatching {
            assets.open(ASSET_PROFILE).bufferedReader().use { it.readText() }
        }.mapCatching { ProtocolProfile.parse(it) }
        return parsed.getOrElse { error ->
            Log.w(TAG, "读取 assets/$ASSET_PROFILE 失败，退回内置完整配置", error)
            usedFallbackProfile = true
            FallbackProfile.build()
        }
    }

    companion object {
        private const val TAG = "RainCheckApp"
        private const val ASSET_PROFILE = "protocol_profile.json"

        private var instanceRef: RainCheckApp? = null

        fun get(): RainCheckApp = requireNotNull(instanceRef) { "RainCheckApp 尚未初始化" }

        fun getOrNull(): RainCheckApp? = instanceRef
    }
}
