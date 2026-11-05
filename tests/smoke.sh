#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/vps-security.sh"
bash -n "$ROOT/tools/build-copy-paste.sh"
version="$(bash "$ROOT/vps-security.sh" --version)"
[[ "$version" == *"$(cat "$ROOT/VERSION")"* ]]
bash "$ROOT/vps-security.sh" --help | grep -q 'VPS Security Bootstrap'
if bash "$ROOT/vps-security.sh" --unknown >/dev/null 2>&1; then
    echo 'unknown option must fail' >&2
    exit 1
fi
if bash "$ROOT/vps-security.sh" --audit --unknown >/dev/null 2>&1; then
    echo 'extra arguments must fail' >&2
    exit 1
fi
echo "smoke tests passed"
