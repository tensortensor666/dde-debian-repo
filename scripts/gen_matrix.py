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

import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
CONFIG = os.path.join(ROOT, "config", "packages.json")

MAX_LAYERS = 7  # L0..L6; bump together with build.yml jobs if the DAG gets deeper

# Anything that changes how a package is built invalidates its deb cache.
# Keep this list small and explicit: adding a file here effectively busts the
# cache for every package once, which is the safe side to err on.
BUILD_INPUTS = (
    "scripts/gen_matrix.py",
    "scripts/fetch-source.sh",
    "scripts/setup-local-repo.sh",
    "scripts/drop-patches.py",
    "scripts/add-not-installed.py",
    "scripts/apply-source-fixes.py",
    "scripts/apply-source-patches.py",
    "scripts/verify-debs.sh",
    ".github/workflows/build-layer.yml",
)


def fail(msg):
    print(f"gen_matrix: {msg}", file=sys.stderr)
    sys.exit(1)


def build_cache_key(pkg, suite, enabled, stack=()):
    """Hash build-relevant inputs for a package and its local dependencies.

    The upstream commit is deliberately NOT included: it is only known after
    the shallow clone in the build job. Instead the cache key has a stable
    config part (here) plus a commit part appended by build-layer.yml.
    """
    name = pkg["name"]
    if name in stack:
        fail(f"dependency cycle while hashing: {' -> '.join(stack + (name,))}")
    payload = {
        "suite": suite,
        "name": name,
        "repo": pkg.get("repo"),
        "ref": pkg.get("ref"),
        "source": pkg.get("source", "git"),
        "depends": pkg.get("depends", []),
        "patch_exclude": pkg.get("patch_exclude", []),
        "not_installed": pkg.get("not_installed", []),
        "source_fixes": pkg.get("source_fixes", []),
        "source_patches": pkg.get("source_patches", []),
    }
    digest = hashlib.sha256()
    digest.update(json.dumps(payload, sort_keys=True, ensure_ascii=False).encode())

    paths = list(BUILD_INPUTS) + list(pkg.get("source_patches", []))
    for rel in paths:
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            fail(f"cache key input is missing: {rel}")
        with open(path, "rb") as fh:
            digest.update(fh.read())

    for dep_name in pkg.get("depends", []):
        dep = enabled.get(dep_name)
        if dep is not None:
            digest.update(f"dependency:{dep_name}:".encode())
            digest.update(build_cache_key(dep, suite, enabled, stack + (name,)).encode())
    return digest.hexdigest()[:16]


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
        # Which Debian suite / repo codename the rest of the pipeline uses.
        suite = cfg.get("suite")
        codename = cfg.get("codename")
        if not suite or not codename:
            fail("'suite' and 'codename' are required at top level")
        fh.write(f"suite={suite}\n")
        fh.write(f"codename={codename}\n")
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
                        # Patches to drop from debian/patches/series at build
                        # time (upstream patch needs a newer ABI than the distro).
                        "patches_exclude": ",".join(pkg.get("patch_exclude", [])),
                        # Paths to list in debian/not-installed so dh_missing
                        # does not abort on build artefacts no package ships.
                        "not_installed": ",".join(pkg.get("not_installed", [])),
                        # Literal source substitutions, as a JSON string, applied
                        # before the build (bridges distro/newer-Qt drift).
                        "source_fixes": json.dumps(
                            pkg.get("source_fixes", []), ensure_ascii=False
                        ),
                        # In-repo patch files applied with patch -p1 (used when a
                        # change involves tabs/newlines that JSON would mangle).
                        "source_patches": ",".join(pkg.get("source_patches", [])),
                        # Stable part of the deb cache key; the upstream commit
                        # is appended in build-layer.yml after cloning.
                        "cache_key": build_cache_key(pkg, suite, enabled),
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
