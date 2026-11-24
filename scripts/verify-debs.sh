#!/usr/bin/env bash
# Lightweight sanity check on built .deb files before publishing.
set -euo pipefail

DIR="${1:-artifacts}"
shopt -s nullglob
DEBS=("$DIR"/*.deb)
shopt -u nullglob

if [[ ${#DEBS[@]} -eq 0 ]]; then
  echo "verify-debs: no .deb found in $DIR" >&2
  exit 1
fi

for deb in "${DEBS[@]}"; do
  echo "verify-debs: checking $(basename "$deb")"
  dpkg-deb --field "$deb" Package Version Architecture >/dev/null
  pkg=$(dpkg-deb --field "$deb" Package)
  ver=$(dpkg-deb --field "$deb" Version)
  arch=$(dpkg-deb --field "$deb" Architecture)

  if [[ -z "$pkg" || -z "$ver" ]]; then
    echo "verify-debs: empty Package/Version in $deb" >&2
    exit 1
  fi

  case "$arch" in
    amd64|all) ;;
    *) echo "verify-debs: unexpected arch '$arch' in $deb" >&2; exit 1 ;;
  esac

  echo "  $pkg $ver ($arch)"
done

echo "verify-debs: ${#DEBS[@]} package(s) OK"
