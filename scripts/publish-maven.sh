#!/usr/bin/env bash
# Publish KuiklyLLMProvider Maven artifacts.
# Matrix: KMP (one coordinate per Kotlin toolchain, variant-independent),
# Android render (download + bundled), HarmonyOS KMP (ohos settings).
set -euo pipefail
PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"
GRADLEW=./gradlew
PROPS=gradle.properties

prop() { grep "^$1=" "$PROPS" 2>/dev/null | cut -d'=' -f2- || true; }

BASE_VERSION=$(prop MAVEN_VERSION)
GROUP_ID=$(prop GROUP_ID)
MODULE_KMP=$(prop MODULE_NAME)
KOTLIN_LIST=$(prop KOTLIN_VERSION_LIST)
OHOS_KOTLIN_LIST=$(prop OHOS_KOTLIN_VERSION_LIST)
MAVEN_URL=$(prop MAVEN_REPO_URL)
VARIANTS="all"
SNAPSHOT="false"
LOCAL_REPO="false"
NEED_CLEAN="false"
DEBUG="false"
ANDROID_ONLY="false"
REFRESH_DEPS="false"

usage() {
  cat <<'EOF'
Usage: ./scripts/publish-maven.sh [options]

  -v, --version <ver>        component version (default: MAVEN_VERSION in gradle.properties)
  -g, --group-id <id>        Maven group id (default: GROUP_ID)
  -k, --kotlin <list>        comma separated Kotlin versions (default: KOTLIN_VERSION_LIST)
  -ok, --ohos-kotlin <list>  comma separated OHOS Kotlin versions
  -m, --maven-url <url>      remote Maven repository URL
  -u, --username <user>      repository username (prefer env ORG_GRADLE_PROJECT_mavenUsername)
  -p, --password <pass>      repository password (prefer env ORG_GRADLE_PROJECT_mavenPassword)
                             -u/-p values are exported to Gradle via env only,
                             never placed on the Gradle command line
      --variant <v>          Android AAR variants: download | bundled | all (default: all)
  -l, --local                publish to build/repo instead of a remote repository
      --android-only         publish only the Android AAR for local verification; skips KMP and OHOS
      --refresh              add --refresh-dependencies to Gradle
  -s, --snapshot             append -SNAPSHOT to every version
  -c, --clean                run gradle clean first
  -d, --debug                Gradle --debug (may echo project properties; avoid real credentials)
  -h, --help                 show this help

Examples:
  ./scripts/publish-maven.sh --local --variant download        # local publish check
  ORG_GRADLE_PROJECT_mavenUsername=ci \
    ORG_GRADLE_PROJECT_mavenPassword="$TOKEN" \
    ./scripts/publish-maven.sh -v 0.2.0 -m https://repo.example.com/maven
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) BASE_VERSION="$2"; shift 2;;
    -g|--group-id) GROUP_ID="$2"; shift 2;;
    -k|--kotlin) KOTLIN_LIST="$2"; shift 2;;
    -ok|--ohos-kotlin) OHOS_KOTLIN_LIST="$2"; shift 2;;
    -m|--maven-url) MAVEN_URL="$2"; shift 2;;
    -u|--username) MAVEN_USERNAME="$2"; shift 2;;
    -p|--password) MAVEN_PASSWORD="$2"; shift 2;;
    --variant) VARIANTS="$2"; shift 2;;
    --android-only) ANDROID_ONLY="true"; shift;;
    --refresh) REFRESH_DEPS="true"; shift;;
    -l|--local) LOCAL_REPO="true"; shift;;
    -s|--snapshot) SNAPSHOT="true"; shift;;
    -c|--clean) NEED_CLEAN="true"; shift;;
    -d|--debug) DEBUG="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

[[ -n "$MODULE_KMP" && -n "$BASE_VERSION" && -n "$KOTLIN_LIST" ]] || {
  echo "MODULE_NAME / MAVEN_VERSION / KOTLIN_VERSION_LIST must be set in gradle.properties" >&2; exit 1; }

case "$VARIANTS" in
  all) VARIANT_LIST="download bundled";;
  download|bundled) VARIANT_LIST="$VARIANTS";;
  *) echo "--variant must be download, bundled or all" >&2; exit 2;;
esac

# 凭据只经环境变量注入，避免口令出现在 ps / history / CI 日志与 Gradle 命令行。
if [[ -n "${MAVEN_USERNAME:-}" ]]; then
  export ORG_GRADLE_PROJECT_mavenUsername="$MAVEN_USERNAME"
fi
if [[ -n "${MAVEN_PASSWORD:-}" ]]; then
  export ORG_GRADLE_PROJECT_mavenPassword="$MAVEN_PASSWORD"
fi

gradle_args=(-PgroupId="$GROUP_ID")
[[ -n "$MAVEN_URL" && "$LOCAL_REPO" != "true" ]] && gradle_args+=(-PmavenRepoUrl="$MAVEN_URL")
[[ "$LOCAL_REPO" == "true" ]] && gradle_args+=(-PPUB_IS_LOCAL_REPO=true)
[[ "$DEBUG" == "true" ]] && gradle_args+=(--debug)
[[ "$REFRESH_DEPS" == "true" ]] && gradle_args+=(--refresh-dependencies)
ANDROID_MODULE="${MODULE_KMP}Android"

# 记录运行前的变体，退出时恢复；尚未派生过（全新 clone）时回退仓库默认 bundled。
INITIAL_VARIANT=$(python3 scripts/derive_catalog.py --current)

cleanup() { ./scripts/prepare-variant.sh "$INITIAL_VARIANT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [[ "$NEED_CLEAN" == "true" ]]; then "$GRADLEW" clean; fi

# KMP 契约层与变体无关，只发一次；Android AAR 按 download/bundled 各发一次。
publish_modules() {
  local ver="$1" settings="$2" modules="$3" variant="$4"
  echo "> [INFO] variant=$variant version=$ver modules=$modules"
  ./scripts/prepare-variant.sh "$variant" >/dev/null
  local tasks=()
  for m in $modules; do tasks+=(":${m}:publish"); done
  if [[ -n "$settings" ]]; then
    "$GRADLEW" "${tasks[@]}" -c "$settings" \
      -PmavenVersion="$ver" -Pvariant="$variant" "${gradle_args[@]}"
  else
    "$GRADLEW" "${tasks[@]}" \
      -PmavenVersion="$ver" -Pvariant="$variant" "${gradle_args[@]}"
  fi
}

IFS=',' read -r -a KT <<< "$KOTLIN_LIST"

# 1) KMP：标准 Kotlin 与鸿蒙 Kotlin 各一个坐标，不区分变体。
if [[ "$ANDROID_ONLY" != "true" ]]; then
  for kt in "${KT[@]}"; do
    build_version="${BASE_VERSION}-${kt}"
    [[ "$SNAPSHOT" == "true" ]] && build_version="${build_version}-SNAPSHOT"
    publish_modules "$build_version" "" "$MODULE_KMP" "download"
  done
  if [[ -n "$OHOS_KOTLIN_LIST" ]]; then
    IFS=',' read -r -a OKT <<< "$OHOS_KOTLIN_LIST"
    for kt in "${OKT[@]}"; do
      build_version="${BASE_VERSION}-${kt}"
      [[ "$SNAPSHOT" == "true" ]] && build_version="${build_version}-SNAPSHOT"
      publish_modules "$build_version" "settings.ohos.gradle.kts" "$MODULE_KMP" "download"
    done
  fi
fi

# 2) Android AAR：每个变体各一个 artifactId。
for variant in $VARIANT_LIST; do
  for kt in "${KT[@]}"; do
    build_version="${BASE_VERSION}-${kt}"
    [[ "$SNAPSHOT" == "true" ]] && build_version="${build_version}-SNAPSHOT"
    publish_modules "$build_version" "" "$ANDROID_MODULE" "$variant"
  done
done

echo "> [INFO] all Maven publications finished (local=$LOCAL_REPO)"
