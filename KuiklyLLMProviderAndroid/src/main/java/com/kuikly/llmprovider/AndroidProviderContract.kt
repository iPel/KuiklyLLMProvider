package com.kuikly.llmprovider

/**
 * Android artifact's own copy of the service management contract.
 * KuiklyLLMProviderAndroid is published standalone and does not depend on the
 * KMP module, so it must not reference LLMProviderContract.
 * Values must stay in sync with KuiklyLLMProvider/.../LLMProviderContract.kt.
 */
object AndroidProviderContract {
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

    // 0 = 不指定，由系统分配随机端口；实际地址一律从 native baseUrl 取。
    const val DEFAULT_PORT = 0

    const val ACTION_DOWNLOAD = "download"
    const val ACTION_PAUSE = "pause"
    const val ACTION_RESUME = "resume"
    const val ACTION_CANCEL = "cancel"
    const val ACTION_SELECT = "select"
    const val ACTION_DELETE = "delete"

    // snapshot() 的 state 取值：与 iOS 侧 kLPMState* 常量保持一致。
    const val STATE_DOWNLOADING = "downloading"
    const val STATE_PAUSED = "paused"
    const val STATE_READY = "ready"
    const val STATE_ACTIVE = "active"
    const val STATE_NOT_AVAILABLE = "not_available"
}
