package com.example.kuiklyllmprovider

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import com.tencent.kuikly.core.render.android.IKuiklyRenderExport
import com.tencent.kuikly.core.render.android.adapter.KuiklyRenderAdapterManager
import com.tencent.kuikly.core.render.android.css.ktx.toMap
import com.tencent.kuikly.core.render.android.expand.KuiklyRenderViewBaseDelegatorDelegate
import com.tencent.kuikly.core.render.android.expand.KuiklyRenderViewBaseDelegator
import com.example.kuiklyllmprovider.adapter.KRFontAdapter
import com.example.kuiklyllmprovider.adapter.KRImageAdapter
import com.example.kuiklyllmprovider.adapter.KRLogAdapter
import com.example.kuiklyllmprovider.adapter.KRRouterAdapter
import com.example.kuiklyllmprovider.adapter.KRThreadAdapter
import com.example.kuiklyllmprovider.adapter.KRUncaughtExceptionHandlerAdapter
import com.example.kuiklyllmprovider.module.KRBridgeModule
import com.example.kuiklyllmprovider.module.KRShareModule
import com.kuikly.llmprovider.AndroidProviderContract
import com.kuikly.llmprovider.KRLLMProviderModule
import org.json.JSONException
import org.json.JSONObject

class KuiklyRenderActivity : AppCompatActivity(), KuiklyRenderViewBaseDelegatorDelegate {

    private lateinit var hrContainerView: ViewGroup
    private lateinit var loadingView: View
    private lateinit var errorView: View

    private val kuiklyRenderViewDelegator = KuiklyRenderViewBaseDelegator(this)

    // exported LAUNCHER Activity 读取外部 Intent extras 时按白名单校验。
    private val pageName: String
        get() {
            val pn = intent.getStringExtra(KEY_PAGE_NAME) ?: ""
            return if (pn in ALLOWED_PAGES) pn else DEFAULT_PAGE
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_hr)
        setupImmersiveMode()
        hrContainerView = findViewById(R.id.hr_container)
        loadingView = findViewById(R.id.hr_loading)
        errorView = findViewById(R.id.hr_error)
        kuiklyRenderViewDelegator.onAttach(hrContainerView, "", pageName, createPageData())
    }

    override fun onDestroy() {
        super.onDestroy()
        // 进程级本地服务由宿主 Application 统一管理，Pager 销毁不停止服务；
        // 这里只 detach 渲染视图，页面轮询/在途请求取消由 KMP 层生命周期钩子处理。
        kuiklyRenderViewDelegator.onDetach()
    }

    override fun onPause() {
        super.onPause()
        kuiklyRenderViewDelegator.onPause()
    }

    override fun onResume() {
        super.onResume()
        kuiklyRenderViewDelegator.onResume()
    }

    override fun registerExternalModule(kuiklyRenderExport: IKuiklyRenderExport) {
        super.registerExternalModule(kuiklyRenderExport)
        with(kuiklyRenderExport) {
            moduleExport(KRBridgeModule.MODULE_NAME) { KRBridgeModule() }
            moduleExport(KRShareModule.MODULE_NAME) { KRShareModule() }
            // 扩展原生 API：注册名必须与跨端 Module.moduleName() 一致
            // （见 KuiklyUI/docs/DevGuide/expand-native-api.md）
            moduleExport(AndroidProviderContract.MODULE_NAME) { KRLLMProviderModule() }
        }
    }

    override fun registerExternalRenderView(kuiklyRenderExport: IKuiklyRenderExport) {
        super.registerExternalRenderView(kuiklyRenderExport)
    }

    private fun createPageData(): Map<String, Any> {
        val param = argsToMap()
        param["appId"] = 1
        return param
    }

    /** 外部 Intent 的 pageData 一律不信任，仅接受本应用内部 start() 携带的合法数据。 */
    private fun argsToMap(): MutableMap<String, Any> {
        // 来源校验：exported Activity 被外部/启动器拉起时不带内部标记，忽略其 pageData。
        if (!intent.getBooleanExtra(KEY_INTERNAL, false)) return mutableMapOf()
        val jsonStr = intent.getStringExtra(KEY_PAGE_DATA) ?: return mutableMapOf()
        if (jsonStr.length > MAX_PAGE_DATA_LEN) return mutableMapOf()
        return try {
            val parsed = JSONObject(jsonStr).toMap()
            // 键名清洗：限制长度并排除控制字符，避免注入异常键；非法 JSON 也不会导致崩溃。
            parsed.filterKeys { it.length <= MAX_KEY_LEN && it.all { c -> c >= ' ' } }
                .toMutableMap()
        } catch (e: JSONException) {
            mutableMapOf()
        } catch (e: Exception) {
            mutableMapOf()
        }
    }

    private fun setupImmersiveMode() {
        window?.apply {
            addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
            statusBarColor = Color.TRANSPARENT
            // 全屏绘制：页面内容画到状态栏下面，由页面按 safeAreaInsets.top 自行让位，
            // 见 shared/.../LLMChatPage.kt 的「状态栏避让」。
            decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            // 浅色顶部导航栏下，状态栏图标使用深色以保证可读性。
            // 底部导航区同样是浅色，两种系统栏内容都保持深色。
            WindowCompat.getInsetsController(this, decorView)?.apply {
                isAppearanceLightStatusBars = true
                isAppearanceLightNavigationBars = true
            }
        }
    }

    companion object {
        private const val KEY_PAGE_NAME = "pageName"
        private const val KEY_PAGE_DATA = "pageData"
        // 仅本应用内部 start() 会置此标记，用于区分外部冷启动。
        private const val KEY_INTERNAL = "com.example.kuiklyllmprovider.INTERNAL"
        private const val DEFAULT_PAGE = "LLMChat"
        private val ALLOWED_PAGES = setOf("LLMChat")
        private const val MAX_PAGE_DATA_LEN = 64 * 1024
        private const val MAX_KEY_LEN = 64

        init {
            initKuiklyAdapter()
        }

        fun start(context: Context, pageName: String, pageData: JSONObject) {
            val starter = Intent(context, KuiklyRenderActivity::class.java)
            starter.putExtra(KEY_PAGE_NAME, pageName)
            starter.putExtra(KEY_PAGE_DATA, pageData.toString())
            starter.putExtra(KEY_INTERNAL, true)
            context.startActivity(starter)
        }

        private fun initKuiklyAdapter() {
            with(KuiklyRenderAdapterManager) {
                krImageAdapter = KRImageAdapter(KRApplication.application)
                krLogAdapter = KRLogAdapter
                krUncaughtExceptionHandlerAdapter = KRUncaughtExceptionHandlerAdapter
                krFontAdapter = KRFontAdapter
                krRouterAdapter = KRRouterAdapter
                krThreadAdapter = KRThreadAdapter()
            }
        }
    }
}
