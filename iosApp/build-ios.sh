#!/bin/sh
# 构建 iOS 示例应用（模拟器 arm64）。
#
# 用法：./iosApp/build-ios.sh
#
# 本仓库不发布 iOS 二进制，不归档符号表、也不 strip Pods framework。
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DERIVED="$SCRIPT_DIR/build/DerivedData"

cd "$SCRIPT_DIR"
pod install --no-repo-update
xcodebuild -workspace iosApp.xcworkspace -scheme iosApp \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build

echo "==> iOS 示例应用构建完成（无发布产物，无需 strip / 符号归档）"
