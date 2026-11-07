# Changelog

## 0.1.2

- `napi_cancelled` 无回调时增加超时兜底；`serverStatus.ok` 与 Android/iOS 对齐
- 补齐 HAR 元数据与中心仓安装说明

## 0.1.1

- HarmonyOS HAR：KRLLMProviderModule（模型管理与服务控制）
- NAPI 桥 `libllm_provider.so`：启动、停止、加载模型、状态查询
- 支持 `resfile` 内置模型与 `requestInStream` 下载
