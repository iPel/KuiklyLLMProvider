#!/usr/bin/env bash
# Package the HarmonyOS HAR for both published variants.
# The package version is plain semver; the Kotlin toolchain suffix appears only in Maven coordinates and git tags.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
PACK=true

prop() { grep "^$1=" gradle.properties 2>/dev/null | cut -d'=' -f2- || true; }
VERSION=$(prop MAVEN_VERSION)
KT=$(prop KOTLIN_VERSION_LIST | cut -d',' -f1)

usage() {
  cat <<'EOF'
Usage: ./scripts/publish-ohpm.sh [options]

  -v, --version <ver>   plain package version (default: MAVEN_VERSION, e.g. 0.1.2)
      --no-pack         prepare metadata only, skip hvigorw
  -h, --help            show this help

Writes dist/download.har, dist/bundled.har, dist/SHA256SUMS and one
dist/symbols/ohos/libllm_provider.so.unstripped (from the download variant).
HARs go to the GitHub Release on the standard tag; publish-symbols.sh adds the
symbols to the SAME Release. This script never uploads.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) VERSION="$2"; shift 2;;
    --no-pack) PACK=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

RELEASE_TAG="${VERSION}-${KT}"

OHOS_DIR="$ROOT/KuiklyLLMProviderOhos"
PKG="$OHOS_DIR/oh-package.json5"
PKG_BAK="$PKG.ohpm-bak"
# hvigor 每次 assembleHar 都会按 buildMode 重写 BuildProfile.ets 的
# BUILD_MODE_NAME / DEBUG；该文件被 git 跟踪，发布脚本不能把它留在工作树里。
BUILD_PROFILE="$OHOS_DIR/BuildProfile.ets"
BUILD_PROFILE_BAK="$BUILD_PROFILE.ohpm-bak"
DIST="$ROOT/dist"
HAR_OUT="$OHOS_DIR/build/default/outputs/default/llm_provider.har"
# CMake POST_BUILD 留下的未 strip .so。
SYMBOL_SRC="$OHOS_DIR/build/native-symbols/libllm_provider.so.unstripped"
SYM_ARCHIVE="$DIST/symbols/ohos/libllm_provider.so.unstripped"
VERIFY_SCRIPT="scripts/verify_symbols.py"
BACKUP_ACTIVE="false"

# 无论正常结束还是报错退出，都恢复真实 oh-package.json5、BuildProfile.ets 并复位变体。
restore_pkg() {
  if [[ "$BACKUP_ACTIVE" == "true" && -f "$PKG_BAK" ]]; then
    mv -f "$PKG_BAK" "$PKG"
  fi
  BACKUP_ACTIVE="false"
}
restore_build_profile() {
  if [[ -f "$BUILD_PROFILE_BAK" ]]; then
    mv -f "$BUILD_PROFILE_BAK" "$BUILD_PROFILE"
  fi
}

# 记录运行前的变体，退出时恢复；尚未派生过（全新 clone）时回退仓库默认 bundled。
INITIAL_VARIANT=$(python3 "$ROOT/scripts/derive_catalog.py" --current)

cleanup() {
  restore_pkg
  restore_build_profile
  ./scripts/prepare-variant.sh "$INITIAL_VARIANT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "> [INFO] HAR version=$VERSION release tag=$RELEASE_TAG"
mkdir -p "$DIST"
if [[ "$PACK" == "true" ]]; then
  # 清空旧 HAR 与旧符号，避免把上次产物当作本次结果。
  rm -f "$DIST"/*.har "$DIST/SHA256SUMS" "$DIST"/hvigor-*.log "$HAR_OUT" \
        "$SYM_ARCHIVE" \
        "$DIST/symbols/ohos/download/libllm_provider.so.unstripped" \
        "$DIST/symbols/ohos/bundled/libllm_provider.so.unstripped"
  mkdir -p "$DIST/symbols/ohos"
fi
# 备份 hvigor 会自动改写的文件；trap cleanup 在退出时恢复运行前的内容。
if [[ -f "$BUILD_PROFILE" ]]; then
  cp "$BUILD_PROFILE" "$BUILD_PROFILE_BAK"
fi

for variant in download bundled; do
  echo "> [INFO] preparing $variant HAR"
  ./scripts/prepare-variant.sh "$variant" >/dev/null

  # 每轮临时改写真实 oh-package.json5：bundled 变体改包名，两个变体都同步版本。
  # hvigorw 读取的就是这个文件，写模板文件不会生效。
  cp "$PKG" "$PKG_BAK"
  BACKUP_ACTIVE="true"
  python3 - "$PKG" "$variant" "$VERSION" <<'PY'
import re
import sys

p, variant, version = sys.argv[1:]
s = open(p, encoding="utf-8").read()
if variant == "bundled":
    s = s.replace('"@ipel/llm-provider-ohos"', '"@ipel/llm-provider-bundled-ohos"')
s = re.sub(r'"version":\s*"[^"]*"', '"version": "' + version + '"', s, count=1)
open(p, "w", encoding="utf-8").write(s)
PY

  if [[ "$PACK" == "true" ]]; then
    command -v hvigorw >/dev/null || {
      echo "hvigorw not found; install DevEco Studio command line tools" >&2
      exit 1
    }
    rm -f "$HAR_OUT" "$SYMBOL_SRC"
    # 清掉 CMake 中间目录，强制按当前 CMakeLists.txt 重新 configure，
    # 避免 build.ninja 里残留历史的符号输出路径；同时保证本轮确实重新链接。
    rm -rf "$OHOS_DIR/.cxx"
    # 模块名取自 ohosApp/build-profile.json5（llm_provider，不是目录名）。
    # hvigorw 对 HAR 缺省使用 debug 模式（华为官方文档：assembleHap/Hsp/Har 默认 debug），
    # 必须显式传 buildMode=release，否则发布的是 Debug 产物、release buildOptionSet 不生效。
    # env -u NODE_OPTIONS 去掉宿主注入的 node shim，否则 hvigorw 会报 EPIPE。
    # 构建日志写入文件，失败时输出末尾内容。
    HVIGOR_LOG="$DIST/hvigor-${variant}.log"
    if ! (cd "$ROOT/ohosApp" && env -u NODE_OPTIONS hvigorw assembleHar \
        --mode module -p module=llm_provider@default -p product=default \
        -p buildMode=release --no-daemon) \
        > "$HVIGOR_LOG" 2>&1; then
      echo "> [ERROR] assembleHar failed for $variant; see $HVIGOR_LOG" >&2
      tail -30 "$HVIGOR_LOG" >&2
      exit 1
    fi
    if [[ ! -f "$HAR_OUT" ]]; then
      echo "> [ERROR] assembleHar 未生成 HAR：${variant}（release 模式输出路径可能变化，请核对 $OHOS_DIR/build/）" >&2
      exit 1
    fi
    if [[ ! -f "$SYMBOL_SRC" ]]; then
      echo "> [ERROR] 缺少本次构建的符号文件：$SYMBOL_SRC" >&2
      echo "          请确认 CMake POST_BUILD 已执行（LLMPROVIDER_SYMBOL_DIR）" >&2
      exit 1
    fi
    python3 "$VERIFY_SCRIPT" "$HAR_OUT" "$SYMBOL_SRC"
    if [[ "$variant" == "download" ]]; then
      cp "$SYMBOL_SRC" "$SYM_ARCHIVE"
      echo "> [INFO] archived dist/symbols/ohos/libllm_provider.so.unstripped"
    else
      [[ -f "$SYM_ARCHIVE" ]] || {
        echo "> [ERROR] 缺少归档符号：$SYM_ARCHIVE" >&2; exit 2; }
      python3 "$VERIFY_SCRIPT" "$HAR_OUT" "$SYM_ARCHIVE"
    fi
    mv "$HAR_OUT" "$DIST/${variant}.har"
    echo "> [INFO] packaged dist/${variant}.har ($(du -h "$DIST/${variant}.har" | cut -f1))"
  fi

  # 每个变体结束立即恢复真实包文件，避免影响下一次循环 / 工作树。
  restore_pkg
done

if [[ "$PACK" == "true" ]]; then
  python3 - "$DIST" <<'PY'
import hashlib
import os
import sys

d = sys.argv[1]
lines = []
for name in ("download.har", "bundled.har"):
    path = os.path.join(d, name)
    if not os.path.isfile(path):
        continue
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    lines.append("%s  %s" % (h.hexdigest(), name))
open(os.path.join(d, "SHA256SUMS"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
fi

cat <<EOF
> [INFO] 两个 HAR 已生成于 dist/（含 SHA256SUMS），与符号表同走标准 tag 的 GitHub Release。
  gh release create $RELEASE_TAG dist/download.har dist/bundled.har dist/SHA256SUMS
  # tag 已存在时改用：gh release upload $RELEASE_TAG dist/download.har dist/bundled.har dist/SHA256SUMS
> [INFO] 调试符号：dist/symbols/ohos/libllm_provider.so.unstripped（两个 HAR 已校验 Build ID）。
         由 ./scripts/publish-symbols.sh -v $VERSION --upload 发布到标准 tag 的 Release。
EOF
