#!/usr/bin/env bash
# Build a signed APT repository from a directory of .deb files.
#   publish-repo.sh <debs_dir> <out_dir> [previous_repo_dir]
# When previous_repo_dir is given (a checkout of the published gh-pages tree),
# its reprepro database and pool are imported first so packages built by older
# runs stay published; only genuinely new versions are added.
# Uses reprepro. Signing key must already be imported into the running
# GPG keyring (done by build.yml from secrets.GPG_PRIVATE_KEY).
set -euo pipefail

DEBS_DIR="${1:?debs dir required}"
OUT_DIR="${2:?out dir required}"
PREV_DIR="${3:-}"
CODENAME="${CODENAME:-dde25}"

mkdir -p "$OUT_DIR/conf" "$OUT_DIR/pool"

# Copy reprepro config from the repo (source of truth) into the output tree.
# Resolve path relative to this script so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cp "$REPO_ROOT/apt-repo/conf/distributions" "$OUT_DIR/conf/distributions"
cp "$REPO_ROOT/apt-repo/conf/options" "$OUT_DIR/conf/options"

# Import the previously published state, if any, before adding new debs.
if [[ -n "$PREV_DIR" && -d "$PREV_DIR/db" ]]; then
  echo "publish-repo: importing previous repo state from $PREV_DIR"
  cp -a "$PREV_DIR/db/." "$OUT_DIR/db/"
  if [[ -d "$PREV_DIR/pool" ]]; then
    cp -a "$PREV_DIR/pool/." "$OUT_DIR/pool/"
  fi
else
  echo "publish-repo: no previous state, starting a fresh repository"
fi

shopt -s nullglob
DEBS=("$DEBS_DIR"/*.deb)
shopt -u nullglob

if [[ ${#DEBS[@]} -eq 0 ]]; then
  echo "publish-repo: no .deb to publish" >&2
  exit 1
fi

# Add each deb. A package already published at the same version is skipped:
# reprepro would otherwise abort on the duplicate.
for deb in "${DEBS[@]}"; do
  pkg="$(dpkg-deb -f "$deb" Package)"
  ver="$(dpkg-deb -f "$deb" Version)"
  if reprepro -b "$OUT_DIR" -T deb ls "$CODENAME" "$pkg" 2>/dev/null \
       | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' \
       | grep -qx "$ver"; then
    echo "publish-repo: skipping $(basename "$deb") ($pkg $ver already published)"
    continue
  fi
  echo "publish-repo: including $(basename "$deb")"
  reprepro -b "$OUT_DIR" includedeb "$CODENAME" "$deb"
done

# Export public key for end users.
KEY_ID="${SIGNING_KEY_ID:-}"
if [[ -n "$KEY_ID" ]]; then
  gpg --armor --export "$KEY_ID" > "$OUT_DIR/dde-repo.key"
else
  gpg --armor --export > "$OUT_DIR/dde-repo.key"
fi

cat > "$OUT_DIR/index.html" <<'EOF'
<!doctype html><meta charset="utf-8">
<title>DDE for Debian repository</title>
<h1>DDE for Debian</h1>
<p>APT repository. Use <code>dde-repo.key</code> to verify signatures.</p>
EOF

echo "publish-repo: done, output in $OUT_DIR"
