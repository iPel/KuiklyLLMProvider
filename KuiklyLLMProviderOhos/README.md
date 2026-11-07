# KuiklyLLMProviderOhos

HarmonyOS 原生层 HAR，实现 Kuikly 扩展原生 API `KRLLMProviderModule`：在设备上启动兼容 OpenAI API 的本地 HTTP 服务，并提供模型下载与管理。配合 `KuiklyLLMProvider`（KMP 层）使用。

## 安装

**方式一：从 [GitHub Release](https://github.com/iPel/KuiklyLLMProvider/releases/tag/0.1.1-2.1.21) 下载 HAR 后本地安装：**

```bash
ohpm install ./download.har     # 或 ./bundled.har
```

```json5
// oh-package.json5
"dependencies": {
  "@ipel/llm-provider-ohos": "file:./download.har"
}
```

**方式二：从 OpenHarmony 三方库中心仓安装：**

`download` 版（[查看可用版本](https://ohpm.openharmony.cn/#/cn/detail/@ipel%2Fllm-provider-ohos)）：

```bash
ohpm install @ipel/llm-provider-ohos
```

或`bundled` 版（[查看可用版本](https://ohpm.openharmony.cn/#/cn/detail/@ipel%2Fllm-provider-bundled-ohos)）：

```bash
ohpm install @ipel/llm-provider-bundled-ohos
```

完整坐标表见根目录 [README.md](../README.md)。

## 使用

在 `KuiklyViewDelegate` 中注册 Module（import 路径按所选版本替换）：

```ts
import { KRLLMProviderModule } from '@ipel/llm-provider-ohos';

map.set(KRLLMProviderModule.MODULE_NAME, () => new KRLLMProviderModule());
```

业务页面通过 `LLMProviderModule.startServer()` 启动服务，再用标准 HTTP 向回调返回的 `baseUrl` 发送请求，请求头携带 `Authorization: Bearer <apiKey>`。

## 依赖要求

- `@kuikly-open/render` >= 2.30.0
- `llm_provider` NAPI 模块：`libllm_provider.so` 随 HAR 分发于 `libs/arm64-v8a/`，接入方无需编译 C++
