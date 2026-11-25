#!/usr/bin/env python3
"""Remove named patches from a source tree's debian/patches/series.

Usage:
    drop-patches.py <src_dir> "name1.patch,name2.patch"

Used when a deepin patch depends on a newer Qt/ABI than the distro ships.
Removing it from series makes quilt skip it while the rest still apply.

Exits non-zero if a named patch is not present in series, so a stale
exclusion cannot silently turn into a no-op.
"""

import os
import sys


def main():
    if len(sys.argv) < 3:
        print("usage: drop-patches.py <src_dir> <comma-separated patches>", file=sys.stderr)
        return 2

    src = sys.argv[1]
    wanted = [p.strip() for p in sys.argv[2].split(",") if p.strip()]
    if not wanted:
        print("drop-patches: nothing to drop", file=sys.stderr)
        return 0

    series = os.path.join(src, "debian", "patches", "series")
    if not os.path.isfile(series):
        print(f"drop-patches: {series} not found", file=sys.stderr)
        return 1

    with open(series, "r", encoding="utf-8") as fh:
        lines = fh.readlines()

    kept, dropped = [], []
    for line in lines:
        name = line.strip()
        if name and not name.startswith("#") and name in wanted:
            dropped.append(name)
            print(f"drop-patches: dropping {name}", file=sys.stderr)
            continue
        kept.append(line)

    missing = [w for w in wanted if w not in dropped]
    if missing:
        print(f"drop-patches: not in series: {', '.join(missing)}", file=sys.stderr)
        return 1

    with open(series, "w", encoding="utf-8", newline="\n") as fh:
        fh.writelines(kept)

    print(f"drop-patches: dropped {len(dropped)} patch(es)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
