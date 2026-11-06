package com.example.kuiklyllmprovider.base

import com.tencent.kuikly.core.base.toInt
import com.tencent.kuikly.core.module.CallbackFn
import com.tencent.kuikly.core.module.Module
import com.tencent.kuikly.core.nvi.serialization.json.JSONArray
import com.tencent.kuikly.core.nvi.serialization.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

internal class BridgeModule : Module() {

    override fun moduleName(): String {
        return MODULE_NAME
    }

    fun closePage() {
        callNativeMethod(CLOSE_PAGE, null, null)
    }

    fun log(content: String) {
        val methodArgs = JSONObject()
        methodArgs.put("content", content)
        callNativeMethod(LOG, methodArgs, null)
    }

    fun toast(content: String) {
        val methodArgs = JSONObject()
        methodArgs.put("content", content)
        callNativeMethod("toast", methodArgs, null)
    }

    fun openPage(url: String, closeCurPage: Boolean = false, closeSamePage: Boolean = false, userData: JSONObject? = null, callbackFn: CallbackFn? = null) {
        val methodArgs = JSONObject()
        methodArgs.put("url", url)
        methodArgs.put("closeCurPage", closeCurPage.toInt())
        methodArgs.put("closeSamePage", closeSamePage.toInt())
        userData?.also {
            methodArgs.put("userData", it)
        }
        callNativeMethod(OPEN_PAGE, methodArgs, callbackFn)
    }

    suspend fun ssoRequest(cmd: String, reqParams: JSONObject): JSONObject? {
        return suspendCoroutine<JSONObject?> { continuation ->
            ssoRequest(cmd, reqParams) {
                continuation.resume(it)
            }
        }
    }

    fun ssoRequest(cmd: String, reqParams: JSONObject, responseCallbackFn: CallbackFn) {
        val methodArgs = JSONObject()
        methodArgs.put("cmd", cmd)
        methodArgs.put("reqParam", reqParams)
        callNativeMethod(SSO_REQUEST, methodArgs, responseCallbackFn)
    }

    fun currentTimeStamp(): Long {
        val timestamp = syncCallNativeMethod(CURRENT_TIMESTAMP, null, null)
        return if (timestamp.isNotEmpty()) timestamp.toLong() else 0
    }

    fun dateFormatter(timeStamp: Long, format: String): String {
        val params = JSONObject()
        params.put("timeStamp", timeStamp)
        params.put("format", format)
        return syncCallNativeMethod(DATE_FORMATTER, params, null)
    }

    private fun callNativeMethod(methodName: String, data: JSONObject?, callbackFn: CallbackFn?) {
        toNative(false, methodName, data?.toString(), callbackFn, false)
    }

    private fun syncCallNativeMethod(methodName: String, data: JSONObject?, callbackFn: CallbackFn?): String {
        return toNative(false, methodName, data?.toString(), callbackFn, true).toString()
    }

    companion object {
        const val MODULE_NAME = "HRBridgeModule"
        const val OPEN_PAGE = "openPage"
        const val CLOSE_PAGE = "closePage"
        const val LOG = "log"
        const val SSO_REQUEST = "ssoRequest"
        const val CURRENT_TIMESTAMP = "currentTimestamp"
        const val DATE_FORMATTER = "dateFormatter"
    }
}
