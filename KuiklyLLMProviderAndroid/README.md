# KuiklyLLMProviderAndroid

独立 Android AAR，实现 `KRLLMProviderModule`，内含 `ModelStore`（下载 / 分卷合并 / SHA-256 校验）
与 `libllm_provider.so`（共享 C++ 引擎）。接入方式见仓库根目录 [README.md](../README.md)。

Maven 坐标（经 JitPack 分发）：

- `com.github.iPel.KuiklyLLMProvider:KuiklyLLMProviderAndroid:0.1.2-2.1.21`
- `com.github.iPel.KuiklyLLMProvider:KuiklyLLMProviderAndroid-Bundled:0.1.2-2.1.21`（内置模型）

## Native 构建

`libllm_provider.so` 由本模块的 AGP `externalNativeBuild` 在构建期编译
`src/main/cpp/CMakeLists.txt` 产出，自动打包进 AAR 的 `jni/arm64-v8a/`；仓库不入库预编译 `.so`，
接入方不需要 NDK。JNI 桥 `src/main/cpp/android_jni.cpp` 属于本模块，
`CMakeLists.txt` 只从 `KuiklyLLMProviderNative/` 引用三端共享的协议与引擎源码。从源码构建需要 Android NDK `26.0.10792818` 与 CMake `3.22.1`
（JitPack 由 AGP 按 `ndkVersion` / `externalNativeBuild.cmake.version` 自动安装）。

共享 C++ 引擎强制依赖 `KuiklyLLMProviderNative/prebuilt/llama/android/arm64-v8a/` 的
llama.cpp / ggml 静态库，缺库即构建失败。

未 strip 的 `libllm_provider.so` 由 CMake `POST_BUILD` 留在模块 `build/native-symbols/`，
Gradle 的 `nativeSymbolsZip` 打成 `-native-symbols.zip`，只随 `KuiklyLLMProviderAndroid` 坐标发布一份；
两个版本共用这份符号，校验方式见[开发文档](../docs/development.md)。手动强制重编并自测三者 Build ID 一致：

```bash
./scripts/build-android-native.sh
```


