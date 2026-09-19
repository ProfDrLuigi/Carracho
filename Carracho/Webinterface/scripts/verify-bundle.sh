#!/bin/bash
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP/Contents" ]]; then
  echo "Benutzung: $0 '/Pfad/zu/Carracho Server.app'" >&2
  exit 2
fi

DIR="$APP/Contents/Helpers/CarrachoWebAdmin"
H="$DIR/carracho-web-admin-helper"

[[ -x "$H" ]] || { echo "FEHLT: $H" >&2; exit 3; }

if [[ -e "$DIR/_internal" || -e "$DIR/base_library.zip" ]]; then
  echo "FEHLER: alte PyInstaller-onedir-Struktur gefunden." >&2
  find "$DIR" -maxdepth 2 -print >&2
  exit 4
fi

COUNT="$(find "$DIR" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')"
[[ "$COUNT" == "1" ]] || {
  echo "FEHLER: Contents/Helpers/CarrachoWebAdmin soll genau das ONEFILE-Binary enthalten." >&2
  find "$DIR" -maxdepth 2 -print >&2
  exit 5
}

echo "Helper: $H"
file "$H"
lipo -archs "$H" 2>/dev/null || true

echo "Helper-Signatur:"
codesign --verify --strict --verbose=2 "$H"
codesign -dv --verbose=2 "$H" 2>&1 | sed -n '1,30p'

echo "Parent-App-Signatur:"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "OK: Bundle und Nested Helper sind signiert."
