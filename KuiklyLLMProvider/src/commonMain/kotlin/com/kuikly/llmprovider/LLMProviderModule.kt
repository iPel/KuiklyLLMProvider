package com.kuikly.llmprovider

import com.tencent.kuikly.core.module.CallbackFn
import com.tencent.kuikly.core.module.Module
import com.tencent.kuikly.core.nvi.serialization.json.JSONObject

/** 本库唯一的公共 API；注册与进程级服务启停由宿主协调层负责。 */
class LLMProviderModule : Module() {

    override fun moduleName(): String = MODULE_NAME

    // 回调在同一 Pager 线程派发，无需 atomic。
    private var active = true

    val isActive: Boolean get() = active

    /** Pager 销毁时调用。 */
    fun dispose() {
        active = false
    }

    private fun guarded(callback: CallbackFn?): CallbackFn? = callback?.let { fn ->
        { result -> if (active) fn(result) }
    }

    private fun call(method: String, args: JSONObject?, callback: CallbackFn?) {
        // keepCallbackAlive=false：回调一次即销毁；syncCall=false：不阻塞 Kuikly 线程
        toNative(false, method, args?.toString(), guarded(callback), false)
    }

    private fun jsonOf(result: Any?): JSONObject = when (result) {
        is JSONObject -> result
        is String -> try {
            JSONObject(result)
        } catch (e: Exception) {
            JSONObject()
        }
        else -> JSONObject()
    }

    private fun dataOf(result: Any?): String {
        if (result == null) return EMPTY_MODELS
        val j = result as? JSONObject ?: return result.toString()
        return j.optString(LLMProviderContract.KEY_DATA, EMPTY_MODELS)
    }

    fun startServer(
        config: ProviderConfig = ProviderConfig(),
        callback: (ok: Boolean, baseUrl: String, apiKey: String, message: String) -> Unit,
    ) {
        val args = JSONObject().apply { put(LLMProviderContract.KEY_PORT, config.port) }
        call(LLMProviderContract.METHOD_START, args) { result ->
            val j = jsonOf(result)
            callback(
                j.optBoolean(LLMProviderContract.KEY_OK, false),
                j.optString(LLMProviderContract.KEY_BASE_URL, ""),
                j.optString(LLMProviderContract.KEY_API_KEY, ""),
                j.optString(LLMProviderContract.KEY_MESSAGE, ""),
            )
        }
    }

    fun stopServer(callback: (ok: Boolean, message: String) -> Unit) {
        call(LLMProviderContract.METHOD_STOP, null) { result ->
            val j = jsonOf(result)
            callback(
                j.optBoolean(LLMProviderContract.KEY_OK, false),
                j.optString(LLMProviderContract.KEY_MESSAGE, ""),
            )
        }
    }

    fun status(callback: (running: Boolean, baseUrl: String, apiKey: String) -> Unit) {
        call(LLMProviderContract.METHOD_STATUS, null) { result ->
            val j = jsonOf(result)
            callback(
                j.optBoolean(LLMProviderContract.KEY_RUNNING, false),
                j.optString(LLMProviderContract.KEY_BASE_URL, ""),
                j.optString(LLMProviderContract.KEY_API_KEY, ""),
            )
        }
    }

    /** 模型快照 JSON 字符串。 */
    fun models(callback: (String) -> Unit) {
        call(LLMProviderContract.METHOD_MODELS, null) { result -> callback(dataOf(result)) }
    }

    fun modelAction(action: String, modelId: String, callback: (String) -> Unit) {
        val args = JSONObject().apply {
            put(LLMProviderContract.KEY_ACTION, action)
            put(LLMProviderContract.KEY_MODEL_ID, modelId)
        }
        call(LLMProviderContract.METHOD_MODEL_ACTION, args) { result -> callback(dataOf(result)) }
    }

    companion object {
        const val MODULE_NAME = LLMProviderContract.MODULE_NAME

        private const val EMPTY_MODELS = "{\"models\":[]}"
    }
}
