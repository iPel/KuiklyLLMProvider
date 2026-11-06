package com.kuikly.llmprovider

import android.os.Handler
import android.os.Looper
import com.tencent.kuikly.core.render.android.export.KuiklyRenderBaseModule
import com.tencent.kuikly.core.render.android.export.KuiklyRenderCallback
import org.json.JSONObject
import java.util.concurrent.Executors

/** Android implementation of the KuiklyLLMProvider extension Module. */
class KRLLMProviderModule : KuiklyRenderBaseModule() {

    companion object {
        /**
         * 进程级单线程队列：所有改变 native 服务状态的操作（start / stop / select / delete）
         * 按调用顺序串行生效，且不占用调用线程。
         * stop 可能要等在途生成或模型加载释放 native 锁，同步执行会阻塞 UI 线程。
         * 服务是进程级资源，因此队列跨 Module 实例共享。
         */
        private val serviceQueue = Executors.newSingleThreadExecutor { r ->
            Thread(r, "provider-service").apply { isDaemon = true }
        }

        /** 其余后台任务（models 轮询的 snapshot 文件 IO、下载类动作）复用线程，避免每次新建 Thread。 */
        private val ioPool = Executors.newCachedThreadPool { r ->
            Thread(r, "provider-module").apply { isDaemon = true }
        }

        private val SUPPORTED_ACTIONS = setOf(
            AndroidProviderContract.ACTION_DOWNLOAD, AndroidProviderContract.ACTION_RESUME,
            AndroidProviderContract.ACTION_PAUSE, AndroidProviderContract.ACTION_CANCEL,
            AndroidProviderContract.ACTION_SELECT, AndroidProviderContract.ACTION_DELETE,
        )
    }

    override fun call(method: String, params: String?, callback: KuiklyRenderCallback?): Any? {
        return when (method) {
            AndroidProviderContract.METHOD_STOP -> {
                serviceQueue.execute {
                    LLMProviderNativeBridge.stop()
                    ModelStore.onServiceStopped()
                    reply(callback, statusPayload(true, "服务已停止"))
                }
                null
            }
            AndroidProviderContract.METHOD_STATUS -> {
                // ok 统一表示「调用是否成功」，运行状态由 running 单独表达。
                reply(callback, statusPayload(true, ""))
                null
            }
            else -> {
                // ModelStore 的方法统一检查 context，未 attach 时返回 ok=false。
                withStore(callback) { s ->
                    when (method) {
                        AndroidProviderContract.METHOD_START -> start(params, callback, s)
                        AndroidProviderContract.METHOD_MODELS ->
                            // snapshot 含文件 IO，挪到后台线程避免阻塞调用线程。
                            background { reply(callback, dataPayload(s.snapshot())) }
                        AndroidProviderContract.METHOD_MODEL_ACTION -> action(params, callback, s)
                        else -> reply(callback, errorPayload("unknown method: $method"))
                    }
                }
                null
            }
        }
    }

    /** Module 未 attach 时返回结构化错误，不使用强制解包。 */
    private fun withStore(callback: KuiklyRenderCallback?, block: (ModelStore) -> Unit) {
        val ctx = context
        if (ctx == null) {
            reply(callback, errorPayload("module not attached"))
            return
        }
        block(ModelStore.instance(ctx))
    }

    private fun start(params: String?, callback: KuiklyRenderCallback?, s: ModelStore) {
        val json = parse(params)
        val port = json.optInt(AndroidProviderContract.KEY_PORT, AndroidProviderContract.DEFAULT_PORT)
        serviceQueue.execute {
            s.ensureBundled()   // bundled variant only: merge parts without showing progress
            val first = s.firstReady()
            val modelPath = first?.let { s.path(it).absolutePath } ?: ""
            val modelId = first?.id ?: ""
            val ok = LLMProviderNativeBridge.start(port, modelPath, modelId) == 1
            // 服务已在运行时 start 幂等返回、不会加载 first，以引擎实际加载的模型为准。
            if (ok) s.activeId = LLMProviderNativeBridge.modelId()
            reply(callback, statusPayload(ok,
                if (ok) "服务已启动" else (LLMProviderNativeBridge.lastError().ifEmpty { "启动失败" })))
        }
    }

    private fun action(params: String?, callback: KuiklyRenderCallback?, s: ModelStore) {
        val json = parse(params)
        val action = json.optString(AndroidProviderContract.KEY_ACTION, "")
        val id = json.optString(AndroidProviderContract.KEY_MODEL_ID, "")
        // select 加载模型、delete 可能卸载模型，进服务队列保证与 start / stop 按序生效；
        // 下载类动作不碰 native 服务，不应排在可能长时间等待的 stop 之后。
        val touchesService = action == AndroidProviderContract.ACTION_SELECT ||
            action == AndroidProviderContract.ACTION_DELETE
        val run: (() -> Unit) -> Unit = if (touchesService) { b -> serviceQueue.execute(b) } else ::background
        run {
            val entry = s.entry(id)
            // 非法 modelId、未知 action、删除内置模型一律 ok=false。
            val bundledDelete = action == AndroidProviderContract.ACTION_DELETE && entry?.bundled == true
            var ok = entry != null && !bundledDelete && action in SUPPORTED_ACTIONS
            if (ok) {
                when (action) {
                    AndroidProviderContract.ACTION_DOWNLOAD -> s.download(id, false)
                    AndroidProviderContract.ACTION_RESUME -> s.download(id, true)
                    AndroidProviderContract.ACTION_PAUSE -> s.pause(id)
                    AndroidProviderContract.ACTION_CANCEL -> s.cancel(id)
                    AndroidProviderContract.ACTION_SELECT -> ok = s.select(id)
                    AndroidProviderContract.ACTION_DELETE -> s.delete(id)
                }
            }
            reply(callback, dataPayload(s.snapshot(), ok,
                if (ok) "" else "invalid modelId or action"))
        }
    }

    /** 统一响应构造器，start/stop/status 结构一致，回调载体统一 JSONObject。 */
    private fun statusPayload(ok: Boolean, message: String): JSONObject = JSONObject()
        .put(AndroidProviderContract.KEY_OK, ok)
        .put(AndroidProviderContract.KEY_RUNNING, LLMProviderNativeBridge.isRunning())
        .put(AndroidProviderContract.KEY_BASE_URL, LLMProviderNativeBridge.baseUrl())
        .put(AndroidProviderContract.KEY_API_KEY, LLMProviderNativeBridge.apiKey())
        .put(AndroidProviderContract.KEY_MESSAGE, message)

    private fun dataPayload(snapshot: String, ok: Boolean = true, message: String = ""): JSONObject =
        JSONObject()
            .put(AndroidProviderContract.KEY_OK, ok)
            .put(AndroidProviderContract.KEY_MESSAGE, message)
            .put(AndroidProviderContract.KEY_DATA, snapshot)

    private fun errorPayload(message: String): JSONObject = JSONObject()
        .put(AndroidProviderContract.KEY_OK, false)
        .put(AndroidProviderContract.KEY_MESSAGE, message)
        .put(AndroidProviderContract.KEY_DATA, "{}")

    private fun parse(params: String?) = try {
        JSONObject(params.orEmpty().ifBlank { "{}" })
    } catch (e: Exception) { JSONObject() }

    private fun background(block: () -> Unit) {
        ioPool.execute(block)
    }

    private fun reply(callback: KuiklyRenderCallback?, value: Any?) {
        val cb = callback ?: return
        Handler(Looper.getMainLooper()).post { cb.invoke(value) }
    }
}
