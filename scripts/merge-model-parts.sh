#!/usr/bin/env bash
# Merge the git-tracked GGUF parts into one file.
# Usage: ./scripts/merge-model-parts.sh <output.gguf> [parts-dir]
#
# Shared by prepare-variant.sh and the bundled podspec's prepare_command.
# Idempotent; missing parts is not an error (download variant has nothing to merge).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-}
PARTS=${2:-"$ROOT/KuiklyLLMProviderAssets/models/parts"}
CATALOG="$ROOT/KuiklyLLMProviderAssets/catalog.json"

if [[ -z "$OUT" ]]; then
  echo "usage: $0 <output.gguf> [parts-dir]" >&2
  exit 2
fi
if [[ ! -f "$CATALOG" ]]; then
  echo "catalog.json not found: $CATALOG" >&2
  exit 1
fi

python3 - "$PARTS" "$OUT" "$CATALOG" "$ROOT" <<'PY'
import glob
import hashlib
import json
import os
import sys

parts_dir, out, catalog_path, root = sys.argv[1:]
out = os.path.abspath(out)
if os.path.commonpath([out, root]) != root:
    raise SystemExit("refusing to write outside the project: " + out)

with open(catalog_path, encoding="utf-8") as f:
    catalog = json.load(f)
model = catalog["models"][0]
expected_sha = model["sha256"].lower()
expected_size = model["bytes"]

names = sorted(glob.glob(os.path.join(parts_dir, "part_*.bin")))
if not names:
    print("  [merge] no parts found, nothing to merge")
    sys.exit(0)

if os.path.isfile(out):
    size = os.path.getsize(out)
    h = hashlib.sha256()
    with open(out, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    if size == expected_size and h.hexdigest() == expected_sha:
        print("  [merge] output already valid, skipping")
        sys.exit(0)

os.makedirs(os.path.dirname(out), exist_ok=True)
tmp = out + ".merging"
h = hashlib.sha256()
total = 0
try:
    with open(tmp, "wb") as dst:
        for name in names:
            with open(name, "rb") as src:
                for chunk in iter(lambda: src.read(1024 * 1024), b""):
                    dst.write(chunk)
                    h.update(chunk)
                    total += len(chunk)
    if total != expected_size or h.hexdigest() != expected_sha:
        raise SystemExit(
            "merged model failed size/SHA-256 verification (total=%d, sha=%s)"
            % (total, h.hexdigest())
        )
    os.replace(tmp, out)
finally:
    if os.path.exists(tmp):
        os.remove(tmp)
print("  [merge] wrote %s (%d bytes from %d parts)" % (out, total, len(names)))
PY
