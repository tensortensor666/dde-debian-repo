#!/usr/bin/env python3
"""Apply literal text substitutions to an unpacked source tree.

Usage:
    FIXES='[{...}]' apply-source-fixes.py <src_dir>

Reads a JSON array from $FIXES, each item:
    {"file": "relative/path", "find": "text", "replace": "text", "count": 1}

Used to bridge deepin sources against a newer distro Qt: private headers
change between Qt patch releases, and an `override` that no longer matches
turns into a hard compile error. Substitutions are literal (no regex), so a
stale rule fails loudly instead of silently mangling code.

Every rule must match at least once or the build aborts: a silently skipped
fix would resurface later as a confusing compile error.
"""

import json
import os
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: apply-source-fixes.py <src_dir>", file=sys.stderr)
        return 2

    src = sys.argv[1]
    raw = os.environ.get("FIXES", "").strip()
    if not raw:
        print("apply-source-fixes: FIXES empty, nothing to do", file=sys.stderr)
        return 0

    try:
        fixes = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"apply-source-fixes: bad JSON in FIXES: {exc}", file=sys.stderr)
        return 2

    if not isinstance(fixes, list):
        print("apply-source-fixes: FIXES must be a JSON array", file=sys.stderr)
        return 2

    failures = 0
    for idx, rule in enumerate(fixes, 1):
        rel = rule.get("file")
        needle = rule.get("find")
        repl = rule.get("replace", "")
        count = rule.get("count", 1)
        if not rel or needle is None:
            print(f"apply-source-fixes: rule {idx} needs file/find", file=sys.stderr)
            failures += 1
            continue

        path = os.path.join(src, rel)
        if not os.path.isfile(path):
            print(f"apply-source-fixes: rule {idx}: no such file {rel}", file=sys.stderr)
            failures += 1
            continue

        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()

        hits = text.count(needle)
        if hits < count:
            print(
                f"apply-source-fixes: rule {idx}: {rel} contains the pattern "
                f"{hits} time(s), expected {count} — upstream drifted",
                file=sys.stderr,
            )
            failures += 1
            continue

        text = text.replace(needle, repl, count)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        print(f"apply-source-fixes: rule {idx}: patched {rel} ({count}x)", file=sys.stderr)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
