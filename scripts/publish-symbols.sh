#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

prop() { grep "^$1=" gradle.properties 2>/dev/null | cut -d'=' -f2- || true; }
VERSION=$(prop MAVEN_VERSION)
KT=$(prop KOTLIN_VERSION_LIST | cut -d',' -f1)
GROUP=$(prop GROUP_ID)
TAG=""
BASE_URL="https://jitpack.io"
WAIT=0
UPLOAD=false
VERIFY_BUNDLED=false
VERIFY_SCRIPT="scripts/verify_symbols.py"

usage() {
  cat <<'EOF'
Usage: ./scripts/publish-symbols.sh [options]

  -v, --version <ver>   纯包版本（默认 MAVEN_VERSION，如 0.1.1）
      --tag <tag>       Release tag（默认 <version>-<KOTLIN_VERSION_LIST[0]>，即标准 tag）
      --jitpack-url <u> JitPack 基址（默认 https://jitpack.io）
      --wait <n>        JitPack 未就绪（404 或「构建中」HTML）时的重试次数，每次间隔 20s（默认 0）
      --verify-bundled  额外下载 bundled AAR（约 400 MB）做完整校验
      --upload          执行 gh release create/upload；默认只生成产物并打印命令
  -h, --help

前置条件：
  1. 已打标准 tag 且 JitPack 构建完成（`KuiklyLLMProviderAndroid` 随发布带 native-symbols.zip）。
  2. 已运行 ./scripts/publish-ohpm.sh，产出 dist/*.har 与 dist/symbols/ohos/libllm_provider.so.unstripped。
输出：
  dist/symbols-<version>.tar.gz 及其 .sha256，发布到标准 tag 的 Release。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) VERSION="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    --jitpack-url) BASE_URL="$2"; shift 2;;
    --wait) WAIT="$2"; shift 2;;
    --verify-bundled) VERIFY_BUNDLED=true; shift;;
    --upload) UPLOAD=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

[[ -n "$VERSION" && -n "$KT" && -n "$GROUP" ]] || {
  echo "> [ERROR] MAVEN_VERSION / KOTLIN_VERSION_LIST / GROUP_ID 必须都有值" >&2; exit 2; }
[[ "$WAIT" =~ ^[0-9]+$ ]] || { echo "> [ERROR] --wait 需要非负整数" >&2; exit 2; }
[[ -f "$VERIFY_SCRIPT" ]] || { echo "> [ERROR] 缺少 $VERIFY_SCRIPT" >&2; exit 2; }
if [[ -z "$TAG" ]]; then TAG="${VERSION}-${KT}"; fi

GROUP_PATH="${GROUP//.//}"
A_DOWNLOAD="KuiklyLLMProviderAndroid"
A_BUNDLED="KuiklyLLMProviderAndroid-Bundled"
REMOTE="$BASE_URL/$GROUP_PATH"
DL_DIR="$ROOT/dist/jitpack/$TAG"
mkdir -p "$DL_DIR"

# JitPack 首次请求会异步触发构建：可能返回 404，也可能返回 HTTP 200 + "build in
# progress" 的 HTML。两者都算「未就绪」。有效性校验必须放在重试循环内，否则 200+HTML
# 会被当成下载成功，随后在校验阶段直接退出，--wait 形同虚设。
# 所有目标构件（AAR / 符号 zip）都是 zip，统一用 unzip -t 判定内容是否有效。
fetch() {
  local url="$1" out="$2" attempt=0
  while :; do
    rm -f "$out.part"
    if curl -fsSL --connect-timeout 15 -o "$out.part" "$url" && \
       unzip -t "$out.part" >/dev/null 2>&1; then
      mv "$out.part" "$out"
      return 0
    fi
    if [[ $attempt -ge $WAIT ]]; then
      rm -f "$out.part"
      return 1
    fi
    attempt=$((attempt + 1))
    echo "> [INFO] 构件未就绪（尚未构建完 / 内容不是有效 zip），20s 后重试 ($attempt/$WAIT)：$url"
    sleep 20
  done
}

echo "> [INFO] 符号发布：version=$VERSION tag=$TAG group=$GROUP"
echo "> [INFO] JitPack 构件来源：$REMOTE"

DL_AAR="$DL_DIR/${A_DOWNLOAD}-${TAG}.aar"
DL_SYM="$DL_DIR/${A_DOWNLOAD}-${TAG}-native-symbols.zip"

for spec in \
  "${A_DOWNLOAD}/${TAG}/${A_DOWNLOAD}-${TAG}.aar|${DL_AAR}" \
  "${A_DOWNLOAD}/${TAG}/${A_DOWNLOAD}-${TAG}-native-symbols.zip|${DL_SYM}"; do
  rel="${spec%%|*}"
  out="${spec##*|}"
  echo "> [INFO] 下载 $rel"
  if ! fetch "$REMOTE/$rel" "$out"; then
    echo "> [ERROR] 无法取得有效构件：$REMOTE/$rel" >&2
    echo "          确认标准 tag 已推送、JitPack 构建成功；首次构建可加 --wait 30。" >&2
    echo "          构建日志：https://jitpack.io/#iPel/KuiklyLLMProvider/$TAG" >&2
    exit 2
  fi
done

# 1) Android
python3 "$VERIFY_SCRIPT" "$DL_AAR" "$DL_SYM"
ID_ANDROID=$(python3 "$VERIFY_SCRIPT" --id "$DL_SYM")
echo "> [INFO] Android 符号 Build ID：$ID_ANDROID"
VERIFIED_ANDROID="download.aar"
if [[ "$VERIFY_BUNDLED" == "true" ]]; then
  BD_AAR="$DL_DIR/${A_BUNDLED}-${TAG}.aar"
  echo "> [INFO] 下载并校验 bundled AAR（体积较大）"
  if ! fetch "$REMOTE/${A_BUNDLED}/${TAG}/${A_BUNDLED}-${TAG}.aar" "$BD_AAR"; then
    echo "> [ERROR] 无法取得有效 bundled AAR；首次构建可加 --wait 30" >&2; exit 2
  fi
  python3 "$VERIFY_SCRIPT" "$BD_AAR" "$DL_SYM"
  VERIFIED_ANDROID="download.aar,bundled.aar"
fi

# 2) 鸿蒙
SYM_OHOS="$ROOT/dist/symbols/ohos/libllm_provider.so.unstripped"
for variant in download bundled; do
  har="$ROOT/dist/${variant}.har"
  [[ -f "$har" ]] || {
    echo "> [ERROR] 缺少 ${har}；请先运行 ./scripts/publish-ohpm.sh" >&2; exit 2; }
  [[ -f "$SYM_OHOS" ]] || {
    echo "> [ERROR] 缺少 ${SYM_OHOS}；请确认 publish-ohpm.sh 是本次发布构建产出的" >&2; exit 2; }
  python3 "$VERIFY_SCRIPT" "$har" "$SYM_OHOS"
done
ID_OHOS=$(python3 "$VERIFY_SCRIPT" --id "$SYM_OHOS")

# 3) 用干净的 stage 目录打包，避免把 dist/symbols 下的历史残留带进 Release。
STAGE="$ROOT/dist/.symbols-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/symbols/android" "$STAGE/symbols/ohos"
unzip -o -j -d "$STAGE/symbols/android" "$DL_SYM" libllm_provider.so.unstripped >/dev/null
cp "$SYM_OHOS" "$STAGE/symbols/ohos/libllm_provider.so.unstripped"
# 校验用的是本机 dist/*.har，而 HAR 是另一次上传；记录 sha256 便于事后核对
# Release 上的 HAR 与符号包里的 Build ID 是否仍指向同一份产物。
sha256_of() {
  python3 - "$1" <<'PY'
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
with p.open('rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
        h.update(chunk)
print(h.hexdigest())
PY
}
HAR_SHA_DOWNLOAD=$(sha256_of "$ROOT/dist/download.har")
HAR_SHA_BUNDLED=$(sha256_of "$ROOT/dist/bundled.har")
cat > "$STAGE/symbols/BUILD_IDS.txt" <<EOF
version=$VERSION
release_tag=$TAG
jitpack_group=$GROUP
# verified 列出已与该符号校验 Build ID 的构件。
android/symbols=android/libllm_provider.so.unstripped
android/symbols.build_id=$ID_ANDROID
android/verified=$VERIFIED_ANDROID
ohos/symbols=ohos/libllm_provider.so.unstripped
ohos/symbols.build_id=$ID_OHOS
ohos/verified=download.har,bundled.har
ohos/download.har.sha256=$HAR_SHA_DOWNLOAD
ohos/bundled.har.sha256=$HAR_SHA_BUNDLED
ios=(源码分发，符号由接入方工程编译期生成，不在此包内)
EOF

SYMBOL_ARCHIVE="$ROOT/dist/symbols-${VERSION}.tar.gz"
tar -czf "$SYMBOL_ARCHIVE" -C "$STAGE" symbols
python3 - "$SYMBOL_ARCHIVE" <<'PY'
import hashlib
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
with p.open('rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
        h.update(chunk)
pathlib.Path(str(p) + '.sha256').write_text(
    '%s  %s\n' % (h.hexdigest(), p.name), encoding='utf-8')
PY
echo "> [INFO] 符号归档：${SYMBOL_ARCHIVE}（$(du -h "$SYMBOL_ARCHIVE" | cut -f1)）"
echo "> [INFO] 校验文件：$SYMBOL_ARCHIVE.sha256"

ASSETS=("$SYMBOL_ARCHIVE" "$SYMBOL_ARCHIVE.sha256")
NOTES="调试符号表：${TAG}。符号已逐构件校验 NT_GNU_BUILD_ID，对应关系见包内 BUILD_IDS.txt。"
if [[ "$UPLOAD" == "true" ]]; then
  command -v gh >/dev/null || { echo "> [ERROR] 未安装 gh CLI" >&2; exit 2; }
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "> [INFO] Release 已存在，上传 assets"
    gh release upload "$TAG" "${ASSETS[@]}" --clobber
  else
    echo "> [INFO] 创建标准 tag 的 Release"
    gh release create "$TAG" "${ASSETS[@]}" --verify-tag --title "$TAG" --notes "$NOTES"
  fi
  echo "> [INFO] 已上传符号表到 $TAG 的 Release"
else
  cat <<EOF
> [INFO] 产物已就绪，未执行上传（加 --upload 自动执行）。手动步骤：
  gh release create $TAG dist/symbols-${VERSION}.tar.gz dist/symbols-${VERSION}.tar.gz.sha256 \\
    --verify-tag --title $TAG --notes "调试符号表（Build ID 已校验）"
  # Release 已存在时改用：
  gh release upload $TAG dist/symbols-${VERSION}.tar.gz dist/symbols-${VERSION}.tar.gz.sha256 --clobber
EOF
fi
