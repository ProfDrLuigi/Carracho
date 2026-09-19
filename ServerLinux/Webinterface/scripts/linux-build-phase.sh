#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-}"

"$ROOT/scripts/build-linux-helper.sh"

BIN="$ROOT/dist/linux/carracho-web-admin-helper"
[[ -x "$BIN" ]] || {
    echo "error: WebAdmin helper fehlt nach Build: $BIN" >&2
    exit 1
}

if [[ -n "$DEST" ]]; then
    install -d "$DEST"
    install -m 0755 "$BIN" "$DEST/carracho-web-admin-helper"
    echo "WebAdmin: eingebettet -> $DEST/carracho-web-admin-helper"
else
    echo "WebAdmin: gebaut -> $BIN"
fi
