# KuiklyLLMProviderOhos

HarmonyOS 原生层 HAR，实现 Kuikly 扩展原生 API `KRLLMProviderModule`。
配合 `KuiklyLLMProvider`（KMP 层）使用；接入方式见仓库根目录 [README.md](../README.md)。

## 安装

两个 HAR 以 GitHub Release（tag `0.1.1-2.1.21`）的 assets 分发，不经 ohpm 中心仓；
包版本均为纯 `0.1.1`。下载后本地安装：

```bash
ohpm install ./download.har     # 或 ./bundled.har
```

```json5
// oh-package.json5
"dependencies": {
  "@ipel/llm-provider-ohos": "file:./download.har"
}
```

`download` 版本包名为 `@ipel/llm-provider-ohos`，`bundled` 版本包名为
`@ipel/llm-provider-bundled-ohos`。完整坐标表见根目录 [README.md](../README.md)。

## 依赖要求

- `@kuikly-open/render` >= 2.30.0
- `llm_provider` NAPI 模块：`libllm_provider.so` 随 HAR 分发于 `libs/arm64-v8a/`，接入方无需编译 C++

## 权限

`src/main/module.json5` 已声明 `ohos.permission.INTERNET`（模型下载需要）。

## 注册

```ts
import { KRLLMProviderModule } from '@ipel/llm-provider-ohos';

map.set(KRLLMProviderModule.MODULE_NAME, () => new KRLLMProviderModule());
```
