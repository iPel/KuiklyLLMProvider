Pod::Spec.new do |spec|
  spec.name         = 'KuiklyLLMProviderIOSBundled'
  spec.version      = '0.1.1'
  spec.summary      = 'On-device OpenAI-compatible HTTP service module for Kuikly (iOS)'
  spec.description  = <<-DESC
    iOS native layer of KuiklyLLMProvider - an on-device OpenAI-compatible HTTP service. Contains KRLLMProviderModule
    (KRBaseModule subclass, class name equals the Kuikly module name) plus the shared
    C++ implementation. The KMP cross-platform layer is published separately.
  DESC
  spec.homepage     = 'https://github.com/iPel/KuiklyLLMProvider'
  spec.license      = { :type => 'Apache-2.0', :file => 'LICENSE' }
  spec.authors      = { 'iPel' => '' }
  spec.source       = { :git => 'https://github.com/iPel/KuiklyLLMProvider.git', :tag => '0.1.1-2.1.21' }

  spec.ios.deployment_target = '14.1'
  # bundled 版在 pod install 期从入库分卷合并回单个 GGUF，并补齐合规文件与模型清单。
  spec.prepare_command = 'bash scripts/prepare-pod-assets.sh bundled'

  # 独立 pod 只含 iOS 原生 Module 与共享 C++ 源码；KMP 层由 shared framework 提供
  spec.source_files = [
    'KuiklyLLMProviderIOS/**/*.{h,m,mm}',
    'KuiklyLLMProviderNative/src/**/*.{h,hpp,cpp}',
  ]
  # 只把平台 Module 的类声明公开给宿主；共享 C++ 的头（含 provider_c_api.h）
  # 都是 Pod 内部实现细节，不进 framework 的公共 Headers。
  spec.public_header_files = 'KuiklyLLMProviderIOS/KRLLMProviderModule.h'
  spec.private_header_files = 'KuiklyLLMProviderNative/**/*.{h,hpp}'

  # download 变体不含模型文件，由应用在运行时下载；bundled 变体在 pod install 期
  # 通过 prepare_command 把入库分卷合并成此 glob 匹配的单文件。
  spec.resource_bundles = {
    'KuiklyLLMProviderModels' => ['KuiklyLLMProviderIOS/Resources/*.gguf'],
    'KuiklyLLMProviderLegal' => [
      'KuiklyLLMProviderIOS/Resources/legal/LICENSE',
      'KuiklyLLMProviderIOS/Resources/legal/NOTICE.md',
      'KuiklyLLMProviderIOS/Resources/legal/catalog.json',
    ],
  }

  spec.dependency 'OpenKuiklyIOSRender'
  spec.libraries = 'c++'
  # LLMPROVIDER_WITH_LLAMA 是强制要求：漏配时 llama_engine.cpp 直接 #error，
  # 不会生成只能回显假内容的模拟引擎。
  spec.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) LLMPROVIDER_WITH_LLAMA=1',
    'HEADER_SEARCH_PATHS' => '$(PODS_TARGET_SRCROOT)/KuiklyLLMProviderNative/src $(PODS_TARGET_SRCROOT)/KuiklyLLMProviderNative/prebuilt/llama/include',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
  }

  # llama.cpp / ggml 静态库仍由宿主 Podfile 注入：仓库内只有 ios-sim/arm64
  # 预编译库，写进 vendored_libraries 会把 Pod 锁死在模拟器架构。
  # 宿主未提供 libllama.a / libggml*.a 时会直接链接失败，不静默退化。
end
