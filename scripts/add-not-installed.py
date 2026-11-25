#!/usr/bin/env python3
"""Append paths to a source tree's debian/not-installed.

Usage:
    add-not-installed.py <src_dir> "<path-or-glob>,<path-or-glob>"

dh_missing in debhelper compat 13 fails the build when files installed by
upstream land in no binary package. debian/not-installed is the documented
way to declare them intentionally excluded (build artefacts such as Qt's
generated SBOM files, which Debian's own Qt packaging also drops).

Existing entries are preserved; the file is created when absent.
"""

import os
import sys


def main():
    if len(sys.argv) < 3:
        print("usage: add-not-installed.py <src_dir> <comma-separated paths>", file=sys.stderr)
        return 2

    src = sys.argv[1]
    wanted = [p.strip() for p in sys.argv[2].split(",") if p.strip()]
    if not wanted:
        print("add-not-installed: nothing to add", file=sys.stderr)
        return 0

    path = os.path.join(src, "debian", "not-installed")
    existing = []
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as fh:
            existing = [ln.rstrip("\n") for ln in fh]

    seen = {ln.strip() for ln in existing}
    added = [p for p in wanted if p not in seen]

    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        for ln in existing:
            fh.write(ln + "\n")
        for p in added:
            fh.write(p + "\n")
            print(f"add-not-installed: {p}", file=sys.stderr)

    if not added:
        print("add-not-installed: already present", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
