#!/usr/bin/env bash
set -euo pipefail

BIN="${1:-$(cd "$(dirname "$0")/.." && pwd)/dist/linux/carracho-web-admin-helper}"

[[ -x "$BIN" ]] || {
    echo "FEHLT oder nicht ausführbar: $BIN" >&2
    exit 2
}

echo "Helper: $BIN"
file "$BIN"

echo
echo "Dynamische Abhängigkeiten:"
ldd "$BIN" || true

echo
echo "Python-Runtime ist eingebettet; auf dem Zielsystem darf kein python3 nötig sein."
if strings "$BIN" 2>/dev/null | grep -q 'Carracho Web Admin'; then
    echo "Marker: OK"
fi
