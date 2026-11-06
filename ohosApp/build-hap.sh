#!/bin/sh
# 构建 HarmonyOS HAP（debug）。
#
# 用法：./ohosApp/build-hap.sh
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# 同步模型清单、内置模型与合规文件到 HAR 的 resfile
"$ROOT_DIR/scripts/prepare-variant.sh" bundled

cd "$SCRIPT_DIR"
hvigorw assembleApp --mode project -p product=default -p buildMode=debug --no-daemon
