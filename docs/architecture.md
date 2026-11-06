# 架构说明

## 分层

```
业务页面 (shared)
   │  服务管理：LLMProviderModule.startServer/stopServer/status/models/modelAction  (Kuikly Module.toNative)
   │  对话请求：标准 HTTP  /v1/chat/completions、/v1/models  (NetworkModule)
   ▼
KuiklyLLMProvider (KMP commonMain)
   ├── LLMProviderModule      唯一公共 API（Pager 注册并持有）
   └── LLMProviderContract    三端契约生成源（internal）
   ▼
三端原生层
   ├── Android  KRLLMProviderModule + ModelStore + LLMProviderNativeBridge
   ├── iOS      KRLLMProviderModule + LPMStore
   └── HarmonyOS KRLLMProviderModule + ArkTS 状态管理 + NAPI
   ▼
KuiklyLLMProviderNative (C++)
   ├── HttpServer   回环地址上的兼容端点，使用 Bearer 鉴权
   ├── Engine       llama.cpp 引擎（唯一实现；未加载模型时推理请求返回 400）
   └── C ABI        llmprovider_start / load_model / api_key / …
```

**服务管理与对话请求使用不同通道**：对话请求不经过扩展原生 API，因此改用云端兼容端点时无需修改示例应用代码。

## 模型资产：入库分卷与各端合并时机

GitHub 单文件上限 100 MiB，单个 GGUF 约 378 MiB，因此只入库
`KuiklyLLMProviderAssets/models/parts/` 下的 12 个 32 MiB 分卷，完整 `.gguf` 被 `.gitignore` 排除。

| 平台 | 合并时机 | 产物形态 | 运行时 |
|---|---|---|---|
| Android | 不合并，分卷直接进 AAR | `assets/model_parts/part_*.bin` | `start()` 阶段在后台合并到 `filesDir/models/` |
| iOS | `pod install` 期（`prepare_command` → `scripts/merge-model-parts.sh`） | `Resources/model.gguf` | 从 `KuiklyLLMProviderModels.bundle` 子 bundle 取真实文件路径 |
| HarmonyOS | 构建期（`scripts/prepare-variant.sh bundled` → `scripts/merge-model-parts.sh`） | `resfile/model.gguf` | 直接使用资源路径 |

llama.cpp 需要可 `mmap` 的真实文件路径；iOS / 鸿蒙的资源安装后即为真实文件，只有 Android `assets`
是 APK 条目，必须运行时合并。

### 完整性校验时机

size + SHA-256 严格校验只在文件落到最终路径之前执行一次，之后 start / select 只检查 size + GGUF 魔数：

| 场景 | Android | iOS | HarmonyOS |
|---|---|---|---|
| 下载完成 | `.part` 严格校验后 rename | 暂存为 `.verifying`，严格校验后 rename | `.part` 严格校验后 rename（要求 200 / 续传 206） |
| 内置模型 | 首次合并的 `.merging` 严格校验后 rename | 签名包内，构建期已校验 | 签名包内，构建期已校验 |
| start / select | size + 魔数 | size + 魔数 | size + 魔数 |

前提：最终路径只经「严格校验 → 同目录原子 rename」写入，且位于应用私有目录（Android `filesDir`、
iOS `Library/Application Support/KuiklyLLMProvider/models`、鸿蒙 `filesDir`）。

### 下载源与备用源

`catalog.json` 的 `url_primary`（魔搭）/ `url_backup`（Hugging Face）互为主备。同一模型只有一个
`sha256` / `bytes`，两个镜像字节一致，允许跨源续传。

每个模型每轮下载最多切一次备用源，备用源也失败后才把错误写进 `error`：

| 主源失败情形 | 切备用源的方式 |
|---|---|
| 收到响应体之前连接失败 / 返回非 2xx | 沿用 `.part` 已有进度续传，不截断；全新下载则从头开始 |
| 已收到数据后中途断开 | 不切源，保留 `.part` 并报错，由用户续传 |
| 全新下载完成后长度或 SHA-256 不符 | 删除 `.part`，从头重新下载 |
| 续传完成后长度或 SHA-256 不符 | 不切源，删除 `.part` 并报错 |

三端差异：

| | Android | iOS | 鸿蒙 |
|---|---|---|---|
| 切源时的进度 | 沿用 `.part` | 一律从头（resumeData 绑定原 URL，失败时已不可用） | 沿用 `.part`；截断错误页失败时从头 |
| 中途断开 | 记错误，保留 `.part` | 系统给出 resumeData 时转暂停，否则按连接失败切源 | 记错误，保留 `.part`；续传未确认 Content-Range 起点时截回续传起点 |
| 用户续传用哪个源 | 主源 | 有 resumeData 沿用其绑定的源，否则主源 | 主源 |

暂停 / 取消不触发切源。例外：iOS 沿用备用源的 resumeData 续传时仍在本轮内，不再切源。

## 模型状态流转

```
内置变体: bundled → (合并与校验) → ready → active
下载变体: not_available → downloading → paused / error → verifying → ready → active
```

`models()` 的每项包含 `state`、`downloaded/total`（进度）、`active`、`bundled` 和 `actions`。
示例应用按 `actions` 渲染操作，两个发布变体共用同一套界面代码。

## 调用链（一次流式对话）

1. 页面 `acquireModule<LLMProviderModule>()` 后调用 `startServer()` → 三端 `KRLLMProviderModule.startServer`
2. 三端在进程级串行队列中执行 start / stop / select / delete（不占用调用线程，按调用顺序生效）：Android 先 `ensureBundled()` 合并分卷
   （仅内置变体），iOS / 鸿蒙直接使用签名包内资源 → `firstReady()` → `llmprovider_start(port, path, id)`
   启动 HTTP 服务；`activeId` 以 `llmprovider_model_id()` 回填（服务已运行时 start 幂等，不会换模型）
3. `LLMProviderModule.models()` 轮询状态；用户选中模型 → `modelAction("select")` → `llmprovider_load_model(path, id)`。
   换模型采用「先卸后载」以避免新旧两份权重同时驻留导致 OOM：加载期间推理请求返回 400，
   加载失败后服务处于无模型状态，`activeId` 以 `llmprovider_model_id()` 回填为空
4. 页面通过 `NetworkModule.httpStreamRequest` 发送 `POST /v1/chat/completions (stream=true)` 请求
5. C++ `handle_completion` 校验 `model` 与当前加载模型一致 → 引擎生成 → SSE 分片回传。
   SSE 响应头延迟到首个输出片段才发送：prompt 超出上下文返回 400，prompt 阶段引擎失败返回 500
   （均为 JSON 错误体）；已开始输出后的失败只能以 `finish_reason: "error"` 结束事件流
6. 页面通过 `SseLineParser` 累积解析，按增量内容渲染

## 消息中的特殊 token

prompt 经 GGUF 内置 chat template 拼接后整体 tokenize，并解析特殊 token（与上游 llama.cpp server
行为一致）。因此消息内容里的 `<|im_start|>` 等文本会被当作控制 token，可伪造角色边界。
服务只监听 127.0.0.1 且要求 Bearer 鉴权，调用方是宿主 App 自身；若宿主会把不可信的第三方文本
直接放进消息，应在宿主侧自行过滤或转义。

## `/v1/models` 的语义

只返回**当前已加载且可立即生成内容**的模型（0 或 1 个）。已下载但未加载的模型不在此列表中，
其状态由 `models()` 返回的 `state` 字段呈现（`ready` 等取值）。

## 两个发布变体的差异

| 维度 | download | bundled |
|---|---|---|
| 代码 | 完全相同 | 完全相同 |
| API | 完全相同 | 完全相同 |
| `catalog.json` | 三个 `bundled:false` | 第一个 `bundled:true` |
| 三端资产 | catalog + LICENSE + NOTICE | 额外 1 个 GGUF（Android 为分卷） |
| KMP 契约层 | 同一个 `KuiklyLLMProvider` 坐标 | 同一个 `KuiklyLLMProvider` 坐标，不分变体 |
| 各端产物坐标 | `KuiklyLLMProviderAndroid` | Android AAR `-Bundled`、独立 Pod / HAR 名称 |
| 分发渠道 | JitPack（Maven）、GitHub tag（Pod）、GitHub Release（HAR） | 同左；bundled Pod 额外 `prepare_command` |

## 标识符与商标边界

- 代码标识符中不出现 `OpenAI` 或 `Qwen`；相关兼容性描述只出现在文档中
- 模型 id 与 GGUF 文件名属于数据值或资产名，不视为代码标识符，用于 `/v1/models` 与下载 URL
- `ChatCompletionsTransport` 按端点命名，避免将商标写入类名

## 注册与编排

本组件只导出 `LLMProviderModule` 与契约常量，不提供全局入口对象，也不提供注册映射。
`createExternalModules()` 的编排权属于宿主：由宿主协调层聚合本组件 Module、宿主自有 Module
与其它三方 Module，并在启动期检测模块名冲突（iOS 侧类名必须等于 `moduleName()`，
名字是不可运行时修改的跨端契约）。

进程级资源（C ABI 全局 `g_server`、监听端口、加载中的 GGUF 与 llama context）
由宿主 Application 统一管理启停；Pager 只持有自己的 Module 与回调，销毁时
`dispose()` 丢弃迟到回调并停止轮询，**不 stop 服务**。`llmprovider_start` 幂等
仅用于避免重复启动，不替代宿主编排。

### 端口与凭据

不指定端口（`port=0`）时由内核分配随机端口，不指定 apiKey 时随机生成
`kuikly-<22 字符 base64url>`（128 bit 系统熵），
两者都以 `startServer` 回调 / `status()` 的 `baseUrl`、`apiKey`、`port` 为唯一来源。

- `stop()` → `start()`：销毁服务并重建，分配新端口、生成新 apiKey，页面用回调覆盖旧值。
- 服务运行中重复 `start()`：幂等返回，不轮换端口和 apiKey，避免页面持有的凭据失效。
- `stop()` 之后 `base_url` / `port` / `api_key` 清空，不再保留失效地址。

调试时不能用固定转发规则，需先读 `llmprovider_port()` 再设置 `adb forward` / `hdc fport`。
