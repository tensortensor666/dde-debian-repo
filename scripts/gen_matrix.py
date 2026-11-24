#!/usr/bin/env python3
"""Read config/packages.json and emit GitHub Actions matrix outputs.

Usage (in workflow step):
    python3 scripts/gen_matrix.py >> "$GITHUB_OUTPUT"

Emits one output per layer: L0, L1, L2, L3. Each output is a JSON object
in the form {"include": [ ... ]} accepted by strategy.matrix.fromJSON.

Only packages with "enabled": true are included.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "..", "config", "packages.json")


def fail(msg):
    print(f"gen_matrix: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    with open(CONFIG, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)

    layers = cfg.get("layers")
    if not isinstance(layers, dict):
        fail("'layers' missing or not an object")

    out = os.environ.get("GITHUB_OUTPUT")
    if not out:
        fail("GITHUB_OUTPUT is not set (run this inside Actions)")

    with open(out, "a", encoding="utf-8") as fh:
        for layer in ("L0", "L1", "L2", "L3"):
            entries = []
            for pkg in layers.get(layer, []):
                if not pkg.get("enabled"):
                    continue
                if not pkg.get("repo") or not pkg.get("ref"):
                    fail(f"{layer}/{pkg.get('name')}: repo and ref are required")
                entries.append(
                    {
                        "name": pkg["name"],
                        "repo": pkg["repo"],
                        "ref": pkg["ref"],
                        "source": pkg.get("source", "git"),
                        "layer": layer,
                    }
                )
            fh.write(f"{layer}<<__MATRIX_DELIM__\n")
            fh.write(json.dumps({"include": entries}, ensure_ascii=False))
            fh.write("\n__MATRIX_DELIM__\n")
            fh.write(f"count_{layer}={len(entries)}\n")
            # Diagnostics MUST go to stderr: stdout is redirected into
            # $GITHUB_OUTPUT, which only accepts key=value / heredoc lines.
            print(f"{layer}: {len(entries)} enabled package(s)", file=sys.stderr)


if __name__ == "__main__":
    main()
