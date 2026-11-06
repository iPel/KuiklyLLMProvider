package com.example.kuiklyllmprovider.adapter

import android.content.pm.ApplicationInfo
import android.util.Log
import com.example.kuiklyllmprovider.KRApplication
import com.tencent.kuikly.core.render.android.adapter.IKRLogAdapter

object KRLogAdapter : IKRLogAdapter {
    // 仅 debuggable 构建输出完整日志；release 关闭 i/d，e 级别脱敏后输出。
    private val verbose: Boolean by lazy {
        try {
            (KRApplication.application.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        } catch (e: Exception) {
            false
        }
    }
    private const val MAX_LEN = 512
    // kuikly- 只匹配定长 22 字符 base64url，避免误匹配 @kuikly-open/render 等框架标识。
    private val SECRET = Regex(
        "(?i)(kuikly-[A-Za-z0-9_-]{22}(?![A-Za-z0-9_-])|Bearer\\s+[A-Za-z0-9._-]+|(?:api[_-]?key|token)[\"':=\\s]+[^\\s,;}\"]+)"
    )

    override val asyncLogEnable: Boolean get() = true
    override fun i(tag: String, msg: String) { if (verbose) Log.i(tag, msg) }
    override fun d(tag: String, msg: String) { if (verbose) Log.d(tag, msg) }
    override fun e(tag: String, msg: String) {
        Log.e(tag, if (verbose) msg else redact(msg))
    }

    // 先脱敏再截断：先截断会破坏跨越截断点的 key，使定长匹配失效而泄漏前缀。
    private fun redact(msg: String): String = SECRET.replace(msg, "<redacted>").take(MAX_LEN)
}
