#!/bin/sh
# 用法：./scripts/build-android-native.sh [额外 Gradle 参数]
#   ./scripts/build-android-native.sh -PLLMPROVIDER_LLAMA_LIB_DIR=/path/to/libs
set -e

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

# clean 保证 CMake 一定重新链接，POST_BUILD 才会写出模块 build/native-symbols/。
./gradlew :KuiklyLLMProviderAndroid:clean \
          :KuiklyLLMProviderAndroid:assembleRelease \
          :KuiklyLLMProviderAndroid:nativeSymbolsZip --no-daemon "$@"

MOD="$ROOT_DIR/KuiklyLLMProviderAndroid/build"
SYMBOL="$MOD/native-symbols/libllm_provider.so.unstripped"
SYMBOL_ZIP="$MOD/native-symbols-zip/native-symbols.zip"
AAR="$MOD/outputs/aar/KuiklyLLMProviderAndroid-release.aar"
for f in "$SYMBOL" "$SYMBOL_ZIP" "$AAR"; do
  if [ ! -f "$f" ]; then
    echo "缺少产物：$f" >&2
    echo "请确认 externalNativeBuild 的 POST_BUILD 已执行（clean 后重试）。" >&2
    exit 1
  fi
done
python3 scripts/verify_symbols.py "$AAR" "$SYMBOL"
python3 scripts/verify_symbols.py "$AAR" "$SYMBOL_ZIP"
echo "==> 符号产物：$SYMBOL"
echo "==> 符号构件：$SYMBOL_ZIP"
echo "==> AAR：$AAR"
ls -la "$SYMBOL" "$SYMBOL_ZIP" "$AAR"
