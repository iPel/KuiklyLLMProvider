package com.example.kuiklyllmprovider

import com.tencent.kuikly.core.module.NetworkModule
import com.tencent.kuikly.core.nvi.serialization.json.JSONArray
import com.tencent.kuikly.core.nvi.serialization.json.JSONObject

private const val MODELS_PATH = "/v1/models"
private const val CHAT_PATH = "/v1/chat/completions"
private const val MAX_LINE_CHARS = 1024 * 1024
private const val INVALID_ENDPOINT = "baseUrl 无效或本地服务未启动"

/**
 * 是否为本机明文端点：解析出 authority 后精确比较 host。
 * 前缀匹配会放行 `http://127.0.0.1.evil.com`；含 userinfo（`http://127.0.0.1@evil.com`）一律拒绝。
 */
internal fun isLocalEndpoint(url: String): Boolean {
    val prefix = "http://"
    val u = url.trim()
    if (!u.startsWith(prefix, ignoreCase = true)) return false
    val authority = u.substring(prefix.length).takeWhile { it != '/' && it != '?' && it != '#' }
    if ('@' in authority) return false
    val host = authority.substringBefore(':')
    return host == "127.0.0.1" || host.equals("localhost", ignoreCase = true)
}

/**
 * 归一化并阻止把本地凭据发往明文外部端点。
 * 端口由系统分配，不使用固定端口；非法 / 空 baseUrl 返回 null，调用方直接失败、不发请求。
 */
private fun endpoint(baseUrl: String, path: String): String? {
    val base = baseUrl.trimEnd('/')
    val allowed = isLocalEndpoint(base) || base.startsWith("https://", ignoreCase = true)
    return if (allowed) base + path else null
}

class ChatCompletionsTransport {

    private fun headers(apiKey: String, stream: Boolean): JSONObject = JSONObject().apply {
        put("Content-Type", "application/json")
        put("Accept", if (stream) "text/event-stream" else "application/json")
        if (apiKey.isNotEmpty() && apiKey.all { it.isLetterOrDigit() || it == '-' || it == '.' || it == '_' })
            put("Authorization", "Bearer $apiKey")
    }

    /** GET /v1/models：返回模型 id 列表文本，供页面展示。 */
    fun listModels(
        network: NetworkModule,
        baseUrl: String,
        apiKey: String,
        callback: (ok: Boolean, text: String) -> Unit,
    ) {
        val url = endpoint(baseUrl, MODELS_PATH) ?: return callback(false, INVALID_ENDPOINT)
        network.httpRequest(
            url = url,
            isPost = false,
            param = JSONObject(),
            headers = headers(apiKey, false),
            cookie = null,
            timeout = 15,
        ) { data, success, errorMsg, _ ->
            if (!success) {
                callback(false, errorMsg.ifEmpty { "GET /v1/models 失败" })
                return@httpRequest
            }
            val body = unwrap(data)
                ?: return@httpRequest callback(false, invalidBodyMessage(data))
            val arr = body.optJSONArray("data")
            val ids = ArrayList<String>()
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    val id = arr.optJSONObject(i)?.optString("id", "") ?: ""
                    if (id.isNotEmpty()) ids.add(id)
                }
            }
            callback(true, if (ids.isEmpty()) "（无模型）" else ids.joinToString(", "))
        }
    }

    /**
     * POST /v1/chat/completions（非流式）。
     *
     * @param body 调用方按 OpenAI 协议构造的请求体（`stream` 应为 false）。
     */
    fun chatOnce(
        network: NetworkModule,
        baseUrl: String,
        apiKey: String,
        body: JSONObject,
        callback: (ok: Boolean, content: String, reasoning: String, finishReason: String, message: String) -> Unit,
    ) {
        val url = endpoint(baseUrl, CHAT_PATH) ?: return callback(false, "", "", "", INVALID_ENDPOINT)
        network.httpRequest(
            url = url,
            isPost = true,
            param = body,
            headers = headers(apiKey, false),
            cookie = null,
            timeout = 120,
        ) { data, success, errorMsg, _ ->
            if (!success) {
                callback(false, "", "", "", errorMsg.ifEmpty { "POST /v1/chat/completions 失败" })
                return@httpRequest
            }
            val body = unwrap(data)
                ?: return@httpRequest callback(false, "", "", "", invalidBodyMessage(data))
            val choice = body.optJSONArray("choices")?.optJSONObject(0)
            val message = choice?.optJSONObject("message")
            callback(
                true,
                message?.optString("content", "") ?: "",
                message?.optString("reasoning_content", "") ?: "",
                choice?.optString("finish_reason", "") ?: "",
                "",
            )
        }
    }

    /**
     * POST /v1/chat/completions（流式 SSE）。
     *
     * 网络分片边界与 SSE 事件边界无关，因此用 [SseLineParser] 按行累积后再解析
     * 每条 `data:` 载荷；`delta.content` 与 `delta.reasoning_content` 分开回调。
     *
     * @return 取消函数：调用后关闭连接，不再产生任何回调。
     */
    fun chatStream(
        network: NetworkModule,
        baseUrl: String,
        apiKey: String,
        body: JSONObject,
        onContent: (String) -> Unit,
        onReasoning: (String) -> Unit,
        onDone: (finishReason: String?) -> Unit,
        onError: (String) -> Unit,
    ): () -> Unit {
        val url = endpoint(baseUrl, CHAT_PATH) ?: run {
            onError(INVALID_ENDPOINT)
            return {}
        }
        var finished = false
        var finishReason: String? = null

        val parser = SseLineParser { payload ->
            if (payload == "[DONE]" || payload.isBlank()) return@SseLineParser
            try {
                val json = JSONObject(payload)
                val serverError = json.optJSONObject("error")
                if (serverError != null) {
                    onError(serverError.optString("message", "服务端错误"))
                    return@SseLineParser
                }
                val choice = json.optJSONArray("choices")?.optJSONObject(0) ?: return@SseLineParser
                val delta = choice.optJSONObject("delta")
                val reasoning = delta?.optString("reasoning_content", "") ?: ""
                val content = delta?.optString("content", "") ?: ""
                if (reasoning.isNotEmpty()) onReasoning(reasoning)
                if (content.isNotEmpty()) onContent(content)
                val reason = choice.optString("finish_reason", "")
                if (reason.isNotEmpty()) finishReason = reason
            } catch (e: Exception) {
                // 无法解析为 JSON 的载荷直接忽略；不完整的行由 SseLineParser 缓存至完整后再派发
            }
        }

        // 总超时 180 秒，由 NetworkModule 控制；取消由返回的取消函数处理。
        val handle = network.httpStreamRequest(
            url = url,
            isPost = true,
            param = body,
            headers = headers(apiKey, true),
            cookie = null,
            timeout = 180,
        ) { event, data, response ->
            if (finished) return@httpStreamRequest
            when (event) {
                "data" -> parser.feed(data)
                "complete" -> {
                    finished = true
                    parser.end()
                    onDone(finishReason)
                }
                "error" -> {
                    finished = true
                    parser.end()
                    val code = response?.statusCode?.let { " (HTTP $it)" } ?: ""
                    onError(data.ifEmpty { "流式请求失败" } + code)
                }
            }
        }

        return {
            if (!finished) {
                finished = true
                handle.close()
            }
        }
    }

    /**
     * `NetworkModule.httpRequest` 的 JSON 响应直接返回解析结果，非 JSON 响应包装成 `{data: "原文"}`。
     * 原文本身是 JSON 时还原；空响应或不是 JSON（错误页、纯文本）返回 null，由调用方按失败处理。
     */
    private fun unwrap(data: JSONObject): JSONObject? {
        if (data.has("choices") || data.has("object")) return data
        // 只有「字符串形态的 data」才是非 JSON 包装体；数组形态（{data:[...]}）原样返回。
        val raw = data.opt("data")
        if (raw !is String) return data
        if (raw.isBlank()) return null
        return try {
            JSONObject(raw)
        } catch (e: Exception) {
            null
        }
    }

    /** [unwrap] 失败时的错误提示：空响应单独说明，否则附非 JSON 原文。 */
    private fun invalidBodyMessage(data: JSONObject): String {
        val raw = data.optString("data", "")
        return if (raw.isBlank()) "服务端返回空响应" else "服务端返回非 JSON 响应：${raw.take(120)}"
    }
}

/**
 * 按 WHATWG event-stream 规则增量解析 SSE：行结束符可为 CRLF / LF / 单独 CR，
 * 遇空行派发事件，`data:` 后只移除一个可选空格。
 */
private class SseLineParser(private val onPayload: (String) -> Unit) {
    private val line = StringBuilder()
    private val data = StringBuilder()
    private var hasData = false
    private var lastCharWasCR = false
    private var atStreamStart = true

    fun feed(chunk: String) {
        for (c in chunk) {
            if (line.length > MAX_LINE_CHARS || data.length > MAX_LINE_CHARS) {
                line.clear(); data.clear(); hasData = false
                onPayload("{\"error\":{\"message\":\"SSE 事件过长\"}}")
                return
            }
            if (atStreamStart) {
                atStreamStart = false
                if (c == '\uFEFF') continue
            }
            if (lastCharWasCR) {
                lastCharWasCR = false
                if (c == '\n') continue
            }
            when (c) {
                '\r' -> {
                    lastCharWasCR = true
                    processLine()
                }
                '\n' -> processLine()
                else -> line.append(c)
            }
        }
    }

    private fun processLine() {
        if (line.isEmpty()) {
            dispatch()
            return
        }
        val text = line.toString()
        line.clear()
        if (text.startsWith(":")) return
        val colon = text.indexOf(':')
        val field = if (colon >= 0) text.substring(0, colon) else text
        var value = if (colon >= 0) text.substring(colon + 1) else ""
        if (value.startsWith(" ")) value = value.substring(1)
        if (field == "data") {
            if (hasData) data.append('\n')
            data.append(value)
            hasData = true
        }
    }

    /** 流结束时派发最后一条未以空行结尾的事件。 */
    fun end() {
        if (line.isNotEmpty()) processLine()
        dispatch()
    }

    private fun dispatch() {
        if (hasData) {
            val payload = data.toString()
            data.clear()
            hasData = false
            onPayload(payload)
        }
    }
}

/**
 * 构造标准 OpenAI Chat Completion 请求体，由演示页组装，不依赖库的请求模型。
 *
 * [enableThinking] 是**可选的供应商扩展字段**：传 null 时只发送标准字段，
 * 可发往任意兼容端点；只有本地 Provider 需要关闭思考功能时才传 false。
 */
fun chatCompletionsBody(
    model: String,
    history: JSONArray,
    stream: Boolean,
    enableThinking: Boolean? = null,
    maxTokens: Int = 1024,
): JSONObject = JSONObject().apply {
    put("model", model)
    put("messages", history)
    put("stream", stream)
    put("max_tokens", maxTokens)
    put("temperature", 0.7)
    if (enableThinking != null) put("enable_thinking", enableThinking)
}

/** 把演示页的对话历史转成 OpenAI 的 messages 数组（只发 role/content）。 */
fun chatMessages(history: List<Pair<String, String>>): JSONArray = JSONArray().apply {
    history.forEach { (role, content) ->
        put(JSONObject().apply {
            put("role", role)
            put("content", content)
        })
    }
}
