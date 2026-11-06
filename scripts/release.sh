#!/usr/bin/env bash
# One entry point for a release: version sync -> variant assets -> Maven/Pod/HAR.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=""
DRY_RUN=false
DO_MAVEN=true
DO_POD=true
DO_OHPM=true
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) VERSION="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --no-maven) DO_MAVEN=false; shift;;
    --no-pod) DO_POD=false; shift;;
    --no-ohpm) DO_OHPM=false; shift;;
    *) ARGS+=("$1"); shift;;
  esac
done
prop() { grep "^$1=" gradle.properties 2>/dev/null | cut -d'=' -f2- || true; }
if [[ -z "$VERSION" ]]; then VERSION=$(prop MAVEN_VERSION); fi

# -v 只接受纯包版本；Kotlin 后缀由各发布脚本拼接。
KOTLIN_VERSION=$(prop KOTLIN_VERSION_LIST | cut -d',' -f1)
OHOS_KOTLIN_VERSION=$(prop OHOS_KOTLIN_VERSION_LIST | cut -d',' -f1)
if [[ -z "$VERSION" || -z "$KOTLIN_VERSION" || -z "$OHOS_KOTLIN_VERSION" ]]; then
  echo "> [ERROR] MAVEN_VERSION / KOTLIN_VERSION_LIST / OHOS_KOTLIN_VERSION_LIST 必须都有值" >&2
  exit 2
fi
if [[ "$VERSION" == *-"$KOTLIN_VERSION" || "$VERSION" == *-"$OHOS_KOTLIN_VERSION" ]]; then
  echo "> [ERROR] -v 只接受纯包版本（如 0.1.1），不要带 Kotlin 工具链后缀：" >&2
  echo "          tag / Maven 坐标的后缀由各发布脚本自动拼接。" >&2
  exit 2
fi

# 两个 git tag 指向同一次提交：标准 tag 供 JitPack(KMP+Android)、iOS Pod 与唯一的
# GitHub Release 使用；鸿蒙 tag 只用于 JitPack(鸿蒙 KMP) 分流。jitpack.yml 按
# *-KBA-* 分流，因此二者必须与 publish-pod.sh / publish-ohpm.sh 的算法一致。
STD_TAG="${VERSION}-${KOTLIN_VERSION}"
OHOS_TAG="${VERSION}-${OHOS_KOTLIN_VERSION}"

# dry-run 回显前把 -u/-p 的值替换为 ***，避免口令出现在控制台 / CI 日志里。
redacted_args() {
  local out=() i=0 a n=${#ARGS[@]}
  while [[ $i -lt $n ]]; do
    a="${ARGS[$i]}"
    case "$a" in
      -u|--username|-p|--password)
        out+=("$a")
        if [[ $((i+1)) -lt $n ]]; then out+=("***"); i=$((i+2)); else i=$((i+1)); fi
        ;;
      *) out+=("$a"); i=$((i+1));;
    esac
  done
  printf '%s' "${out[*]:-}"
}

# 把 -u/-p 从透传 argv 中剥离为环境变量，其余参数放入 MAVEN_ARGS，
# 使口令连 publish-maven.sh 的进程命令行都不进入。
MAVEN_ARGS=()
prepare_maven_args() {
  local i=0 a n=${#ARGS[@]}
  MAVEN_ARGS=()
  while [[ $i -lt $n ]]; do
    a="${ARGS[$i]}"
    case "$a" in
      -p|--password)
        if [[ $((i+1)) -lt $n ]]; then
          export ORG_GRADLE_PROJECT_mavenPassword="${ARGS[$((i+1))]}"
          i=$((i+2))
        else
          i=$((i+1))
        fi
        ;;
      -u|--username)
        if [[ $((i+1)) -lt $n ]]; then
          export ORG_GRADLE_PROJECT_mavenUsername="${ARGS[$((i+1))]}"
          i=$((i+2))
        else
          i=$((i+1))
        fi
        ;;
      *) MAVEN_ARGS+=("$a"); i=$((i+1));;
    esac
  done
}

sync_version() {
  echo "> [INFO] syncing package version $VERSION"
  echo "> [INFO] standard tag=$STD_TAG (JitPack KMP/Android + iOS Pod + Release) | ohos tag=$OHOS_TAG (JitPack ohos KMP only)"
  python3 - "$VERSION" "$STD_TAG" <<'PY'
import re
import sys

version, tag = sys.argv[1:3]


def rewrite(path, subs):
    """Apply exactly one substitution per pattern; fail loudly on a stale layout."""
    with open(path, encoding="utf-8") as f:
        s = f.read()
    original = s
    for pattern, replacement in subs:
        fn = replacement if callable(replacement) else (lambda m, r=replacement: r)
        s, n = re.subn(pattern, fn, s, count=1, flags=re.M)
        if n != 1:
            raise SystemExit("无法同步 %s：未匹配到 %r，请检查文件结构是否变更" % (path, pattern))
    if s != original:
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)


rewrite("gradle.properties", [
    (r"^MAVEN_VERSION=.*$", "MAVEN_VERSION=" + version),
])

# 两个 podspec 都必须入库且从同一个 git tag 引用，spec.version 与 :tag 要一起同步：
# download 是主 podspec，bundled 由 publish-pod.sh 派生，但 --no-pod 时不会重新生成。
for p in ("KuiklyLLMProviderIOS.podspec", "KuiklyLLMProviderIOSBundled.podspec"):
    rewrite(p, [
        (r"spec\.version\s*=\s*'[^']*'", "spec.version      = '" + version + "'"),
        (r"(:tag => )'[^']*'", lambda m, t=tag: m.group(1) + "'" + t + "'"),
    ])

# HAR 包版本保持纯语义版本；Release tag 的后缀由 publish-ohpm.sh 拼。
rewrite("KuiklyLLMProviderOhos/oh-package.json5", [
    (r'"version":\s*"[^"]*"', '"version": "' + version + '"'),
])
PY
}

echo "> [INFO] release version=$VERSION dry-run=$DRY_RUN"
echo "> [INFO] std tag=$STD_TAG | ohos tag=$OHOS_TAG"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "> [INFO] would run: sync_version -> scripts/publish-maven.sh $(redacted_args) -> scripts/publish-pod.sh -> scripts/publish-ohpm.sh"
  echo "> [INFO] sync_version 会同步：gradle.properties MAVEN_VERSION、两个 podspec 的 spec.version 与 :tag、oh-package.json5 version"
  echo "> [INFO] variants: download, bundled | targets: KMP, Android, iOS(Pod), HarmonyOS(HAR)"
  exit 0
fi

prepare_maven_args
sync_version
./scripts/prepare-variant.sh bundled
if [[ "$DO_MAVEN" == "true" ]]; then
  # bash 3.2 + set -u：空数组直接展开 "${MAVEN_ARGS[@]}" 会报 unbound variable，
  # 而不带任何额外参数恰是默认发布路径，必须分支处理。
  if [[ ${#MAVEN_ARGS[@]} -gt 0 ]]; then
    ./scripts/publish-maven.sh -v "$VERSION" "${MAVEN_ARGS[@]}"
  else
    ./scripts/publish-maven.sh -v "$VERSION"
  fi
fi
[[ "$DO_POD" == "true" ]] && ./scripts/publish-pod.sh -v "$VERSION"
[[ "$DO_OHPM" == "true" ]] && ./scripts/publish-ohpm.sh -v "$VERSION"
./scripts/prepare-variant.sh bundled

# 调试符号由 publish-symbols.sh 在 JitPack 构建完成后统一发布。
cat <<EOF
> [INFO] release $VERSION prepared; local artifacts are ready. Remaining manual steps:
  1) 提交版本文件与资产，打标准 tag（JitPack、iOS Pod 与唯一 Release 共用）：
       git tag $STD_TAG && git push origin $STD_TAG
     鸿蒙 tag 单独打，仅用于 JitPack 鸿蒙 KMP 分流：
       git tag $OHOS_TAG && git push origin $OHOS_TAG
  2) 用标准 tag 的 Release 发布两个 HAR（与符号表共用同一个 Release）：
       gh release create $STD_TAG dist/download.har dist/bundled.har dist/SHA256SUMS
       # Release 已存在时改用 gh release upload $STD_TAG ...
  3) 待 JitPack 构建完成后发布调试符号表：
       ./scripts/publish-symbols.sh -v $VERSION --wait 30 --upload
  4) 不需要 pod trunk push，也不需要 ohpm publish。
EOF
