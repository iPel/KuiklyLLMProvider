#!/bin/sh
# Prepare one of the two published variants of KuiklyLLMProvider (asset stage only).
#   ./scripts/prepare-variant.sh download  -> 0 bundled models, for Play / app-store channels
#   ./scripts/prepare-variant.sh bundled   -> 1 bundled model, for self-distributed / offline channels
# Publishing is done by publish-maven.sh / publish-pod.sh / publish-ohpm.sh (or release.sh).
# Both variants share exactly the same code and API; only catalog.json and assets differ.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${1:-bundled}
case "$VARIANT" in download|bundled) ;; *) echo "usage: $0 download|bundled" >&2; exit 2;; esac

ASSETS="$ROOT/KuiklyLLMProviderAssets"
A_ANDROID="$ROOT/KuiklyLLMProviderAndroid/src/main/assets"
A_IOS="$ROOT/KuiklyLLMProviderIOS/Resources"
A_OHOS="$ROOT/KuiklyLLMProviderOhos/src/main/resources/resfile"

echo "==> variant=$VARIANT"
# Always ship legal files in both variants.
for D in "$A_ANDROID/legal" "$A_IOS/legal" "$A_OHOS"; do
  mkdir -p "$D"
  cp "$ASSETS/LICENSE" "$D/LICENSE"
  cp "$ASSETS/NOTICE.md" "$D/NOTICE.md"
done

# 删除前断言 ROOT 为绝对路径，且每个目标都必须位于 ROOT 之内，
# 避免变量异常（为空 / 被覆盖）时误删项目外文件。
case "$ROOT" in
  /*) ;;
  *) echo "无法确定项目根目录（非绝对路径）：$ROOT" >&2; exit 1;;
esac
assert_safe_path() {
  case "$1" in
    "$ROOT"/*) ;;
    *) echo "拒绝删除非项目内路径：$1" >&2; exit 1;;
  esac
}
for target in "$A_ANDROID/model_parts" "$A_IOS/model.gguf" "$A_OHOS/model.gguf"; do
  assert_safe_path "$target"
done

# Clean any previously injected weights/parts.
rm -rf "$A_ANDROID/model_parts" "$A_IOS/model.gguf" "$A_OHOS/model.gguf"

python3 - "$ROOT" <<'PY'
import json, sys, os
root = sys.argv[1]
cat = json.load(open(os.path.join(root, "KuiklyLLMProviderAssets/catalog.json")))

# 按 catalog 的显式文件清单清理 OHOS resfile 下旧权重，不使用 shell 的
# Qwen*.gguf 通配符；删除前用 realpath + commonpath 断言仍在项目根内。
# 清单随 catalog 自动同步，新增模型无需改脚本。
root = os.path.realpath(root)
resfile = os.path.join(root, "KuiklyLLMProviderOhos/src/main/resources/resfile")
for m in cat["models"]:
    p = os.path.realpath(os.path.join(resfile, m["file"]))
    if os.path.commonpath([p, root]) != root:
        raise SystemExit("refusing to remove outside the project: " + p)
    if os.path.isfile(p):
        os.remove(p)
PY

# 各端读自己资源目录里的派生 catalog。
python3 "$ROOT/scripts/derive_catalog.py" "$VARIANT" "$A_ANDROID" "$A_IOS/legal" "$A_OHOS"

if [ "$VARIANT" = bundled ]; then
  echo "==> injecting bundled model from git-tracked parts"
  PARTS="$ASSETS/models/parts"
  if [ ! -d "$PARTS" ] || ! ls "$PARTS"/part_*.bin >/dev/null 2>&1; then
    echo "missing bundled parts: $PARTS (run ./scripts/update-model.sh first)" >&2
    exit 1
  fi
  # 三端统一从入库分卷生成，不依赖本地 396 MB 原始 GGUF；
  # JitPack / CI 检出的源码中没有大文件也能复现同样的产物。
  "$ROOT/scripts/merge-model-parts.sh" "$A_IOS/model.gguf" "$PARTS"
  cp "$A_IOS/model.gguf" "$A_OHOS/model.gguf"
  mkdir -p "$A_ANDROID/model_parts"
  cp "$PARTS"/part_*.bin "$A_ANDROID/model_parts/"
  echo "  Android parts: $(ls "$A_ANDROID/model_parts"/part_*.bin | wc -l | tr -d ' ')"
fi
echo "==> done."
