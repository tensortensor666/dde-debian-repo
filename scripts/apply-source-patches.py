#!/usr/bin/env python3
"""Apply in-repo patch files to an unpacked source tree.

Usage:
    apply-source-patches.py <src_dir> "patches/a.patch,patches/b.patch"

Patches are stored in this repository (see patches/) and applied with
`patch -p1` inside <src_dir>. File-based patches are used instead of inline
string substitutions whenever the change involves whitespace-significant
source: passing tabs/newlines through a JSON config -> Actions matrix -> env
round trip silently mangles them.

Fails if any patch does not apply cleanly, so drift is loud.
"""

import os
import subprocess
import sys


def main():
    if len(sys.argv) < 3:
        print("usage: apply-source-patches.py <src_dir> <comma-separated patches>", file=sys.stderr)
        return 2

    src = sys.argv[1]
    items = [p.strip() for p in sys.argv[2].split(",") if p.strip()]
    if not items:
        print("apply-source-patches: nothing to apply", file=sys.stderr)
        return 0

    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(here)

    failed = 0
    for rel in items:
        path = rel if os.path.isabs(rel) else os.path.join(repo_root, rel)
        if not os.path.isfile(path):
            print(f"apply-source-patches: missing patch {rel}", file=sys.stderr)
            failed += 1
            continue
        with open(path, "rb") as fh:
            proc = subprocess.run(
                ["patch", "-p1", "--forward", "--fuzz=2", "--batch", "-d", src],
                stdin=fh,
                capture_output=True,
            )
        if proc.returncode != 0:
            print(f"apply-source-patches: {rel} FAILED", file=sys.stderr)
            sys.stderr.write(proc.stdout.decode("utf-8", "replace"))
            sys.stderr.write(proc.stderr.decode("utf-8", "replace"))
            failed += 1
        else:
            print(f"apply-source-patches: applied {rel}", file=sys.stderr)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
