#!/usr/bin/env bash
# Turn a directory of .deb files into an apt source available to following
# build layers. Runs inside the debian:forky build container as root.
set -euo pipefail

DEBS_DIR="${1:-upstream-debs}"

if [[ ! -d "$DEBS_DIR" ]]; then
  echo "setup-local-repo: $DEBS_DIR not found, nothing to register"
  exit 0
fi

count=$(find "$DEBS_DIR" -maxdepth 1 -name '*.deb' | wc -l)
if [[ "$count" -eq 0 ]]; then
  echo "setup-local-repo: no .deb found, skipping"
  exit 0
fi

DEBS_DIR="$(cd "$DEBS_DIR" && pwd)"

cd "$DEBS_DIR"
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
echo "setup-local-repo: indexed $count package(s)"

# apt-key-less: [trusted=yes] keeps this local source simple.
cat > /etc/apt/sources.list.d/00-dde-local.list <<EOF
deb [trusted=yes] file:$DEBS_DIR ./
EOF

apt-get update -o Dir::Etc::sourcelist="sources.list.d/00-dde-local.list" \
  -o Dir::Etc::sourceparts="-" \
  -o APT::Get::List-Cleanup="0" || true

echo "setup-local-repo: registered file:$DEBS_DIR"
