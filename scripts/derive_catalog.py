#!/usr/bin/env python3
"""从 KuiklyLLMProviderAssets/catalog.json 派生指定变体的 catalog.json，写入各输出目录。

用法：
  derive_catalog.py <download|bundled> <out-dir>...
  derive_catalog.py --current   打印当前已派生的变体；尚未派生（全新 clone）时打印仓库默认 bundled

bundled 变体仅首个模型标记为内置；Assets/catalog.json 是只读基准，不写回。
prepare-variant.sh 与 prepare-pod-assets.sh 共用，保证三端与 CocoaPods 派生规则一致。
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_VARIANT = "bundled"


def current():
    # 三端由 prepare-variant.sh 同步派生，取 Android 一份即可代表当前变体。
    p = os.path.join(ROOT, "KuiklyLLMProviderAndroid/src/main/assets/catalog.json")
    try:
        with open(p, encoding="utf-8") as f:
            v = json.load(f).get("variant")
    except (OSError, ValueError):
        v = None
    print(v if v in ("download", "bundled") else DEFAULT_VARIANT)


def derive(variant, outs):
    with open(os.path.join(ROOT, "KuiklyLLMProviderAssets/catalog.json"), encoding="utf-8") as f:
        cat = json.load(f)
    for i, m in enumerate(cat["models"]):
        m["bundled"] = variant == "bundled" and i == 0
    cat["variant"] = variant
    for d in outs:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "catalog.json"), "w", encoding="utf-8") as f:
            json.dump(cat, f, ensure_ascii=False, indent=2)
    print("  catalog.json written (variant=%s)" % variant)


def main():
    if sys.argv[1:] == ["--current"]:
        current()
    elif len(sys.argv) >= 3 and sys.argv[1] in ("download", "bundled"):
        derive(sys.argv[1], sys.argv[2:])
    else:
        raise SystemExit("usage: derive_catalog.py download|bundled <out-dir>... | --current")


if __name__ == "__main__":
    main()
