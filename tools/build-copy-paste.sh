#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vps-security.sh"
VERSION_FILE="$ROOT/VERSION"
DIST="$ROOT/dist"

[[ -f "$SRC" ]] || { echo "missing: $SRC" >&2; exit 1; }
[[ -f "$VERSION_FILE" ]] || { echo "missing: $VERSION_FILE" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ -n "$VERSION" ]] || { echo "VERSION is empty" >&2; exit 1; }
mkdir -p "$DIST"

EXPECTED_SHA256="$(sha256sum "$SRC" | awk '{print $1}')"
TMP_GZ="$(mktemp)"
TMP_B64="$(mktemp)"
trap 'rm -f "$TMP_GZ" "$TMP_B64"' EXIT

gzip -n -9 -c "$SRC" > "$TMP_GZ"
base64 -w 76 "$TMP_GZ" > "$TMP_B64"

OUT="$DIST/vps-security-copy-paste.txt"
cat > "$OUT" <<EOF2
# VPS Security Bootstrap v$VERSION
# 整段复制到 Debian/Ubuntu SSH 终端执行；无需提前上传 .sh 文件。
TARGET="\${HOME:-/tmp}/vps-security-bootstrap-v$VERSION.sh"
PAYLOAD="/tmp/vps-security-bootstrap-v$VERSION.gz.b64"
EXPECTED_SHA256="$EXPECTED_SHA256"
cat > "\$PAYLOAD" <<'VPSSEC_PAYLOAD'
EOF2
cat "$TMP_B64" >> "$OUT"
cat >> "$OUT" <<'EOF2'
VPSSEC_PAYLOAD
if ! base64 -d "$PAYLOAD" | gzip -dc > "$TARGET"; then
    echo "❌ Payload 解码失败。"
    rm -f "$PAYLOAD" "$TARGET"
    return 1 2>/dev/null || exit 1
fi
rm -f "$PAYLOAD"
ACTUAL_SHA256="$(sha256sum "$TARGET" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "❌ SHA256 完整性校验失败。"
    echo "Expected: $EXPECTED_SHA256"
    echo "Actual:   $ACTUAL_SHA256"
    rm -f "$TARGET"
    return 1 2>/dev/null || exit 1
fi
chmod 700 "$TARGET"
if ! bash -n "$TARGET"; then
    echo "❌ Bash 语法检查失败，拒绝执行。"
    rm -f "$TARGET"
    return 1 2>/dev/null || exit 1
fi
echo "✅ 完整性校验通过：$ACTUAL_SHA256"
echo "✅ 脚本位置：$TARGET"
bash "$TARGET"
EOF2

chmod 644 "$OUT"
(
    cd "$ROOT"
    sha256sum vps-security.sh dist/vps-security-copy-paste.txt > dist/SHA256SUMS
)

echo "Built: $OUT"
echo "Source SHA256: $EXPECTED_SHA256"
