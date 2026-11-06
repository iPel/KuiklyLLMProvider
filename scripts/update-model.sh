#!/usr/bin/env bash
# Manually refresh the bundled GGUF and its git-tracked split parts.
#
#   ./scripts/update-model.sh --url <https://.../model.gguf> --sha256 <64-hex>
#   ./scripts/update-model.sh --file /path/to/model.gguf --sha256 <64-hex>
#
# Verifies the GGUF, splits it into 32 MiB parts and updates catalog.json when values change.
# Does not run git, touch NOTICE.md, change the release variant, or publish.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ASSETS="$ROOT/KuiklyLLMProviderAssets"
MODELS="$ASSETS/models"
PARTS="$MODELS/parts"
CATALOG="$ASSETS/catalog.json"
NOTICE="$ASSETS/NOTICE.md"

case "$ROOT" in /*) ;; *) echo "cannot resolve absolute project root: $ROOT" >&2; exit 1;; esac
case "$PARTS" in "$ROOT"/*) ;; *) echo "refusing to write outside the project: $PARTS" >&2; exit 1;; esac

URL=""
LOCAL_FILE=""
EXPECT_SHA=""
MODEL_ID=""
PART_SIZE=$((32 * 1024 * 1024))
URL_PRIMARY=""
TMP=""
SRC_KIND="local"

usage() {
  cat <<'EOF'
Usage: ./scripts/update-model.sh [options]

  --url <URL>          download a new GGUF (mutually exclusive with --file)
  --file <PATH>        use an existing local GGUF (mutually exclusive with --url)
  --sha256 <64-hex>    expected digest; omit to reuse the catalog value
                       (only valid when re-splitting the very same weights)
  --id <model-id>      catalog entry to refresh (default: first model, the bundled one)
  --part-size <bytes>  part size (default: 33554432 = 32 MiB)
  -h, --help           show this help

Examples:
  ./scripts/update-model.sh --url https://.../Qwen3-0.6B-Q4_K_M.gguf \
      --sha256 ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a
  ./scripts/update-model.sh --file ~/Downloads/Qwen3-0.6B-Q4_K_M.gguf
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2;;
    --file) LOCAL_FILE="$2"; shift 2;;
    --sha256) EXPECT_SHA="$2"; shift 2;;
    --id) MODEL_ID="$2"; shift 2;;
    --part-size) PART_SIZE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

if [[ -n "$URL" && -n "$LOCAL_FILE" ]]; then
  echo "--url and --file are mutually exclusive" >&2; exit 2
fi
if [[ -z "$URL" && -z "$LOCAL_FILE" ]]; then
  echo "one of --url or --file is required" >&2; usage; exit 2
fi
case "$PART_SIZE" in
  ''|*[!0-9]*) echo "--part-size must be a positive integer" >&2; exit 2;;
  0) echo "--part-size must be greater than zero" >&2; exit 2;;
esac
if [[ -n "$EXPECT_SHA" && ! "$EXPECT_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "--sha256 must be 64 hex characters" >&2; exit 2
fi
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }

cleanup() { if [[ -n "$TMP" && -f "$TMP" ]]; then rm -f "$TMP"; fi; }
trap cleanup EXIT

if [[ -n "$URL" ]]; then
  command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }
  TMP=$(mktemp "$MODELS/.download.XXXXXX")
  echo "==> downloading $URL"
  curl -fL --retry 3 --connect-timeout 20 -o "$TMP" "$URL"
  SRC="$TMP"
  SRC_KIND="tmp"
  URL_PRIMARY="$URL"
else
  [[ -f "$LOCAL_FILE" ]] || { echo "local GGUF not found: $LOCAL_FILE" >&2; exit 1; }
  SRC="$LOCAL_FILE"
fi

echo "==> verifying, splitting and updating catalog"
python3 - "$SRC" "$EXPECT_SHA" "$PART_SIZE" "$CATALOG" "$MODEL_ID" \
  "$URL_PRIMARY" "$MODELS" "$PARTS" "$ROOT" "$SRC_KIND" <<'PY'
import glob
import hashlib
import json
import os
import shutil
import sys

src, expect, part_size, catalog_path, model_id, url_primary, models_dir, parts_dir, root, src_kind = sys.argv[1:]
part_size = int(part_size)

for path in (models_dir, parts_dir, catalog_path):
    if os.path.commonpath([os.path.abspath(path), root]) != root:
        raise SystemExit("refusing to write outside the project: " + path)

with open(catalog_path, encoding="utf-8") as f:
    catalog = json.load(f)
models = catalog["models"]
if not models:
    raise SystemExit("catalog.json has no models")

if model_id:
    entry = next((m for m in models if m.get("id") == model_id), None)
    if entry is None:
        raise SystemExit("unknown --id %s; available: %s" % (model_id, ", ".join(m["id"] for m in models)))
else:
    entry = models[0]
    print("  [INFO] no --id given, refreshing first model: " + entry["id"])

cur_sha = entry.get("sha256", "")
expect = expect.lower() if expect else cur_sha.lower()
if len(expect) != 64 or any(c not in "0123456789abcdef" for c in expect):
    raise SystemExit("no valid SHA-256 available; pass --sha256 <64-hex>")
if expect != cur_sha.lower():
    print("  [INFO] digest differs from catalog; new weights will be recorded")

size = os.path.getsize(src)
h = hashlib.sha256()
with open(src, "rb") as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b""):
        h.update(chunk)
actual = h.hexdigest()
if actual != expect:
    raise SystemExit("SHA-256 mismatch: expected %s, got %s" % (expect, actual))
print("  verified: %d bytes, sha256=%s" % (size, actual))

target = os.path.join(models_dir, entry["file"])
if os.path.exists(src) and os.path.exists(target) and os.path.samefile(src, target):
    pass
elif src_kind == "tmp":
    os.replace(src, target)
else:
    shutil.copy2(src, target)
print("  installed: " + os.path.relpath(target, root))

os.makedirs(parts_dir, exist_ok=True)
for old in glob.glob(os.path.join(parts_dir, "part_*.bin")):
    os.remove(old)

count = 0
with open(target, "rb") as f:
    while True:
        block = f.read(part_size)
        if not block:
            break
        with open(os.path.join(parts_dir, "part_%02d.bin" % count), "wb") as out:
            out.write(block)
        count += 1
print("  split into %d parts (%d bytes each, last may be smaller)" % (count, part_size))

check = hashlib.sha256()
total = 0
for name in sorted(glob.glob(os.path.join(parts_dir, "part_*.bin"))):
    with open(name, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            check.update(chunk)
            total += len(chunk)
if total != size or check.hexdigest() != expect:
    raise SystemExit("assembled parts do not match the source (total=%d, sha=%s)" % (total, check.hexdigest()))
print("  self-check: assembled parts reproduce the source digest")

changed = []
if entry.get("bytes") != size:
    entry["bytes"] = size
    changed.append("bytes")
if entry.get("sha256") != expect:
    entry["sha256"] = expect
    changed.append("sha256")
if url_primary and entry.get("url_primary") != url_primary:
    entry["url_primary"] = url_primary
    changed.append("url_primary")
if changed:
    with open(catalog_path, "w", encoding="utf-8") as f:
        f.write(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print("  catalog.json updated: " + ", ".join(changed))
else:
    print("  catalog.json unchanged")

print("  parts dir: " + os.path.relpath(parts_dir, root))
PY

cat <<EOF

==> done. Remaining manual steps:
  1. Review ${NOTICE#$ROOT/} and README.md: update the Bytes / SHA-256 rows if the weights changed.
  2. git add ${PARTS#$ROOT/} ${CATALOG#$ROOT/}   (and any compliance edits), then commit.
  3. ./scripts/prepare-variant.sh <download|bundled> to restage the three platforms.
  4. Re-run the platform builds / publish scripts; this script never publishes.
EOF
