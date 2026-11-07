#!/usr/bin/env bash
# Prepare CocoaPods artifacts for both published variants. Never pushes by itself.
# Package versions are plain semver; the git tag carries the Kotlin toolchain suffix.
set -euo pipefail
cd "$(dirname "$0")/.."
PODSPEC=KuiklyLLMProviderIOS.podspec
BUNDLED_PODSPEC=KuiklyLLMProviderIOSBundled.podspec
DO_LINT=false

prop() { grep "^$1=" gradle.properties 2>/dev/null | cut -d'=' -f2- || true; }
VERSION=$(prop MAVEN_VERSION)
KOTLIN_VERSION=$(prop KOTLIN_VERSION_LIST | cut -d',' -f1)

usage() {
  cat <<'EOF'
Usage: ./scripts/publish-pod.sh [options]

  -v, --version <ver>   plain package version (default: MAVEN_VERSION, e.g. 0.1.2)
      --lint            run pod spec lint on both podspecs (requires the tag
                        to be pushed; use `pod lib lint` for a local check)
  -h, --help            show this help

Generates KuiklyLLMProviderIOSBundled.podspec and prints the manual tag steps.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) VERSION="$2"; shift 2;;
    --lint) DO_LINT=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

TAG="${VERSION}-${KOTLIN_VERSION}"
echo "> [INFO] package version=$VERSION git tag=$TAG"
python3 - "$VERSION" "$TAG" "$PODSPEC" "$BUNDLED_PODSPEC" <<'PY'
import re
import sys

version, tag, src_path, out_path = sys.argv[1:]
s = open(src_path, encoding="utf-8").read()
s = s.replace(
    "spec.name         = 'KuiklyLLMProviderIOS'",
    "spec.name         = 'KuiklyLLMProviderIOSBundled'",
)
s = re.sub(r"spec\.version\s*=\s*'[^']*'", "spec.version      = '" + version + "'", s)
s = re.sub(r"(:tag => )'[^']*'", lambda m: m.group(1) + "'" + tag + "'", s)
old_prepare = ("  # CocoaPods 的 :git/:tag checkout 不含生成物，prepare_command 补齐合规文件与模型清单。\n"
               "  spec.prepare_command = 'bash scripts/prepare-pod-assets.sh download'")
new_prepare = ("  # bundled 版在 pod install 期从入库分卷合并回单个 GGUF，并补齐合规文件与模型清单。\n"
               "  spec.prepare_command = 'bash scripts/prepare-pod-assets.sh bundled'")
if old_prepare not in s:
    raise SystemExit("cannot find download prepare_command in " + src_path)
s = s.replace(old_prepare, new_prepare, 1)
open(out_path, "w", encoding="utf-8").write(s)
PY
echo "> [INFO] generated $BUNDLED_PODSPEC (name / version / tag / prepare_command)"

if [[ "$DO_LINT" == "true" ]]; then
  command -v pod >/dev/null || { echo "pod not found" >&2; exit 1; }
  echo "> [INFO] linting $PODSPEC"
  pod spec lint "$PODSPEC" --allow-warnings --quick
  echo "> [INFO] linting $BUNDLED_PODSPEC"
  pod spec lint "$BUNDLED_PODSPEC" --allow-warnings --quick
fi

cat <<EOF
> [INFO] podspecs ready:
  $PODSPEC
  $BUNDLED_PODSPEC
> [INFO] 主 podspec 的 spec.source :tag 需与 $TAG 保持一致（release.sh 负责同步）。
> [INFO] 发布前把分卷、两个 podspec 与合并脚本提交并打 tag：
  git add KuiklyLLMProviderAssets/models/parts $PODSPEC $BUNDLED_PODSPEC scripts/merge-model-parts.sh
  git tag $TAG && git push origin $TAG
EOF
