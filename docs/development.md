# 开发文档

## 工程结构

| 目录 | 说明 |
|---|---|
| `KuiklyLLMProvider` | KMP 跨端层：`LLMProviderModule`（唯一 API）、`LLMProviderContract`（internal 契约生成源） |
| `KuiklyLLMProviderAndroid` | 独立 Android AAR：`KRLLMProviderModule`、`ModelStore`、`LLMProviderNativeBridge`；JNI `.so` 由 `externalNativeBuild` 构建期自产 |
| `KuiklyLLMProviderIOS` 与 `KuiklyLLMProviderIOS.podspec` | 独立 iOS Pod：`KRLLMProviderModule.h/.mm`，类名即 Module 名 |
| `KuiklyLLMProviderOhos` | 独立 HarmonyOS HAR：ArkTS Module、NAPI 桥与随包分发的 `libllm_provider.so` |
| `KuiklyLLMProviderNative` | 共享 C++ 源码（`src/`）：兼容 OpenAI API 的 HTTP 服务、llama.cpp 引擎与内部 C ABI（`provider_c_api.h` / `.cpp` 同名成对）；JNI / NAPI / ObjC 桥各归平台模块。`prebuilt/llama/` 另存三端交叉编译的第三方静态库与公共头（依赖产物，不是平台实现） |
| `KuiklyLLMProviderAssets` | 模型清单、内置模型、LICENSE 与 NOTICE 的唯一来源 |
| `shared` | 示例应用页面（Kotlin commonMain） |
| `androidApp` / `iosApp` / `ohosApp` | 各平台宿主应用 |
| `docs` / `marketplace` | 文档与组件市场登记 |

## 版本配置

`gradle.properties` 是唯一配置源，发布脚本通过 `-P` 参数覆盖：

| 属性 | 说明 |
|---|---|
| `MODULE_NAME` | 组件模块名 `KuiklyLLMProvider` |
| `MAVEN_VERSION` | **纯包版本** `0.1.1`；Pod / HAR 均使用该值 |
| `GROUP_ID` | Maven publication 的 groupId `com.github.iPel.KuiklyLLMProvider`（按 JitPack 多模块规则推导） |
| `KOTLIN_VERSION_LIST` | 标准工具链 `2.1.21`（逗号分隔） |
| `OHOS_KOTLIN_VERSION_LIST` | 鸿蒙工具链 `2.0.21-KBA-010` |
| `KUIKLY_VERSION` / `KUIKLY_OHOS_VERSION` | Kuikly 版本标记；Gradle 依赖的实际取值由 `buildSrc/src/main/java/KotlinBuildVar.kt` 的 `Version.getKuiklyVersion()` 提供 |
| `MAVEN_REPO_URL` | 自建 Maven 仓库地址；留空时使用本地 `build/repo` |
| `PROVIDER_VARIANT` | 默认变体 `bundled`（内置模型，离线可用） |

凭据不写入本文件。推荐通过 `ORG_GRADLE_PROJECT_mavenUsername` /
`ORG_GRADLE_PROJECT_mavenPassword` 环境变量传递，Gradle 会自动映射为 `-P` 属性。
`scripts/publish-maven.sh` 的 `-u/-p` 是 `--username` / `--password` 的短选项，
参数值会留在 shell 历史与进程列表中；脚本仅保证口令不进入 Gradle 命令行。

### 版本与 tag 规则

`scripts/release.sh` 是唯一派生入口，其余脚本按同样规则各自拼接：

| 用途 | 格式 | 当前值 |
|---|---|---|
| Pod / HAR 包版本 | `MAVEN_VERSION` | `0.1.1` |
| Maven 坐标版本、标准 git tag / GitHub Release | `{MAVEN_VERSION}-{KOTLIN_VERSION_LIST[0]}` | `0.1.1-2.1.21` |
| 鸿蒙 Maven 坐标版本 / JitPack 触发 tag | `{MAVEN_VERSION}-{OHOS_KOTLIN_VERSION_LIST[0]}` | `0.1.1-2.0.21-KBA-010` |

`scripts/release.sh -v` 只接受纯包版本，带工具链后缀会被拒绝（否则坐标会二次拼接）。
Kotlin 后缀只落在 Maven 坐标与 git tag 上，不进入 Pod / HAR 的包版本。
**KMP 契约层不分变体**；只有 Android AAR 用 `-Bundled` artifactId、iOS 用独立 Pod、
鸿蒙用独立 HAR 包名区分 download / bundled。

### 构建工具链版本

`build.gradle.kts` 显式指定 `com.android.tools:r8:8.6.17`。根工程使用 AGP 8.2.2，其自带的
D8/R8 8.2.47 无法解析 Kotlin 2.1.21 的 metadata；按
[Android 官方版本要求](https://developer.android.com/build/kotlin-support)，Kotlin 2.1 需要
R8 8.6.17 及以上。鸿蒙构建使用独立的 `build.ohos.gradle.kts` 作为根构建脚本，不受此项影响。

Android 的 `libllm_provider.so` 由 `KuiklyLLMProviderAndroid` 的 `externalNativeBuild` 在模块构建期
编译共享 C++ 源码产出，AGP 自动打包进 AAR 的 `jni/arm64-v8a/`，仓库不入库预编译 `.so`。
`ndkVersion` 锁在 `26.0.10792818`、CMake `3.22.1`；`-DANDROID_STL=c++_static` 保证 AAR 只分发
一个 `.so`，宿主无需自带 `libc++_shared.so`。`abiFilters` 只留 `arm64-v8a`（仓库只入库该 ABI
的 llama.cpp 静态库）。JitPack 侧由 AGP 按 `ndkVersion` / `externalNativeBuild.cmake.version` 自动安装。

## 构建

```bash
# Android：native 由 externalNativeBuild 自动编译，无需单独执行脚本
./gradlew :androidApp:assembleDebug -c settings.gradle.kts

# iOS（先生成 framework，再执行 pod install）
./gradlew :shared:syncFramework -Pkotlin.native.cocoapods.platform=iphonesimulator \
  -Pkotlin.native.cocoapods.archs=arm64 -Pkotlin.native.cocoapods.configuration=Debug
cd iosApp && pod install
xcodebuild -workspace iosApp.xcworkspace -scheme iosApp -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build

# HarmonyOS（entry/hvigorfile.ts 的内联 task 在 PreBuild 前自动关联编译）
./ohosApp/build-hap.sh

# 需要强制重建 Kotlin/Native 产物时单独执行
./ohosApp/build-so.sh

# 手动强制重编 Android native 并产出调试符号（正常构建不需要）
./scripts/build-android-native.sh
```

**全新 clone 的首次构建前置**（等价于 `git clean -fdx` 之后的状态）：

| 端 | 必需步骤 | 跳过后的报错 |
|---|---|---|
| Android | 配置 `ANDROID_HOME`（或自建 `local.properties` 写 `sdk.dir`） | Gradle: SDK location not found |
| iOS | `pod install` **之前**先跑 `./gradlew :shared:generateDummyFramework`（轻量占位，Xcode 构建时再触发真实 framework），或执行上面带 cocoapods 参数的 `:shared:syncFramework` | `shared.podspec`: `Kotlin framework 'shared' doesn't exist yet` |
| HarmonyOS | `cd ohosApp && ohpm install` | `BuildNativeWithNinja` 找不到 `oh_modules/@kuikly-open/render/.../libkuikly.so` |

模型资产无需手工准备：`iosApp/Podfile`、各端发布与构建脚本都会调用
`scripts/prepare-variant.sh bundled`，从 `KuiklyLLMProviderAssets/models/parts/` 的 12 个入库分卷重建。
在注入了 `NODE_OPTIONS` 删除 shim 的 IDE / 代理环境里，`ohpm` 与 `hvigorw` 可能报
`SAFE_DELETE_BULK_CONFIRM_REQUIRED`，此时用 `env -u NODE_OPTIONS <命令>` 运行即可
（`scripts/publish-ohpm.sh` 内部已对 `hvigorw` 这样处理）。

只有 Android AAR 与鸿蒙 HAR 含本仓库编译的 native 二进制，需要 strip 与符号表；KMP 契约层、
iOS Pod（源码分发）都不需要。

- **Android**：CMake `POST_BUILD` 把未 strip 的 `.so` 留在模块 `build/native-symbols/`，
  Gradle 的 `nativeSymbolsZip` 打成 `-native-symbols.zip`，由 JitPack 与 AAR **同一次构建**一起发布。
  Release 上的 Android 符号必须取自该 JitPack 构件：本机构建路径不同、Build ID 不同，
  无法还原 JitPack AAR 的崩溃栈。`scripts/publish-symbols.sh` 下载后用 `scripts/verify_symbols.py`
  比对 AAR 与符号的 `NT_GNU_BUILD_ID`，一致才允许上传。
- **HarmonyOS**：`scripts/publish-ohpm.sh` 以 `-p buildMode=release` 构建（HAR 缺省是 debug），
  每轮 `assembleHar` 后立刻取本次链接的符号并校验该 HAR 的 Build ID。
- **iOS**：Pod 按 `:git/:tag` 源码分发，dSYM 由接入方工程在编译期生成，
  本仓库不做 strip，也不归档符号。

两个变体对同一份符号表做 verify：Android 只在 `KuiklyLLMProviderAndroid` 坐标发布一份
`native-symbols` classifier，鸿蒙只归档 `dist/symbols/ohos/libllm_provider.so.unstripped`。

符号表统一由 `scripts/publish-symbols.sh` 打成 `dist/symbols-<version>.tar.gz`；符号表、两个 HAR 与
`SHA256SUMS` 发布到**标准 tag** 的同一个 GitHub Release，鸿蒙 tag 只用于 JitPack 分流。
JitPack 首次请求会异步触发构建，可能返回 404，也可能返回「HTTP 200 + 构建中页面」；
脚本把两者都视为未就绪，必须校验内容是有效 zip 才算下载成功，并按 `--wait` 轮询。
包内 `BUILD_IDS.txt` 记录每份符号的 Build ID、已校验构件列表与两个 HAR 的 sha256。
`scripts/build-android-native.sh` 会先 `clean` 以确保 CMake 重新链接，并自测 AAR / 符号 / 符号 zip
三者 Build ID 一致；它验证的是本机链路，不是发布用的符号来源。

HarmonyOS 的 `libshared.so` 与 `libshared_api.h` 不入库，由 `ohosApp/entry/hvigorfile.ts` 内联的
`kuikly_build_shared` task 在 `PreBuild` 前编译并拷回 `entry/`。`shared/build.ohos.gradle.kts`
的 `binaries.sharedLib` 不带名字，debug 对应 `linkDebugSharedOhosArm64` / `debugShared/`，
release 对应 `linkReleaseSharedOhosArm64` / `releaseShared/`。`build-so.sh` 仅用于手动强制重编。

### 启用 GGUF 推理（三端强制）

三端编译同一份 `KuiklyLLMProviderNative/src/`，且**必须**定义 `LLMPROVIDER_WITH_LLAMA=1`
并链接仓库内 `prebuilt/llama/` 的带符号静态库，缺头文件或缺任一 `.a` 都会中止。
`llama_engine.cpp` 在未定义宏时直接 `#error`；运行时未加载模型时，
`/v1/chat/completions` 由 HTTP 层以 400 显式拒绝。

| 入口 | 默认位置 | 覆盖方式 |
|---|---|---|
| `KuiklyLLMProviderAndroid/src/main/cpp/CMakeLists.txt` | `prebuilt/llama/android/arm64-v8a/` | `-PLLMPROVIDER_LLAMA_DIR=...` / `-PLLMPROVIDER_LLAMA_LIB_DIR=...`（或同名 CMake 变量 / 环境变量） |
| `KuiklyLLMProviderOhos/src/main/cpp/CMakeLists.txt` | `prebuilt/llama/ohos/arm64-v8a/` | `LLMPROVIDER_LLAMA_DIR` / `LLMPROVIDER_LLAMA_LIB_DIR` |
| `iosApp/Podfile` + 两个 podspec | `prebuilt/llama/ios-sim/arm64/` | `LLMPROVIDER_LLAMA_DIR` / `LLMPROVIDER_LLAMA_LIB_DIR`（环境变量） |

头文件统一在 `prebuilt/llama/include/`。iOS 侧宏与头文件路径由 podspec 的
`pod_target_xcconfig` 强制声明，静态库仍由宿主 `Podfile` 注入（仓库只入库模拟器 arm64
预编译库，绑进 podspec 会锁死架构）；宿主未提供时链接期直接失败。

Android 与鸿蒙的 llama.cpp 依赖完全归各自模块管理，宿主工程不解析库路径：

```bash
# Android
./gradlew :KuiklyLLMProviderAndroid:assembleRelease \
  -PLLMPROVIDER_LLAMA_LIB_DIR=/path/to/libs

# HarmonyOS（环境变量由子进程继承到 CMake）
LLMPROVIDER_LLAMA_DIR=/path/to/llama.cpp \
LLMPROVIDER_LLAMA_LIB_DIR=/path/to/llama.cpp/lib \
  ./ohosApp/build-hap.sh
```

只显式指定 `LLMPROVIDER_LLAMA_DIR` 且指向另一份源码树时，`LIB_DIR` 取 `${DIR}/lib`；
两个变量都不指定时使用仓库内 prebuilt 的头文件与静态库。

`libllm_provider.so` 在 Android 与 HarmonyOS 均由模块自身编译并随交付物分发
（Android AAR 的 `jni/`、HAR 的 `libs/arm64-v8a/`），宿主工程不编译原生层。
两端 CMake 的 `POST_BUILD` 都保留 unstripped 符号并 strip 交付物；Android 还会把
编译机主目录在字符串表里等长替换为中性路径（`sanitize_symbols.py`）。符号输出目录在各自
模块的 `build/native-symbols/`，不写入仓库根目录；鸿蒙侧该变量用
`CACHE ... FORCE`，避免 `.cxx/CMakeCache.txt` 把路径固定在先前的输出位置。
HAR 采用 DevEco 标准布局：native 源码、`CMakeLists.txt` 与 `types/libllm_provider/`
统一位于 `src/main/cpp/`，`externalNativeOptions.path` 指向 `./src/main/cpp/CMakeLists.txt`；
入口偏离该路径会让 `ConfigureCmake` / `BuildNativeWithCmake` / `BuildNativeWithNinja`
全部被跳过，产出的 HAR 不含 `.so`。Android 的 `externalNativeBuild.cmake.path` 同理，
且 `src/main/jniLibs/` 不得再放同名 `.so`，否则 `mergeNativeLibs` 会因重名失败。

`iosApp/Podfile` 在 `pod install` 时调用 `scripts/prepare-variant.sh bundled` 生成本地模型资产；
鸿蒙 `build-hap.sh` 同样直接调用该脚本。

## 两个发布变体

```bash
./scripts/prepare-variant.sh download   # 不含模型；三端仅包含 catalog.json、LICENSE、NOTICE.md
./scripts/prepare-variant.sh bundled    # 从入库分卷生成：Android 12 个分卷，iOS 与鸿蒙各一个 model.gguf
```

`bundled` 的资产来源统一是 `KuiklyLLMProviderAssets/models/parts/`（12 个 32 MiB 分卷，
已入库），不依赖本地 396 MB 原始 GGUF；JitPack 检出的源码中没有大文件也能复现同样产物：

- Android：把分卷复制到 `assets/model_parts/`，运行时在 `start()` 阶段合并；
- iOS / HarmonyOS：`scripts/merge-model-parts.sh` 在 `pod install` 期 / 构建期合并成单个 `model.gguf`。

```bash
./scripts/update-model.sh --url <URL> --sha256 <64-hex>    # 下载新 GGUF、校验、重新切分卷、回写 catalog
./scripts/update-model.sh --file /path/to/model.gguf        # 或用本地文件
./scripts/merge-model-parts.sh <output.gguf>                # 从分卷合并并校验 SHA-256 / 字节数
```

## 发布

| 脚本 | 作用 |
|---|---|
| `scripts/build-android-native.sh` | 手动 `clean + assembleRelease + nativeSymbolsZip`，产出 AAR、模块 `build/native-symbols/` 与符号 zip，并自测三者 Build ID 一致；正常构建无需执行 |
| `scripts/update-model.sh` | 下载 / 校验新 GGUF、切成 32 MiB 分卷、回写 catalog；不执行 git 操作，不发布 |
| `scripts/merge-model-parts.sh` | 从入库分卷合并出单个 `model.gguf` 并校验 SHA-256 与字节数 |
| `scripts/prepare-variant.sh` | 生成两个变体的模型清单与三端资产 |
| `scripts/publish-maven.sh` | KMP 每工具链一个坐标 + Android AAR 每变体一个；支持 `--variant download/bundled/all`、`--local`、`--android-only`、`-s`、`-m/-u/-p` |
| `scripts/publish-pod.sh` | 生成 `KuiklyLLMProviderIOSBundled.podspec`（注入 `prepare_command`）、可选 `pod spec lint`、打印 tag 指引 |
| `scripts/publish-ohpm.sh` | 以 `buildMode=release` 用 `hvigorw assembleHar` 产出两个 HAR、`SHA256SUMS` 与一份鸿蒙符号，并校验两个 HAR；退出时恢复 hvigor 自动改写的 `oh-package.json5` 与 `BuildProfile.ets`，不污染工作树 |
| `scripts/verify_symbols.py` | 解析 ELF 的 `NT_GNU_BUILD_ID`，比对 AAR/HAR 与符号（支持 zip / tar.gz），不依赖 NDK 工具链 |
| `scripts/publish-symbols.sh` | 从 JitPack 下载 `KuiklyLLMProviderAndroid` AAR 与 `native-symbols.zip`、逐构件校验 Build ID，汇总一份鸿蒙符号，打包并上传到标准 tag Release |
| `scripts/release.sh` | 同步包版本与两个 podspec 的 `:tag`，编排上述脚本；支持 `--dry-run` |
| `jitpack.yml` | 按 tag 分流：标准 tag 发 KMP + Android 两变体，`*-KBA-*` tag 只发鸿蒙 KMP |

### 分发矩阵

| 产物 | 渠道 | 版本 / tag |
|---|---|---|
| KMP（标准 Kotlin） | JitPack 标准 tag | Maven 版本 = `0.1.1-2.1.21` |
| KMP（鸿蒙 Kotlin） | JitPack 鸿蒙 tag | Maven 版本 = `0.1.1-2.0.21-KBA-010` |
| Android AAR × 2 变体 | JitPack 标准 tag | Maven 版本 = `0.1.1-2.1.21` |
| iOS Pod × 2 变体 | GitHub `:git/:tag` | 包版本 `0.1.1`，tag `0.1.1-2.1.21` |
| 鸿蒙 HAR × 2 变体 | GitHub Release assets（标准 tag） | 包版本 `0.1.1`，tag `0.1.1-2.1.21` |
| Android 符号 classifier | JitPack 标准 tag（随 `KuiklyLLMProviderAndroid`） | `KuiklyLLMProviderAndroid-0.1.1-2.1.21-native-symbols.zip` |
| 调试符号表（Android + 鸿蒙） | GitHub Release（**标准 tag**） | `symbols-0.1.1.tar.gz` + `.sha256` |

Maven 侧的坐标版本与 tag 相同，完整坐标表见根目录 [README.md](../README.md)；Pod / HAR 的
包版本始终为纯 `0.1.1`。GGUF 分卷随源码入库，JitPack 与 `pod install` 都从分卷复现产物，
不依赖 396 MB 原始文件。iOS 不做符号分发。

```bash
./scripts/release.sh --dry-run -v 0.1.1
./scripts/publish-maven.sh --local --variant download --android-only   # 本地发布验证
./scripts/release.sh -v 0.1.1                                         # 版本同步 + 本地产物

# 外部动作，脚本不自动执行
# 1) 标准 tag：JitPack 构建 KMP + Android 两变体；iOS Pod 与唯一 Release 共用同一 tag
git tag 0.1.1-2.1.21 && git push origin 0.1.1-2.1.21
# 鸿蒙 tag：只触发 JitPack 鸿蒙 KMP 构建，不建 Release
git tag 0.1.1-2.0.21-KBA-010 && git push origin 0.1.1-2.0.21-KBA-010
# 2) 标准 tag 的 Release：放两个 HAR 与校验文件（与符号表共用同一个 Release）
gh release create 0.1.1-2.1.21 dist/download.har dist/bundled.har dist/SHA256SUMS
# 3) 等 JitPack 构建完成后，把符号表发布到标准 tag 的 Release
./scripts/publish-symbols.sh -v 0.1.1 --wait 30 --upload
```

仓库地址为 `https://github.com/iPel/KuiklyLLMProvider`。

两个 iOS podspec 必须包含在同一个 tag 中，否则接入方无法解析 bundled Pod。
接入坐标按 JitPack 多模块规则推导，首次远端构建后需按构建日志核对实际输出。

## 测试

```bash
./gradlew :androidApp:compileDebugKotlin -c settings.gradle.kts
./gradlew :androidApp:assembleDebug -c settings.gradle.kts
./gradlew :KuiklyLLMProviderAndroid:externalNativeBuildRelease   # native 单测入口
./scripts/publish-maven.sh --local --variant download --android-only
./scripts/release.sh --dry-run
# 校验脚本：对任一 AAR/HAR 与对应符号文件比对 Build ID（不一致退出 1）
python3 scripts/verify_symbols.py <artifact.aar|har> <symbols.so|zip>
bash -n scripts/build-android-native.sh scripts/release.sh scripts/prepare-variant.sh scripts/update-model.sh \
  scripts/merge-model-parts.sh scripts/publish-maven.sh scripts/publish-pod.sh scripts/publish-ohpm.sh scripts/publish-symbols.sh
# 宿主侧 C++ 单元测试（纯头文件，不需要 llama.cpp / CMake）
clang++ -std=c++17 -IKuiklyLLMProviderNative/src \
  KuiklyLLMProviderNative/tests/think_splitter_test.cpp \
  -o /tmp/think_splitter_test && /tmp/think_splitter_test
# HttpServer 生命周期测试（apiKey 格式、port=0 端口分配；FakeEngine 桩，不链接 llama.cpp）
clang++ -std=c++17 -IKuiklyLLMProviderNative/src \
  KuiklyLLMProviderNative/tests/http_server_test.cpp \
  KuiklyLLMProviderNative/src/http_server.cpp \
  KuiklyLLMProviderNative/src/engine_common.cpp \
  -o /tmp/http_server_test && /tmp/http_server_test
```

## 合规文件位置

| 文件 | 位置 |
|---|---|
| 唯一来源 | `KuiklyLLMProviderAssets/LICENSE`、`NOTICE.md`、`catalog.json` |
| Android | `KuiklyLLMProviderAndroid/src/main/assets/legal/` 与 `assets/catalog.json` |
| iOS | `KuiklyLLMProviderIOS/Resources/legal/` |
| HarmonyOS | `KuiklyLLMProviderOhos/src/main/resources/resfile/` |
| 根目录与 HAR | `LICENSE`、`CHANGELOG.md`、`KuiklyLLMProviderOhos/LICENSE` |

修改合规内容后运行 `./scripts/prepare-variant.sh download` 同步到三端。

