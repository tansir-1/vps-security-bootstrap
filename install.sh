#!/usr/bin/env bash
set -Eeuo pipefail

REPO="tansir-1/vps-security-bootstrap"
VERSION="${VPS_SECURITY_VERSION:-10.1.2}"
TAG="v${VERSION}"
ASSET="vps-security-v${VERSION}.sh"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: This installer must run as root."
    echo "Run:"
    echo "  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash"
    exit 1
fi

for cmd in curl sha256sum awk bash mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: Missing required command: $cmd"; exit 1; }
done

TARGET="$(mktemp /tmp/vps-security-bootstrap.XXXXXX.sh)"
cleanup() { rm -f "$TARGET"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
chmod 700 "$TARGET"

case "$VERSION" in
    10.1.2) EXPECTED_SHA256="3a7bf7844d2043acb59bf8402d6790af5caaf1b0ec19fa60d12f73f21a322390" ;;
    10.1.1) EXPECTED_SHA256="41f35fbabbf530acbf675b656b40a4fde0c0178554951d9189e7571afcd11648" ;;
    10.1.0) EXPECTED_SHA256="7eff3046de6fd3c91739c40475fcbd1379e9d7d9aa4ca357edbc2e97c89d29d0" ;;
    *) echo "ERROR: No pinned SHA256 is available in this installer for $TAG."; exit 1 ;;
esac

echo "VPS Security Bootstrap installer"
echo "Version: $TAG"
echo "Downloading release asset..."
curl -fL --retry 3 --connect-timeout 15 "$DOWNLOAD_URL" -o "$TARGET"
ACTUAL_SHA256="$(sha256sum "$TARGET" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "ERROR: SHA256 verification failed."
    echo "Expected: $EXPECTED_SHA256"
    echo "Actual:   $ACTUAL_SHA256"
    exit 1
fi

echo "SHA256 verification passed."
bash -n "$TARGET" || { echo "ERROR: Bash syntax check failed."; exit 1; }
echo "Bash syntax check passed."
echo "Starting VPS Security Bootstrap $TAG..."
echo
set +e
bash "$TARGET"
RC=$?
set -e
exit "$RC"
