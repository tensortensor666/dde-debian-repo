#!/usr/bin/env python3
"""Read config/packages.json, compute dependency layers, emit Actions matrices.

Usage (in a workflow step):
    python3 scripts/gen_matrix.py >> "$GITHUB_OUTPUT"

Layers are computed automatically: a package goes into layer N+1 where N is the
highest layer among its enabled dependencies. Packages with no enabled deps land
in L0. This means config/packages.json only needs "depends", never a layer id.

Emits one output per layer (L0..L5) plus count_<layer>. Each value is a JSON
object {"include":[...]} accepted by strategy.matrix.fromJSON.

Only packages with "enabled": true are included. Disabled dependencies are
ignored (assumed to come from the distro).
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "..", "config", "packages.json")

MAX_LAYERS = 6  # L0..L5; bump together with build.yml jobs if the DAG gets deeper


def fail(msg):
    print(f"gen_matrix: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    with open(CONFIG, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)

    packages = cfg.get("packages")
    if not isinstance(packages, list):
        fail("'packages' missing or not an array")

    enabled = {}
    for pkg in packages:
        name = pkg.get("name")
        if not name:
            fail("a package entry is missing 'name'")
        if not pkg.get("enabled"):
            continue
        if not pkg.get("repo") or not pkg.get("ref"):
            fail(f"{name}: repo and ref are required")
        if name in enabled:
            fail(f"duplicate enabled package name: {name}")
        enabled[name] = pkg

    # Assign layers by longest-path over enabled deps only.
    layer_of = {}

    def resolve(name, stack):
        if name in layer_of:
            return layer_of[name]
        if name in stack:
            fail(f"dependency cycle: {' -> '.join(stack + [name])}")
        pkg = enabled[name]
        deps = [d for d in pkg.get("depends", []) if d in enabled]
        depth = 0
        for dep in deps:
            depth = max(depth, resolve(dep, stack + [name]) + 1)
        layer_of[name] = depth
        return depth

    for name in enabled:
        resolve(name, [])

    deepest = max(layer_of.values()) if layer_of else -1
    if deepest >= MAX_LAYERS:
        fail(
            f"dependency graph needs {deepest + 1} layers but MAX_LAYERS={MAX_LAYERS}; "
            "raise MAX_LAYERS in gen_matrix.py and add matching jobs in build.yml"
        )

    out = os.environ.get("GITHUB_OUTPUT")
    if not out:
        fail("GITHUB_OUTPUT is not set (run this inside Actions)")

    with open(out, "a", encoding="utf-8") as fh:
        for idx in range(MAX_LAYERS):
            layer = f"L{idx}"
            entries = []
            for name, pkg in sorted(enabled.items()):
                if layer_of[name] != idx:
                    continue
                entries.append(
                    {
                        "name": name,
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
            print(
                f"{layer}: {len(entries)} enabled package(s)"
                + (f" -> {', '.join(e['name'] for e in entries)}" if entries else ""),
                file=sys.stderr,
            )


if __name__ == "__main__":
    main()
