package com.example.kuiklyllmprovider.module

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import android.widget.Toast
import com.tencent.kuikly.core.render.android.export.KuiklyRenderBaseModule
import com.tencent.kuikly.core.render.android.export.KuiklyRenderCallback
import com.example.kuiklyllmprovider.KRApplication
import com.example.kuiklyllmprovider.KuiklyRenderActivity
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date

class KRBridgeModule : KuiklyRenderBaseModule() {

    override fun call(method: String, params: String?, callback: KuiklyRenderCallback?): Any? {
        return when (method) {
            "closePage" -> activity?.finish()
            "openPage" -> {
                val paramJSON = JSONObject(params ?: "{}")
                val pageName = paramJSON.optString("pageName", paramJSON.optString("url", ""))
                val pageData = paramJSON.optJSONObject("pageData") ?: JSONObject()
                val ctx = activity ?: KRApplication.application
                KuiklyRenderActivity.start(ctx, pageName, pageData)
            }
            "toast" -> {
                val paramJSON = JSONObject(params ?: "{}")
                Toast.makeText(KRApplication.application, paramJSON.optString("content"), Toast.LENGTH_SHORT).show()
            }
            "log" -> {
                val paramJSON = JSONObject(params ?: "{}")
                Log.i("KuiklyRender", paramJSON.optString("content"))
            }
            "copyToPasteboard" -> {
                val paramJSON = JSONObject(params ?: "{}")
                val content = paramJSON.optString("content")
                val clipboard = KRApplication.application.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("kuikly", content))
            }
            "currentTimestamp" -> (System.currentTimeMillis()).toString()
            "dateFormatter" -> {
                val paramJSON = JSONObject(params ?: "{}")
                val data = Date(paramJSON.optLong("timeStamp"))
                SimpleDateFormat(paramJSON.optString("format")).format(data)
            }
            else -> callback?.invoke(mapOf("code" to -1, "message" to "Method not found"))
        }
    }

    companion object {
        const val MODULE_NAME = "HRBridgeModule"
    }
}
