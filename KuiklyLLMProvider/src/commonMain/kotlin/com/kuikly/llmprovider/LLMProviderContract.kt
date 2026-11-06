package com.kuikly.llmprovider

/**
 * 三端契约常量的唯一来源。原生实现各持副本：
 * AndroidProviderContract.kt、KRLLMProviderModule.mm、KRLLMProviderModule.ets。
 */
internal object LLMProviderContract {
    const val MODULE_NAME = "KRLLMProviderModule"

    const val METHOD_START = "startServer"
    const val METHOD_STOP = "stopServer"
    const val METHOD_STATUS = "serverStatus"
    const val METHOD_MODELS = "models"
    const val METHOD_MODEL_ACTION = "modelAction"

    const val KEY_PORT = "port"
    const val KEY_MODEL_ID = "modelId"
    const val KEY_ACTION = "action"
    const val KEY_DATA = "data"

    const val KEY_OK = "ok"
    const val KEY_RUNNING = "running"
    const val KEY_BASE_URL = "baseUrl"
    const val KEY_API_KEY = "apiKey"
    const val KEY_MESSAGE = "message"

    // 0 = 系统分配端口；实际地址从 startServer 回调或 status 取。
    const val DEFAULT_PORT = 0

    const val ACTION_DOWNLOAD = "download"
    const val ACTION_PAUSE = "pause"
    const val ACTION_RESUME = "resume"
    const val ACTION_CANCEL = "cancel"
    const val ACTION_SELECT = "select"
    const val ACTION_DELETE = "delete"
}
