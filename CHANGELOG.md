# Changelog

## 0.1.2

- 修复断点续传时因缺少 Content-Length 跳过 SHA-256 校验并删除正确分卷
- HarmonyOS：`napi_cancelled` 无回调时增加超时兜底；`serverStatus.ok` 与另两端对齐
- iOS Pod：补齐 LICENSE、NOTICE 与 catalog，已有模型不再被覆盖
- 发布脚本不再把派生变体写回基准 catalog，`--no-pack` 不再删除已有产物
- HAR 元数据补齐 author / repository / homepage，README 增加中心仓安装方式

## 0.1.1

- 首个版本：端侧模型服务组件，支持 Android、iOS 与 HarmonyOS
- 两个版本：`download`（不含模型）、`bundled`（内置 1 个模型）
- 三个 Unsloth Q4_K_M 模型：Qwen3-0.6B、Qwen3.5-0.8B、Qwen3.5-2B；主要下载源为魔搭，备用下载源为 Hugging Face；SHA-256 校验与断点续传
- 服务管理 API：`start` / `stop` / `status` / `models` / `modelAction`（下载、暂停、续传、取消、切换、删除）
- HTTP 端点：`/health`、`/v1/models`（仅返回当前已加载模型）、`/v1/chat/completions`、`/v1/completions`，支持 SSE
- 示例应用：模型选择、下载进度、思考开关与设置浮层
