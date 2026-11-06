package com.example.kuiklyllmprovider

import com.tencent.kuikly.compose.ui.graphics.Color
import com.tencent.kuikly.compose.ui.unit.dp
import com.tencent.kuikly.compose.ui.unit.sp

/**
 * 设计系统颜色、字号与触控尺寸（浅色），对比度按 WCAG 2.2 校验：
 * 文本 ≥4.5:1、控件边界 ≥3:1。
 */
internal val PageBackground = Color(0xFFFAF9F6)  // 暖米底
internal val Surface = Color(0xFFFFFFFF)
internal val Accent = Color(0xFFB04A26)          // 陶土：5.45:1 / 白字 5.45:1
internal val AccentContainer = Color(0xFFF7E8E1) // 当前启用 / 选中底
internal val BrandPress = Color(0xFFF0DBD3)      // 按下态底
internal val BorderSoft = Color(0xFFE8E2D9)      // 菜单卡片极淡边
internal val UserBubble = Color(0xFFF2EDE7)      // 暖米气泡
internal val TextPrimary = Color(0xFF1E1B16)     // 17.16:1 / 16.30:1
internal val TextSecondary = Color(0xFF5C564C)   // 7.27:1 / 6.90:1
internal val TextTertiary = Color(0xFF7A7166)    // 4.79:1 / 4.55:1
internal val BorderStrong = Color(0xFF9A8F80)    // 3.17:1 对白，满足非文本 3:1
internal val Divider = Color(0xFFF0EBE4)         // 仅装饰性分隔
internal val ThinkingRule = Color(0xFFD8D2C8)    // 思考区左侧细竖线（浅暖灰）
internal val Overlay = Color(0x66000000)         // 设置浮层使用；选模型菜单不用遮罩
internal val DisabledBg = Color(0xFFF0EBE4)
internal val DisabledFg = Color(0xFF5C564C)      // 对 DisabledBg ≥6:1

// 字号 4 档，行高由组件保持 1.4–1.5
internal val CaptionSize = 12.sp
internal val BodySmallSize = 14.sp
internal val BodySize = 16.sp
internal val TitleSize = 20.sp

// 4pt 基准间距与触控最小尺寸
internal val MinTouch = 44.dp

// 大圆角 / 胶囊设计语言：视觉高度压低，触控区仍保持 MinTouch。
internal val ControlVisualHeight = 36.dp
internal val ActionHeight = 40.dp
internal val PillRadius = 18.dp      // 36dp 控件的胶囊半径
internal val ActionRadius = 20.dp    // 40dp 主操作 / CTA
internal val InputRadius = 26.dp     // 52dp 输入框
internal val InputHeight = 52.dp     // 输入框与发送按钮共用高度
internal val CardRadius = 24.dp      // 菜单卡片大圆角
internal val BubbleRadius = 20.dp    // 用户气泡

// 选模型菜单最大宽度：手机上仍与输入区同宽（约 370dp），
// 平板 / 横屏 / 折叠屏展开时不超过该值并靠左对齐。
internal val MenuMaxWidth = 420.dp

// 对话内容最大宽度：宽屏下正文 / 思考区 / 气泡不拉满，与菜单上限一致。
internal val ContentMaxWidth = 420.dp
