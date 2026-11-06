package com.example.kuiklyllmprovider

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import com.tencent.kuikly.compose.foundation.background
import com.tencent.kuikly.compose.foundation.border
import com.tencent.kuikly.compose.foundation.clickable
import com.tencent.kuikly.compose.foundation.interaction.MutableInteractionSource
import com.tencent.kuikly.compose.foundation.interaction.collectIsPressedAsState
import com.tencent.kuikly.compose.foundation.layout.Arrangement
import com.tencent.kuikly.compose.foundation.layout.Box
import com.tencent.kuikly.compose.foundation.layout.Column
import com.tencent.kuikly.compose.foundation.layout.Row
import com.tencent.kuikly.compose.foundation.layout.Spacer
import com.tencent.kuikly.compose.foundation.layout.fillMaxWidth
import com.tencent.kuikly.compose.foundation.layout.height
import com.tencent.kuikly.compose.foundation.layout.padding
import com.tencent.kuikly.compose.foundation.layout.size
import com.tencent.kuikly.compose.foundation.layout.width
import com.tencent.kuikly.compose.foundation.layout.widthIn
import com.tencent.kuikly.compose.foundation.shape.RoundedCornerShape
import com.tencent.kuikly.compose.material3.Text
import com.tencent.kuikly.compose.material3.CircularProgressIndicator
import com.tencent.kuikly.compose.ui.Alignment
import com.tencent.kuikly.compose.ui.Modifier
import com.tencent.kuikly.compose.ui.text.style.TextAlign
import com.tencent.kuikly.compose.ui.text.font.FontStyle
import com.tencent.kuikly.compose.ui.unit.Dp
import com.tencent.kuikly.compose.ui.unit.dp

/** 内容区组件：欢迎区、消息气泡、思考区与选模型菜单。 */

@Composable
internal fun WelcomeBlock(
    external: Boolean,
    modelReady: Boolean,
    onOpenModels: () -> Unit,
    onSuggestion: (String) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 28.dp),
    ) {
        Text(text = "有什么可以帮你？", fontSize = TitleSize, color = TextPrimary)
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = if (external) "正在使用外部兼容服务。"
            else "模型在设备上运行，对话内容不会离开设备。",
            fontSize = CaptionSize,
            color = TextSecondary,
        )
        if (!modelReady) {
            Spacer(modifier = Modifier.height(20.dp))
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(ActionHeight)
                    .background(Accent, RoundedCornerShape(ActionRadius))
                    .clickable { onOpenModels() },
                contentAlignment = Alignment.Center,
            ) {
                Text(text = "下载并启用模型", fontSize = BodySmallSize, color = Surface)
            }
        }
        Spacer(modifier = Modifier.height(20.dp))
        // 统一节奏：固定尺寸圆点 + 固定文字缩进，分隔线与文字左缘对齐，
        // 最后一条不画分隔线，避免悬空线造成的参差。
        Suggestions.forEachIndexed { index, suggestion ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(MinTouch)
                    .clickable { onSuggestion(suggestion) },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(4.dp)
                        .background(Accent, RoundedCornerShape(2.dp)),
                )
                Spacer(modifier = Modifier.width(12.dp))
                Text(text = suggestion, fontSize = BodySmallSize, color = TextPrimary)
            }
            if (index != Suggestions.lastIndex) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 16.dp)
                        .height(1.dp)
                        .background(Divider),
                )
            }
        }
    }
}

/** 用户消息：米色气泡靠右，与左对齐的助手正文形成位置区分。 */

@Composable
internal fun UserMessage(content: String, maxBubbleWidth: Dp) {
    Row(
        modifier = Modifier
            .widthIn(max = ContentMaxWidth)
            .fillMaxWidth()
            .padding(horizontal = 20.dp),
        horizontalArrangement = Arrangement.End,
    ) {
        Box(
            modifier = Modifier
                .widthIn(max = maxBubbleWidth)
                .background(UserBubble, RoundedCornerShape(BubbleRadius))
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Text(
                text = content,
                fontSize = BodySmallSize,
                color = TextPrimary,
                textAlign = TextAlign.Justify,
            )
        }
    }
}

/** 助手消息：限制最大宽度、两端对齐，与弱化后的思考文本靠字号与字色区分。 */

@Composable
internal fun AssistantMessage(content: String, active: Boolean) {
    Column(
        modifier = Modifier
            .widthIn(max = ContentMaxWidth)
            .fillMaxWidth()
            .padding(horizontal = 20.dp),
    ) {
        Text(
            text = when {
                content.isNotEmpty() -> content
                active -> "正在生成…"
                else -> "（本次没有生成回答）"
            },
            fontSize = BodySmallSize,
            color = TextPrimary,
            textAlign = TextAlign.Justify,
            modifier = Modifier.fillMaxWidth(),
        )
        // 脚注只在回答结束且有正文时出现；流式生成中不提前显示。
        if (content.isNotEmpty() && !active) {
            Spacer(modifier = Modifier.height(20.dp))
            Text(
                text = "本回答由 AI 生成，内容仅供参考，请仔细甄别",
                fontSize = CaptionSize,
                color = TextTertiary,
                fontStyle = FontStyle.Italic,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** 思考过程：有内容才可展开；展开区为灰色字 + 左侧浅灰细竖线，无背景色块。 */

@Composable
internal fun ThinkingRow(
    text: String,
    expanded: Boolean,
    active: Boolean,
    onToggle: () -> Unit,
) {
    val hasText = text.isNotEmpty()
    Column(
        modifier = Modifier
            .widthIn(max = ContentMaxWidth)
            .fillMaxWidth()
            .padding(horizontal = 20.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = hasText) { onToggle() }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (active) "思考中…" else "已完成思考",
                fontSize = CaptionSize,
                color = TextTertiary,
            )
            if (hasText) {
                Spacer(modifier = Modifier.width(12.dp))
                Text(
                    text = if (expanded) "收起" else "展开",
                    fontSize = CaptionSize,
                    color = TextSecondary,
                )
            }
        }
        if (expanded && hasText) {
            // 参照「灰色字 + 竖线」：外层 2dp 浅灰作竖线，内层用页面底色盖住其余部分；
            // 高度由文字撑开，竖线自然贯穿整段，不用固定高度的短竖条。
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(ThinkingRule)
                    .padding(start = 2.dp),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(PageBackground)
                        .padding(start = 12.dp, top = 2.dp, bottom = 12.dp),
                ) {
                    Text(
                        text = text,
                        fontSize = CaptionSize,
                        color = TextSecondary,
                        textAlign = TextAlign.Justify,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

/* 选模型菜单：与输入区同宽的圆角抽屉。 */

@Composable
internal fun ModelPanel(
    models: List<ModelUi>,
    pendingModelId: String?,
    onAction: (String, String) -> Unit,
) {
    // CTA / chip 展开菜单时，手指抬起的 UP 可能落在新出现的菜单行上；
    // 180ms 保护期避免「点按钮」被误判成「点菜单项」而自动下载或切换。
    var interactive by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { delay(180L); interactive = true }
    Column(
        modifier = Modifier
            // widthIn 在前：先给父约束设上限，fillMaxWidth 在该上限内铺满，
            // 结果为 min(可用宽度, MenuMaxWidth)，手机上不变、宽屏收窄。
            .widthIn(max = MenuMaxWidth)
            .fillMaxWidth()
            .background(Surface, RoundedCornerShape(CardRadius))
            .border(1.dp, BorderSoft, RoundedCornerShape(CardRadius)),
    ) {
        models.forEach { m ->
            ModelMenuRow(m = m, pendingModelId = pendingModelId, onAction = onAction, interactive = interactive)
        }
    }
}

/* 单行 56dp：真实按下态、当前启用态、进度与操作，整行只做模型切换。 */

@Composable
internal fun ModelMenuRow(
    m: ModelUi,
    pendingModelId: String?,
    onAction: (String, String) -> Unit,
    interactive: Boolean,
) {
    val isPending = pendingModelId == m.id
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val selectable = m.actions.contains("select")
    val actions = m.actions.filter { it != "select" }
    val rowBg = when {
        pressed -> BrandPress
        isPending || m.active -> AccentContainer
        else -> Surface
    }
    val barColor = if (pressed || m.active || isPending) Accent else rowBg
    val stateHint = when {
        isPending -> "切换中…"
        m.active -> "使用中"
        m.bundled -> "内置"
        m.state == "downloading" -> "下载中"
        m.state == "paused" -> "已暂停"
        m.state == "ready" -> "已下载"
        else -> "未下载"
    }
    val hasProgress = (m.state == "downloading" || m.state == "paused") && m.total > 0
    val percent = if (m.total > 0) (m.downloaded.toFloat() / m.total.toFloat() * 100).toInt() else 0

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(56.dp)
                .background(rowBg)
                // 整行只响应模型切换；下载 / 暂停 / 续传 / 取消 / 删除一律由行内按钮承担。
                .clickable(interactionSource = interaction, indication = null) {
                    if (!interactive || isPending) return@clickable
                    if (selectable) onAction("select", m.id)
                }
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(modifier = Modifier.width(3.dp).height(24.dp).background(barColor))
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(text = shortModelName(m.name), fontSize = BodySmallSize, color = TextPrimary)
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = "${m.bytes / 1048576} MB · $stateHint",
                    fontSize = CaptionSize,
                    color = TextTertiary,
                )
            }
            if (hasProgress) {
                // 整组固定 60dp：百分比位数从 3% 到 100% 变化时圆环不左右移动。
                Row(
                    modifier = Modifier.width(60.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(
                        progress = { (m.downloaded.toFloat() / m.total.toFloat()).coerceIn(0f, 1f) },
                        modifier = Modifier.size(14.dp),
                        color = Accent,
                        trackColor = Divider,
                        strokeWidth = 2.dp,
                    )
                    Spacer(modifier = Modifier.width(5.dp))
                    Text(
                        text = "$percent%",
                        fontSize = CaptionSize,
                        color = TextSecondary,
                        modifier = Modifier.width(36.dp),
                    )
                }
                Spacer(modifier = Modifier.width(7.dp))
            }
            // 当前启用态由淡陶土底、左侧竖条与「使用中」文字表达。
            actions.take(2).forEach { act ->
                Text(
                    text = modelActionLabel(act),
                    fontSize = CaptionSize,
                    color = if (act == "delete") TextSecondary else Accent,
                    modifier = Modifier
                        .clickable { if (interactive) onAction(act, m.id) }
                        .padding(horizontal = 6.dp, vertical = 8.dp),
                )
                Spacer(modifier = Modifier.width(4.dp))
            }
        }
        Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Divider))
    }
}
