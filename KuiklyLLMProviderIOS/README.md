# KuiklyLLMProviderIOS

独立 iOS Pod，实现 `KRLLMProviderModule`。类名与 Module 名一致，iOS 无需手动注册。
接入方式见仓库根目录 [README.md](../README.md) 与 `KuiklyLLMProviderIOS.podspec`。

两个 Pod 都从 GitHub `:git/:tag` 引用，共用标准 tag `0.1.2-2.1.21`，包版本均为 `0.1.2`：

| 版本 | Pod 名 |
|---|---|
| `download` | `KuiklyLLMProviderIOS` |
| `bundled` | `KuiklyLLMProviderIOSBundled` |

完整 Podfile 写法见根目录 [README.md](../README.md)。

## 依赖要求

Pod 强制定义 `LLMPROVIDER_WITH_LLAMA=1` 并引用 `KuiklyLLMProviderNative/prebuilt/llama/include`；
宿主 Podfile 必须注入 `libllama.a` / `libggml*.a`（demo 见 `iosApp/Podfile`，默认取
`prebuilt/llama/ios-sim/arm64/`）。未提供静态库会在链接期失败。
