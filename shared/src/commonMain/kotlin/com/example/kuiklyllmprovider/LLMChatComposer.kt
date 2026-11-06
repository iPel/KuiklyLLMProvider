package com.example.kuiklyllmprovider

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.tencent.kuikly.compose.extension.keyboardHeightChange
import com.tencent.kuikly.compose.extension.placeHolder
import com.tencent.kuikly.compose.foundation.background
import com.tencent.kuikly.compose.foundation.border
import com.tencent.kuikly.compose.foundation.clickable
import com.tencent.kuikly.compose.foundation.layout.Arrangement
import com.tencent.kuikly.compose.foundation.layout.Box
import com.tencent.kuikly.compose.foundation.layout.Column
import com.tencent.kuikly.compose.foundation.layout.ExperimentalLayoutApi
import com.tencent.kuikly.compose.foundation.layout.FlowRow
import com.tencent.kuikly.compose.foundation.layout.Row
import com.tencent.kuikly.compose.foundation.layout.Spacer
import com.tencent.kuikly.compose.foundation.layout.fillMaxSize
import com.tencent.kuikly.compose.foundation.layout.fillMaxWidth
import com.tencent.kuikly.compose.foundation.layout.height
import com.tencent.kuikly.compose.foundation.layout.padding
import com.tencent.kuikly.compose.foundation.layout.size
import com.tencent.kuikly.compose.foundation.layout.width
import com.tencent.kuikly.compose.foundation.shape.RoundedCornerShape
import com.tencent.kuikly.compose.foundation.text.BasicTextField
import com.tencent.kuikly.compose.foundation.text.KeyboardOptions
import com.tencent.kuikly.compose.material3.Text
import com.tencent.kuikly.compose.ui.Alignment
import com.tencent.kuikly.compose.ui.Modifier
import com.tencent.kuikly.compose.ui.focus.onFocusChanged
import com.tencent.kuikly.compose.ui.graphics.SolidColor
import com.tencent.kuikly.compose.ui.text.TextStyle
import com.tencent.kuikly.compose.ui.text.font.FontFamily
import com.tencent.kuikly.compose.ui.text.input.ImeAction
import com.tencent.kuikly.compose.ui.unit.dp

/** 输入区相关组件：顶栏、输入栏、设置浮层与胶囊 chip。 */

@Composable
internal fun ChatTopBar(
    title: String,
    onNewChat: () -> Unit,
    onSettingsClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(44.dp)
            .background(Surface)
            .padding(horizontal = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .background(Surface)
                .size(MinTouch)
                .clickable { onNewChat() },
            contentAlignment = Alignment.Center,
        ) {
            Text(text = "新对话", fontSize = CaptionSize, color = Accent)
        }
        Spacer(modifier = Modifier.width(8.dp))
        if (title.isNotEmpty()) {
            // 标题在中间区域居中；不直接给 Text 加 weight，否则文字会左对齐。
            Box(
                modifier = Modifier.weight(1f),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = title,
                    fontSize = BodySize,
                    color = TextPrimary,
                )
            }
        } else {
            Spacer(modifier = Modifier.weight(1f))
        }
        Box(
            modifier = Modifier
                .background(Surface)
                .size(MinTouch)
                .clickable { onSettingsClick() },
            contentAlignment = Alignment.Center,
        ) {
            Text(text = "设置", fontSize = CaptionSize, color = TextSecondary)
        }
    }
}

@Composable
internal fun ChatComposer(
    input: String,
    canSend: Boolean,
    generating: Boolean,
    switching: Boolean,
    switchFailed: Boolean,
    bottomInset: Float,
    modelName: String?,
    thinkingEnabled: Boolean,
    onInput: (String) -> Unit,
    onKeyboardHeight: (Float) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onToggleModelPanel: () -> Unit,
    onThinkingEnabled: (Boolean) -> Unit,
    onDismissPanel: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(Surface)
            .padding(bottom = bottomInset.dp)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        // 未就绪引导由首屏主 CTA 承担，输入区不重复提示。
        // 模型与思考共用同一套 chip 规格；模型 chip 的高亮表示当前有可用模型。
        Row(verticalAlignment = Alignment.CenterVertically) {
            ToolChip(
                text = (modelName?.let { shortModelName(it) } ?: "选择模型") +
                    if (switchFailed) " · 切换失败" else "",
                active = modelName != null,
                onClick = onToggleModelPanel,
            )
            Spacer(modifier = Modifier.width(8.dp))
            ToolChip(
                text = "思考",
                active = thinkingEnabled,
                onClick = { onThinkingEnabled(!thinkingEnabled) },
            )
        }
        Spacer(modifier = Modifier.height(8.dp))
        // 输入框与发送按钮并列：统一 12dp 圆角，避免双层圆角嵌套；
        // 左右边距由外层 16dp 统一承担，中间留 12dp（4pt 基准）。
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(InputHeight)
                    // 胶囊：半径取高度一半；Kuikly 对大宽高比容器会放大圆角，
                    // 放大后仍被裁剪为半高，形状稳定。
                    .background(BorderStrong, RoundedCornerShape(InputRadius))
                    .padding(1.dp),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Surface, RoundedCornerShape(InputRadius))
                        .clickable { onDismissPanel() }
                        .padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // 用 BasicTextField 的 String 重载：它在内部 remember 中保留 selection，
                    // 而 material3 TextField(String) 每次重组都以 selection=0 回写原生，导致光标归零。
                    BasicTextField(
                        value = input,
                        onValueChange = onInput,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(48.dp)
                            .placeHolder("发消息…", TextTertiary)
                            .onFocusChanged { state ->
                                if (state.isFocused || state.hasFocus) onDismissPanel()
                            }
                            .keyboardHeightChange { params -> onKeyboardHeight(params.height) },
                        singleLine = true,
                        textStyle = TextStyle(fontSize = BodySmallSize, color = TextPrimary),
                        cursorBrush = SolidColor(Accent),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                        keyboardActions = com.tencent.kuikly.compose.foundation.text.KeyboardActions(
                            onSend = { onSend() },
                        ),
                    )
                }
            }
            Spacer(modifier = Modifier.width(12.dp))
            val buttonColor = when {
                switching -> DisabledBg
                generating -> TextSecondary
                canSend -> Accent
                else -> DisabledBg
            }
            // 禁用态用暖灰底与深色文字（对比度 ≥6:1）。
            val buttonTextColor = if (canSend || generating) Surface else DisabledFg
            // 与输入框使用完全相同的双层 Box 结构与圆角参数，
            // 避免 Kuikly 对不同宽高比控件采用不同圆角渲染路径。
            Box(
                modifier = Modifier
                    .width(64.dp)
                    .height(InputHeight)
                    .background(buttonColor, RoundedCornerShape(InputRadius))
                    .padding(1.dp),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(buttonColor, RoundedCornerShape(InputRadius))
                        .clickable {
                            onDismissPanel()
                            if (generating) onStop() else if (canSend) onSend()
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = if (switching) "切换中" else if (generating) "停止" else "发送",
                        fontSize = CaptionSize,
                        color = buttonTextColor,
                    )
                }
            }
        }
    }
}

/** 设置浮层：运行状态、生成选项与调试动作。 */

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun SettingsPanel(
    topInset: Float,
    statusText: String,
    apiKey: String,
    generating: Boolean,
    reasoningChars: Int,
    streamChars: Int,
    serverReady: Boolean,
    streaming: Boolean,
    onToggleServer: () -> Unit,
    onListModels: () -> Unit,
    onClearMessages: () -> Unit,
    onStreaming: (Boolean) -> Unit,
    onClose: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(Surface)
            .padding(top = topInset.dp)
            .padding(horizontal = 20.dp)
            .padding(bottom = 16.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().height(44.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "设置",
                fontSize = BodySize,
                color = TextPrimary,
                modifier = Modifier.weight(1f),
            )
            Box(
                modifier = Modifier
                    .height(ControlVisualHeight)
                    .background(Surface, RoundedCornerShape(PillRadius))
                    .border(1.dp, BorderStrong, RoundedCornerShape(PillRadius))
                    .clickable { onClose() }
                    .padding(horizontal = 16.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(text = "关闭", fontSize = CaptionSize, color = Accent)
            }
        }
        Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Divider))
        Spacer(modifier = Modifier.height(12.dp))
        SectionLabel("运行状态")
        Text(text = statusText, fontSize = CaptionSize, color = TextPrimary)
        if (apiKey.isEmpty()) {
            Text(text = "本地服务未启动", fontSize = CaptionSize, color = TextSecondary)
        } else {
            // 展示本地凭据便于 curl 调试；仅 127.0.0.1 有效、重启即更换。
            Text(
                text = "本地凭据（仅 127.0.0.1 有效，重启后更换）",
                fontSize = CaptionSize,
                color = TextSecondary,
            )
            // 等宽字体避免 0/O、1/l 混淆。
            Text(text = apiKey, fontSize = CaptionSize, color = TextPrimary, fontFamily = FontFamily.Monospace)
        }
        if (generating) {
            Text(
                text = "生成中 · 思考 $reasoningChars 字 · 回答 $streamChars 字",
                fontSize = CaptionSize,
                color = Accent,
            )
        }
        Spacer(modifier = Modifier.height(12.dp))

        SectionLabel("生成")
        Row(modifier = Modifier.fillMaxWidth()) {
            ToolChip("流式输出", streaming) { onStreaming(!streaming) }
        }
        Spacer(modifier = Modifier.height(12.dp))

        SectionLabel("调试")
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            DevAction(if (serverReady) "停止服务" else "启动服务", onToggleServer)
            DevAction("查看模型列表", onListModels)
            DevAction("清空对话", onClearMessages)
        }
    }
    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Divider))
}

/** 设置浮层的分组标题。 */

@Composable
internal fun SectionLabel(text: String) {
    Text(
        text = text,
        fontSize = CaptionSize,
        color = TextTertiary,
        modifier = Modifier.padding(bottom = 8.dp),
    )
}

@Composable
internal fun ToolChip(text: String, active: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .height(MinTouch)
            .clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .height(ControlVisualHeight)
                .background(Surface, RoundedCornerShape(PillRadius))
                .border(1.dp, if (active) Accent else BorderStrong, RoundedCornerShape(PillRadius))
                .padding(horizontal = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = text,
                fontSize = CaptionSize,
                color = if (active) Accent else TextSecondary,
            )
        }
    }
}

/** 设置浮层里的次级动作，胶囊形状。 */

@Composable
internal fun DevAction(text: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .height(ControlVisualHeight)
            .background(Surface, RoundedCornerShape(PillRadius))
            .border(1.dp, BorderStrong, RoundedCornerShape(PillRadius))
            .clickable { onClick() }
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text = text, fontSize = CaptionSize, color = TextSecondary)
    }
}
