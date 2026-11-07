#!/bin/sh
# 为 CocoaPods 消费者补齐 resource_bundles 所需的合规文件与模型清单。
# :git/:tag checkout 不含这些生成物（.gitignore 排除）；:path 本地集成时
# iosApp/Podfile 已生成，故 catalog.json 与 model.gguf 只在缺失时补，不覆盖。
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${1:-download}
case "$VARIANT" in download|bundled) ;; *) echo "usage: $0 download|bundled" >&2; exit 2;; esac

ASSETS="$ROOT/KuiklyLLMProviderAssets"
RES="$ROOT/KuiklyLLMProviderIOS/Resources"
LEGAL="$RES/legal"
mkdir -p "$LEGAL"
cp "$ASSETS/LICENSE" "$LEGAL/LICENSE"
cp "$ASSETS/NOTICE.md" "$LEGAL/NOTICE.md"

if [ ! -f "$LEGAL/catalog.json" ]; then
  python3 "$ROOT/scripts/derive_catalog.py" "$VARIANT" "$LEGAL"
fi

# merge-model-parts.sh 自身幂等：已有文件 size + SHA-256 校验通过才跳过，否则重新合并。
if [ "$VARIANT" = bundled ]; then
  "$ROOT/scripts/merge-model-parts.sh" "$RES/model.gguf"
fi
