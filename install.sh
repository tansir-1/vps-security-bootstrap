#!/usr/bin/env bash
set -Eeuo pipefail

REPO="tansir-1/vps-security-bootstrap"
VERSION="${VPS_SECURITY_VERSION:-10.0.0}"
TAG="v${VERSION}"
ASSET="vps-security-v${VERSION}.sh"

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
TARGET="${TMPDIR:-/tmp}/vps-security-bootstrap-${VERSION}.sh"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: This installer must run as root."
    echo "Run:"
    echo "  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash"
    exit 1
fi

for cmd in curl sha256sum awk bash; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Missing required command: $cmd"
        exit 1
    fi
done

echo "VPS Security Bootstrap installer"
echo "Version: ${TAG}"
echo "Downloading release asset..."

curl -fL --retry 3 --connect-timeout 15 "$DOWNLOAD_URL" -o "$TARGET"

case "$VERSION" in
    10.0.0)
        EXPECTED_SHA256="77072ba40afbde12da4d6868599476a95c027487ac41734e321499c4b8c7a89c"
        ;;
    *)
        echo "ERROR: No pinned SHA256 is available in this installer for ${TAG}."
        echo "Please use a tagged installer version or update install.sh for the new release."
        rm -f "$TARGET"
        exit 1
        ;;
esac

ACTUAL_SHA256="$(sha256sum "$TARGET" | awk '{print $1}')"

if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "ERROR: SHA256 verification failed."
    echo "Expected: $EXPECTED_SHA256"
    echo "Actual:   $ACTUAL_SHA256"
    rm -f "$TARGET"
    exit 1
fi

echo "SHA256 verification passed."

if ! bash -n "$TARGET"; then
    echo "ERROR: Bash syntax check failed."
    rm -f "$TARGET"
    exit 1
fi

echo "Bash syntax check passed."
echo "Starting VPS Security Bootstrap ${TAG}..."
echo

exec bash "$TARGET"
