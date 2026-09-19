#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${CARRACHO_WEBADMIN_PYTHON:-${PYTHON:-python3}}"
BUILD_DIR="${CARRACHO_WEBADMIN_BUILD_DIR:-$ROOT/.build}"
VENV="$BUILD_DIR/venv"
DIST="${CARRACHO_WEBADMIN_DIST_DIR:-$ROOT/dist}"
NAME="carracho-web-admin-helper"
TARGET_ARCH="${TARGET_ARCH:-universal2}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}"
SIGN_ID="${CODESIGN_IDENTITY:-}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Fehler: Dieser Build muss auf macOS laufen." >&2
  exit 2
fi

command -v "$PYTHON" >/dev/null 2>&1 || {
  echo "Fehler: Python 3 fehlt auf dem Build-Mac." >&2
  exit 3
}

REAL_PY="$($PYTHON -c 'import os,sys; print(os.path.realpath(sys.executable))')"

if [[ "$TARGET_ARCH" == "universal2" ]]; then
  ARCHS_FOUND="$(lipo -archs "$REAL_PY" 2>/dev/null || true)"
  [[ "$ARCHS_FOUND" == *x86_64* && "$ARCHS_FOUND" == *arm64* ]] || {
    echo "Fehler: universal2 verlangt universal2-Python; gefunden: ${ARCHS_FOUND:-unbekannt}" >&2
    exit 4
  }
fi

mkdir -p "$BUILD_DIR" "$DIST"
if [[ ! -x "$VENV/bin/python" ]]; then
  "$PYTHON" -m venv "$VENV"
fi
if ! "$VENV/bin/python" -c 'import PyInstaller' >/dev/null 2>&1; then
  "$VENV/bin/python" -m pip install --disable-pip-version-check "pyinstaller>=6.10,<7"
fi

rm -rf "$BUILD_DIR/pyinstaller" "$BUILD_DIR/spec" "$DIST/$NAME"
mkdir -p "$BUILD_DIR/pyinstaller" "$BUILD_DIR/spec"

ARGS=(
  --noconfirm
  --clean
  --onefile
  --name "$NAME"
  --distpath "$DIST"
  --workpath "$BUILD_DIR/pyinstaller"
  --specpath "$BUILD_DIR/spec"
  --add-data "$ROOT/web:web"
  --exclude-module tkinter
  --exclude-module tkinter.ttk
  --exclude-module idlelib
  --exclude-module ensurepip
  --exclude-module unittest
  --exclude-module test
  --target-arch "$TARGET_ARCH"
)

if [[ -n "$SIGN_ID" && "$SIGN_ID" != "-" ]]; then
  ARGS+=(--codesign-identity "$SIGN_ID")
fi

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
"$VENV/bin/pyinstaller" "${ARGS[@]}" "$ROOT/helper/web_admin.py"

BIN="$DIST/$NAME"
[[ -x "$BIN" ]] || { echo "Fehler: Helper fehlt: $BIN" >&2; exit 6; }

if [[ -n "$SIGN_ID" ]]; then
  /usr/bin/codesign --force --sign "$SIGN_ID" --timestamp=none "$BIN"
  /usr/bin/codesign --verify --strict --verbose=2 "$BIN"
fi

echo "WebAdmin ONEFILE Helper gebaut: $BIN"
lipo -archs "$BIN" 2>/dev/null || file "$BIN"
