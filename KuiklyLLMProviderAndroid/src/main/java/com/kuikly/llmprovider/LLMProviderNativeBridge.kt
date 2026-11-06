package com.kuikly.llmprovider

object LLMProviderNativeBridge {

    /** .so 缺失时安静降级，不让 App 启动即崩溃。 */
    val available: Boolean by lazy {
        try {
            System.loadLibrary("llm_provider")
            true
        } catch (e: UnsatisfiedLinkError) {
            false
        } catch (e: SecurityException) {
            false
        }
    }

    private external fun nativeStart(port: Int, modelPath: String, modelId: String): Int
    private external fun nativeStop()
    private external fun nativeLoadModel(modelPath: String, modelId: String): Int
    private external fun nativeIsRunning(): Boolean
    private external fun nativeBaseUrl(): String
    private external fun nativeApiKey(): String
    private external fun nativeModelId(): String
    private external fun nativeLastError(): String

    fun start(port: Int, modelPath: String, modelId: String): Int =
        if (available) nativeStart(port, modelPath, modelId) else 0

    fun stop() {
        if (available) nativeStop()
    }

    fun loadModel(modelPath: String, modelId: String): Int =
        if (available) nativeLoadModel(modelPath, modelId) else 0

    fun isRunning(): Boolean = available && nativeIsRunning()

    fun baseUrl(): String =
        if (available) nativeBaseUrl() else ""

    fun apiKey(): String = if (available) nativeApiKey() else ""

    /** 引擎当前实际加载的模型 id；未加载时为空串。 */
    fun modelId(): String = if (available) nativeModelId() else ""

    fun lastError(): String = if (available) nativeLastError() else ""
}
