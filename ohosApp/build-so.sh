#!/bin/sh
# 手动重建 HarmonyOS 侧的 Kotlin 产物 libshared.so / libshared_api.h。
# 常规构建由 entry/hvigorfile.ts 自动完成；本脚本用于强制重编。
#
# 用法：./ohosApp/build-so.sh
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

SO_OUT="$ROOT_DIR/shared/build/bin/ohosArm64/debugShared/libshared.so"
H_OUT="$ROOT_DIR/shared/build/bin/ohosArm64/debugShared/libshared_api.h"
LIBS_DIR="$SCRIPT_DIR/entry/libs/arm64-v8a"
BIZ_DIR="$SCRIPT_DIR/entry/src/main/cpp/thirdparty/biz_entry"

echo "==> 链接 shared (ohosArm64)"
cd "$ROOT_DIR"
KUIKLY_AGP_VERSION=7.4.2 \
KUIKLY_KOTLIN_VERSION=2.0.21-KBA-010 \
  ./gradlew -c settings.ohos.gradle.kts :shared:linkDebugSharedOhosArm64 --stacktrace

if [ ! -f "$SO_OUT" ]; then
  echo "链接已完成，但未找到产物：$SO_OUT" >&2
  exit 1
fi

echo "==> 拷贝产物到 entry"
mkdir -p "$LIBS_DIR" "$BIZ_DIR"
cp "$SO_OUT" "$LIBS_DIR/"
cp "$H_OUT" "$BIZ_DIR/"

echo "==> 完成"
ls -la "$LIBS_DIR/libshared.so"
