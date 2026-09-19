#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/dist/carracho-web-admin-helper"
APP="${1:-}"

if [[ -z "$APP" || ! -d "$APP/Contents" ]]; then
  echo "Benutzung: $0 '/Pfad/zu/Carracho Server.app'" >&2
  exit 2
fi
if [[ ! -x "$HELPER/carracho-web-admin-helper" ]]; then
  echo "Helper fehlt. Erst scripts/build-helper.sh ausführen." >&2
  exit 3
fi

DEST="$APP/Contents/Helpers/CarrachoWebAdmin"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
ditto "$HELPER" "$DEST"

echo "Eingebettet nach:"
echo "  $DEST"
echo
echo "Hinweis: Ein bereits signiertes .app-Bundle ist danach neu zu signieren."
echo "Sauberer ist die Xcode Run-Script-Phase aus docs/XCODE_INTEGRATION.md,"
echo "damit das Kopieren vor der finalen App-Signatur passiert."
