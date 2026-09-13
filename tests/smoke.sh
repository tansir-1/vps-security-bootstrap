#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/vps-security.sh"
bash -n "$ROOT/tools/build-copy-paste.sh"
version="$(bash "$ROOT/vps-security.sh" --version)"
[[ "$version" == *"$(cat "$ROOT/VERSION")"* ]]
bash "$ROOT/vps-security.sh" --help | grep -q 'VPS Security Bootstrap'
echo "smoke tests passed"
