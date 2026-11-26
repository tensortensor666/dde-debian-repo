#!/usr/bin/env bash
# Fetch upstream source into a target directory.
#   fetch-source.sh <repo> <ref> <source> <target>
#     repo   - owner/name on GitHub (e.g. linuxdeepin/dde-shell), or a full
#              https:// URL for non-GitHub hosts (e.g. salsa.debian.org)
#     ref    - branch or tag
#     source - "git" (git clone) or "apt" (apt source, reserved for L0)
set -euo pipefail

REPO="${1:?repo required}"
REF="${2:?ref required}"
SOURCE="${3:-git}"
TARGET="${4:-src}"

mkdir -p "$TARGET"

if [[ "$SOURCE" == "git" ]]; then
  if [[ "$REPO" == http://* || "$REPO" == https://* ]]; then
    # Full URL (e.g. a salsa.debian.org packaging repo). Use as-is.
    URL="$REPO"
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git"
  else
    URL="https://github.com/${REPO}.git"
  fi

  echo "fetch-source: cloning ${REPO}@${REF}"
  git clone --depth 1 --branch "$REF" --recurse-submodules \
    "$URL" "$TARGET/.clone"

  # Move everything including dotfiles into the target.
  shopt -s dotglob nullglob
  mv "$TARGET"/.clone/* "$TARGET"/
  shopt -u dotglob nullglob
  rmdir "$TARGET/.clone"

elif [[ "$SOURCE" == "apt" ]]; then
  # For private deps that only ship as Debian source packages.
  # Expects deb-src entries already configured in /etc/apt/sources.list.d/.
  echo "fetch-source: apt source ${REPO} (name=${REF})"
  apt-get source --download-only "$REPO" -o Dir::Cache::archives="$TARGET"
  (
    cd "$TARGET"
    for dsc in *.dsc; do dpkg-source -x "$dsc"; done
  )
else
  echo "fetch-source: unknown source type '$SOURCE'" >&2
  exit 1
fi

if [[ ! -d "$TARGET/debian" ]]; then
  echo "fetch-source: no debian/ directory in $TARGET — cannot build a Debian package" >&2
  exit 1
fi

echo "fetch-source: ready at $TARGET"
