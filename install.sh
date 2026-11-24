#!/usr/bin/env bash
# Client-side installer: add this repository to a Debian 13 system.
#   curl -fsSL https://<USER>.github.io/<REPO>/install.sh | sudo bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root / sudo" >&2
  exit 1
fi

BASE_URL="${REPO_URL:-https://chenchongbiao.github.io/dde-debian-repo}"
CODENAME="${CODENAME:-dde25}"

echo "[1/4] Install keyring"
curl -fsSL "${BASE_URL}/dde-repo.key" \
  -o /usr/share/keyrings/dde-repo.gpg

echo "[2/4] Add apt source"
cat > /etc/apt/sources.list.d/dde-repo.list <<EOF
deb [signed-by=/usr/share/keyrings/dde-repo.gpg] ${BASE_URL} ${CODENAME} main
EOF

echo "[3/4] apt update"
apt-get update

echo "[4/4] Done. Available groups:"
echo "  apt install deepin-desktop-environment-base"
echo "  apt install deepin-desktop-environment-core"
echo "  apt install deepin-desktop-environment-extras"
