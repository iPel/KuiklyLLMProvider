package com.example.kuiklyllmprovider

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.tencent.kuikly.core.nvi.serialization.json.JSONArray
import com.tencent.kuikly.core.nvi.serialization.json.JSONObject
import com.tencent.kuikly.core.module.Module

/** 数据模型、JSON 解析与纯文本工具。 */

// 颜色、字号与尺寸统一取自 DesignTokens.kt

/** Demo-local view model; parsed from the provider's JSON snapshot (protocol only). */
internal data class ModelUi(
    val id: String, val name: String, val bytes: Long, val state: String,
    val downloaded: Long, val total: Long, val active: Boolean,
    val bundled: Boolean, val actions: List<String>,
)

internal fun parseModels(json: String): List<ModelUi> {
    if (json.isBlank()) return emptyList()
    return try {
        val arr = JSONObject(json).optJSONArray("models") ?: JSONArray()
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val acts = o.optJSONArray("actions") ?: JSONArray()
            ModelUi(
                id = o.optString("id", ""), name = o.optString("name", ""),
                bytes = o.optLong("bytes", 0), state = o.optString("state", ""),
                downloaded = o.optLong("downloaded", 0), total = o.optLong("total", 0),
                active = o.optBoolean("active", false), bundled = o.optBoolean("bundled", false),
                actions = (0 until acts.length()).map { acts.optString(it, "") ?: "" },
            )
        }
    } catch (e: Exception) { emptyList() }
}

/** 演示页使用的消息结构；role/content 对应 OpenAI 的 messages 字段。 */
internal data class ChatTurn(
    val role: String,
    val content: String,
    val reasoning: String = "",
    val expanded: Boolean = false,
) {
    companion object {
        fun user(text: String) = ChatTurn("user", text)
        fun assistant(text: String = "") = ChatTurn("assistant", text)
    }
}

internal val Suggestions = listOf(
    "用一句话介绍你自己",
    "解释一下什么是端侧大模型",
    "帮我写一段 Kotlin 冒泡排序",
)


/** 备用标题：直接用第一条用户问题，压缩空白并截断。 */
internal fun titleFromQuestion(question: String): String {
    val clean = question.replace(Regex("[\r\n\t]+"), " ").trim()
    return if (clean.length <= 16) clean else clean.take(16) + "…"
}

/** 校验模型生成的候选标题；不合格时改用问题截断。 */
internal fun cleanTitle(candidate: String, question: String): String {
    val text = candidate.trim()
        .trim('「', '」', '"', '\'', '“', '”', '。', '，', '.', ',', ':', '：')
        .replace(Regex("[\r\n\t]+"), " ")
        .trim()
    val usable = text.isNotEmpty() && text.length <= 20 &&
        !text.contains("[") && !text.contains("]") &&
        !text.startsWith("我是") && !text.startsWith("以下是") &&
        !text.startsWith("作为一个")
    return if (usable) text else titleFromQuestion(question)
}

internal fun shortModelName(name: String): String = name.substringBefore(" ").ifBlank { name }

internal fun modelActionLabel(action: String): String = when (action) {
    "download" -> "下载"
    "pause" -> "暂停"
    "resume" -> "续传"
    "cancel" -> "取消"
    "delete" -> "删除"
    else -> action
}
