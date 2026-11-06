package com.example.kuiklyllmprovider

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.kuikly.llmprovider.LLMProviderModule
import kotlinx.coroutines.delay
import com.tencent.kuikly.compose.foundation.background
import com.tencent.kuikly.compose.foundation.clickable
import com.tencent.kuikly.compose.foundation.layout.Arrangement
import com.tencent.kuikly.compose.foundation.layout.Box
import com.tencent.kuikly.compose.foundation.layout.Column
import com.tencent.kuikly.compose.foundation.layout.PaddingValues
import com.tencent.kuikly.compose.foundation.layout.Spacer
import com.tencent.kuikly.compose.foundation.layout.fillMaxSize
import com.tencent.kuikly.compose.foundation.layout.fillMaxWidth
import com.tencent.kuikly.compose.foundation.layout.height
import com.tencent.kuikly.compose.foundation.layout.padding
import com.tencent.kuikly.compose.foundation.layout.size
import com.tencent.kuikly.compose.foundation.lazy.LazyColumn
import com.tencent.kuikly.compose.foundation.lazy.itemsIndexed
import com.tencent.kuikly.compose.foundation.lazy.rememberLazyListState
import com.tencent.kuikly.compose.foundation.layout.WindowInsets
import com.tencent.kuikly.compose.material3.Scaffold
import com.tencent.kuikly.compose.ui.Alignment
import com.tencent.kuikly.compose.ui.Modifier
import com.tencent.kuikly.compose.ui.platform.LocalActivity
import com.tencent.kuikly.compose.ui.platform.LocalConfiguration
import com.tencent.kuikly.compose.ui.platform.LocalSoftwareKeyboardController
import com.tencent.kuikly.compose.ui.unit.dp
import com.tencent.kuikly.core.module.Module
import com.tencent.kuikly.core.module.NetworkModule
import com.tencent.kuikly.core.pager.IPager

/** 主 composable：状态、轮询、模型动作、发送/流式生成与整体布局。 */

@Composable
internal fun LLMChatScreen() {
    val pager: IPager = LocalActivity.current
    val network: NetworkModule = pager.acquireModule(NetworkModule.MODULE_NAME)
    val provider: LLMProviderModule = pager.acquireModule(LLMProviderModule.MODULE_NAME)
    val transport = remember { ChatCompletionsTransport() }

    val listState = rememberLazyListState()
    val keyboard = LocalSoftwareKeyboardController.current
    val configuration = LocalConfiguration.current
    val safeArea = configuration.safeAreaInsets
    val pageWidth = configuration.pageViewWidth
    val maxBubbleWidth = (if (pageWidth > 0f) pageWidth * 0.78f else 280f).dp

    // ---- 本地 Provider 的连接信息（来自 LLMProvider 的启动与状态回调） ----
    var localBaseUrl by remember { mutableStateOf("") }
    var localApiKey by remember { mutableStateOf("") }
    var serverReady by remember { mutableStateOf(false) }
    var modelLoaded by remember { mutableStateOf(false) }

    // ---- 当前实际使用的 Provider：留空时使用本地服务，填写后改用指定的兼容端点 ----
    var providerUrl by remember { mutableStateOf("") }
    var providerKey by remember { mutableStateOf("") }
    var providerModel by remember { mutableStateOf("") }

    fun currentUrl(): String = providerUrl.trim().ifBlank { localBaseUrl }
    // 本地凭据仅用于本机端点；外部端点未填 key 时不带凭据。
    fun currentKey(): String =
        providerKey.trim().ifBlank { if (isLocalEndpoint(currentUrl())) localApiKey else "" }
    fun isExternal(): Boolean = providerUrl.trim().isNotEmpty()

    var statusText by remember { mutableStateOf("正在启动本地服务…") }
    var modelJson by remember { mutableStateOf("") }
    var modelPanelOpen by remember { mutableStateOf(false) }
    var devExpanded by remember { mutableStateOf(false) }
    // 乐观切换：点选后立即在 UI 上呈现目标模型，库侧加载完成后确认，超时回滚。
    var pendingModelId by remember { mutableStateOf<String?>(null) }
    var switchTimedOut by remember { mutableStateOf(false) }
    var title by remember { mutableStateOf("") }
    var titlePending by remember { mutableStateOf(false) }

    var input by remember { mutableStateOf("") }
    var streaming by remember { mutableStateOf(true) }
    var thinkingEnabled by remember { mutableStateOf(true) }
    var generating by remember { mutableStateOf(false) }
    var cancelled by remember { mutableStateOf(false) }
    var streamChars by remember { mutableStateOf(0) }
    var reasoningChars by remember { mutableStateOf(0) }
    var cancelStream by remember { mutableStateOf<(() -> Unit)?>(null) }
    var keyboardHeight by remember { mutableStateOf(0f) }
    val messages = remember { mutableStateListOf<ChatTurn>() }

    // 页面生命周期启动后才可使用 Module（willInit 中 Module 尚未注册）
    LaunchedEffect(Unit) {
        provider.startServer { ok, url, key, message ->
            serverReady = ok
            localBaseUrl = url
            localApiKey = key
            statusText = if (ok) "服务已就绪 · $url" else "启动失败：$message"
        }
    }

    // 轮询绑定 Module 作用域；页面销毁后下一轮自动停止。
    LaunchedEffect(Unit) {
        while (provider.isActive) {
            provider.models { json -> modelJson = json }
            delay(400)
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            provider.dispose()
            cancelStream?.invoke()
            cancelStream = null
        }
    }

    val modelList = parseModels(modelJson)
    val activeModel = modelList.firstOrNull { it.active }
    // 切换期间 UI 立即显示目标模型名，不等库侧异步加载完成。
    val displayedModel = pendingModelId?.let { id -> modelList.firstOrNull { it.id == id }?.name }
        ?: activeModel?.name
    val canSend = serverReady && activeModel != null && pendingModelId == null && !isExternal()

    LaunchedEffect(activeModel?.id) {
        if (activeModel != null && !isExternal()) providerModel = activeModel.id
    }

    // 库侧真正切换完成：清除 pending，恢复正常态。
    LaunchedEffect(activeModel?.id, pendingModelId) {
        val pending = pendingModelId ?: return@LaunchedEffect
        if (activeModel?.id == pending) {
            pendingModelId = null
            switchTimedOut = false
            statusText = "已切换到 ${shortModelName(activeModel.name)}"
        }
    }

    // 超时保护：10 秒仍未完成则回滚，并在 chip 上给出 3 秒可见反馈。
    LaunchedEffect(pendingModelId) {
        val pending = pendingModelId ?: return@LaunchedEffect
        delay(10_000)
        if (pendingModelId == pending) {
            pendingModelId = null
            switchTimedOut = true
            statusText = "模型切换未完成，请重试"
            delay(3_000)
            switchTimedOut = false
        }
    }

    fun modelAction(action: String, id: String) {
        if (action == "select") {
            pendingModelId = id
            switchTimedOut = false
        }
        provider.modelAction(action, id) { json -> modelJson = json }
    }

    fun toggleThinking(index: Int) {
        if (index < 0 || index >= messages.size) return
        val turn = messages[index]
        messages[index] = turn.copy(expanded = !turn.expanded)
    }

    fun newChat() {
        cancelStream?.invoke()
        cancelStream = null
        cancelled = true
        generating = false
        messages.clear()
        input = ""
        title = ""
        titlePending = false
        streamChars = 0
        reasoningChars = 0
        modelPanelOpen = false
        devExpanded = false
        statusText = "已开始新对话"
    }

    // 第一轮 Agent 回复完成后，用一次极短的非流式请求生成会话标题；失败或结果异常时改用问题截断。
    fun generateTitle(question: String) {
        if (title.isNotEmpty() || titlePending) return
        titlePending = true
        val prompt = "请用不超过 10 个汉字概括下面的问题，只输出标题本身，不要解释、不要引号、不要标点：\n$question"
        val body = chatCompletionsBody(
            model = activeModel?.id ?: providerModel,
            history = chatMessages(listOf("user" to prompt)),
            stream = false,
            enableThinking = if (!isExternal()) false else null,
        )
        transport.chatOnce(network, currentUrl(), currentKey(), body) { ok, content, _, _, _ ->
            title = if (ok) cleanTitle(content, question) else titleFromQuestion(question)
        }
    }

    fun send() {
        val text = input.trim()
        if (text.isEmpty() || generating || !canSend) return
        // 空列表时的这一轮就是首轮，用于回复完成后生成标题。
        val firstQuestion = if (messages.isEmpty()) text else null
        keyboard?.hide()
        messages.add(ChatTurn.user(text))
        messages.add(ChatTurn.assistant())
        input = ""
        generating = true
        cancelled = false
        streamChars = 0
        reasoningChars = 0

        // 只把 role/content 发给模型，思考文本与展开态留在 UI 层；
        // 历史收紧到最近 4 条 / 每条 300 字，与 1024 输出预算一起适配 0.6B 模型的上下文窗口。
        val history = messages.toList()
            .filter { it.content.isNotEmpty() }
            .takeLast(4)
            .map { turn -> turn.role to turn.content.take(300) }
        // 标准 OpenAI 请求体；仅在本地 Provider 且关闭思考功能时附加供应商扩展字段
        val body = chatCompletionsBody(
            model = activeModel?.id ?: providerModel,
            history = chatMessages(history),
            stream = streaming,
            enableThinking = if (!isExternal() && !thinkingEnabled) false else null,
        )
        val url = currentUrl()
        val key = currentKey()

        fun appendDelta(delta: String) {
            if (cancelled || delta.isEmpty()) return
            val last = messages.lastIndex
            if (last < 0) return
            val turn = messages[last]
            messages[last] = turn.copy(content = turn.content + delta)
            streamChars += delta.length
        }

        fun appendReasoning(thought: String) {
            if (cancelled || thought.isEmpty()) return
            val last = messages.lastIndex
            if (last < 0) return
            val turn = messages[last]
            messages[last] = turn.copy(reasoning = turn.reasoning + thought)
            if (thought.trim().isNotEmpty()) reasoningChars += thought.trim().length
        }

        if (streaming) {
            cancelStream = transport.chatStream(
                network = network,
                baseUrl = url,
                apiKey = key,
                body = body,
                onContent = { delta -> appendDelta(delta) },
                onReasoning = { thought -> appendReasoning(thought) },
                onDone = { reason ->
                    generating = false
                    cancelStream = null
                    val full = messages.lastOrNull()?.content ?: ""
                    statusText = when {
                        reason == "length" -> "输出达到 max_tokens 上限 · 回答 ${full.length} 字"
                        reasoningChars > 0 -> "完成 · 思考 $reasoningChars 字 · 回答 ${full.length} 字"
                        thinkingEnabled -> "完成 · ${full.length} 字（本次未产生思考）"
                        else -> "完成 · ${full.length} 字（已关闭思考功能）"
                    }
                    if (!cancelled && full.isNotEmpty() && firstQuestion != null) {
                        generateTitle(firstQuestion)
                    }
                },
                onError = { error ->
                    generating = false
                    cancelStream = null
                    statusText = "SSE 请求失败：$error"
                },
            )
        } else {
            transport.chatOnce(network, url, key, body) { ok, content, reasoning, _, message ->
                val last = messages.lastIndex
                if (!cancelled && last >= 0) {
                    val turn = messages[last]
                    if (ok) {
                        reasoningChars = reasoning.trim().length
                        messages[last] = turn.copy(content = content, reasoning = reasoning.trim())
                    }
                    statusText = if (ok) "生成完成 · ${content.length} 字" else "请求失败：$message"
                    if (ok && firstQuestion != null) generateTitle(firstQuestion)
                }
                generating = false
            }
        }
    }

    fun stopGenerating() {
        cancelStream?.invoke()
        cancelStream = null
        cancelled = true
        generating = false
        statusText = "已停止生成"
    }

    // 流式输出期间保持列表滚动到底部；使用 scrollToItem 而非 animateScrollToItem，
    // 避免逐段输出打断滚动动画。
    LaunchedEffect(messages.size, streamChars, reasoningChars, keyboardHeight) {
        if (messages.isNotEmpty()) {
            listState.scrollToItem(messages.size)
        }
    }

    fun toggleServer() {
        if (serverReady) {
            provider.stopServer { ok, message ->
                serverReady = false
                localBaseUrl = ""
                localApiKey = ""
                statusText = if (ok) "服务已停止" else message
            }
        } else {
            provider.startServer { ok, url, key, message ->
                serverReady = ok
                localBaseUrl = url
                localApiKey = key
                statusText = if (ok) "服务已就绪 · $url" else "启动失败：$message"
            }
        }
    }

    fun listModels() {
        transport.listModels(network, currentUrl(), currentKey()) { ok, text ->
            statusText = if (ok) "模型：$text" else "GET /v1/models 失败：$text"
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(PageBackground)) {
        Scaffold(
            modifier = Modifier.fillMaxSize(),
            containerColor = PageBackground,
            // 显式关闭自动 insets：安全区由 topBar 占位与输入栏的 bottomInset 自行处理，
            // 避免与手写逻辑叠加导致标题行错位。
            contentWindowInsets = WindowInsets(0, 0, 0, 0),
            topBar = {
                Column {
                    if (safeArea.top > 0f) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(safeArea.top.dp)
                                .background(Surface),
                        )
                    }
                    ChatTopBar(
                        title = title,
                        onNewChat = { newChat() },
                        onSettingsClick = {
                            devExpanded = !devExpanded
                            if (devExpanded) modelPanelOpen = false
                        },
                    )
                }
            },
            bottomBar = {
                ChatComposer(
                    input = input,
                    canSend = canSend,
                    generating = generating,
                    switching = pendingModelId != null,
                    switchFailed = switchTimedOut,
                    bottomInset = maxOf(keyboardHeight, safeArea.bottom),
                    modelName = displayedModel,
                    thinkingEnabled = thinkingEnabled,
                    onInput = { input = it },
                    onKeyboardHeight = { height ->
                        keyboardHeight = height
                        if (height > 0f) modelPanelOpen = false
                    },
                    onSend = { send() },
                    onStop = { stopGenerating() },
                    onToggleModelPanel = {
                        modelPanelOpen = !modelPanelOpen
                        if (modelPanelOpen) devExpanded = false
                    },
                    onThinkingEnabled = { thinkingEnabled = it },
                    onDismissPanel = { modelPanelOpen = false },
                )
            },
        ) { innerPadding ->
            // Kuikly 的 Scaffold 不自动裁剪 content，必须显式应用 innerPadding 避开 topBar / bottomBar。
            Box(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(top = 16.dp, bottom = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    if (messages.isEmpty()) {
                        item {
                            WelcomeBlock(
                                external = isExternal(),
                                modelReady = activeModel != null || pendingModelId != null,
                                // 主 CTA 只呼起菜单，绝不代用户发起下载。
                                onOpenModels = { modelPanelOpen = true },
                                onSuggestion = { suggestion ->
                                    if (canSend) {
                                        input = suggestion
                                        send()
                                    } else {
                                        statusText = "请先下载并启用模型"
                                        modelPanelOpen = true
                                    }
                                },
                            )
                        }
                    }
                    itemsIndexed(messages) { index, turn ->
                        if (turn.role == "assistant") {
                            val active = generating && index == messages.lastIndex
                            // 模型偶尔只输出空白的 reasoning_content，trim 后为空就不要渲染思考区。
                            val reasoning = turn.reasoning.trim()
                            val hasReasoning = reasoning.isNotEmpty()
                            Column {
                                // 只有真正产生思考内容才显示思考行；没有思考内容时由正文显示「正在生成…」。
                                if (hasReasoning) {
                                    ThinkingRow(
                                        text = reasoning,
                                        expanded = turn.expanded,
                                        active = active,
                                        onToggle = { toggleThinking(index) },
                                    )
                                }
                                // 生成中且已有思考内容、正文尚未开始输出时不渲染正文占位，
                                // 保证「思考中…」与「正在生成…」同一时刻只出现一个。
                                if (!active || !hasReasoning || turn.content.isNotEmpty()) {
                                    AssistantMessage(turn.content, active)
                                }
                            }
                        } else {
                            UserMessage(turn.content, maxBubbleWidth)
                        }
                    }
                    item { Spacer(modifier = Modifier.height(1.dp)) }
                }
                if (modelPanelOpen) {
                    // 不显示遮罩；上方保留透明点击层用于点击外部关闭，
                    // 对话内容保持原亮度；菜单与输入区同宽，向上展开为紧凑抽屉。
                    Column(modifier = Modifier.fillMaxSize()) {
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .fillMaxWidth()
                                .clickable { modelPanelOpen = false },
                        )
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp)
                                .padding(bottom = 8.dp),
                            // 宽屏时菜单受 MenuMaxWidth 约束，靠左与 chip 对齐。
                            contentAlignment = Alignment.TopStart,
                        ) {
                            ModelPanel(
                                models = modelList,
                                pendingModelId = pendingModelId,
                                onAction = { act, id ->
                                    modelAction(act, id)
                                    if (act == "select") modelPanelOpen = false
                                },
                            )
                        }
                    }
                }
            }
        }

        // 设置以浮层呈现，不参与主布局测量，展开时对话区和输入区保持原样。
        if (devExpanded) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Overlay)
                    .clickable { devExpanded = false },
            )
            SettingsPanel(
                topInset = safeArea.top,
                statusText = statusText,
                apiKey = localApiKey,
                generating = generating,
                reasoningChars = reasoningChars,
                streamChars = streamChars,
                serverReady = serverReady,
                streaming = streaming,
                onToggleServer = { toggleServer() },
                onListModels = { listModels() },
                onClearMessages = { messages.clear() },
                onStreaming = { streaming = it },
                onClose = { devExpanded = false },
            )
        }
    }
}
