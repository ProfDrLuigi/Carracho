#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="carracho-web-admin-helper"

PYTHON="${CARRACHO_WEBADMIN_PYTHON:-${PYTHON:-python3}}"
CACHE_ROOT="${CARRACHO_WEBADMIN_CACHE_ROOT:-$ROOT/.linux-build}"
VENV="$CACHE_ROOT/venv"
WORK="$CACHE_ROOT/pyinstaller"
SPEC="$CACHE_ROOT/spec"
DIST="${CARRACHO_WEBADMIN_DIST_DIR:-$ROOT/dist/linux}"

log() { printf 'WebAdmin: %s\n' "$*"; }
die() { printf 'error: WebAdmin: %s\n' "$*" >&2; exit 1; }

command -v "$PYTHON" >/dev/null 2>&1 || die "Python 3 fehlt auf dem BUILD-Rechner. Setze CARRACHO_WEBADMIN_PYTHON."
[[ "$(uname -s)" == "Linux" ]] || die "Dieses Script baut die Linux-Version und muss unter Linux laufen."

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) ARCH_TAG="x86_64" ;;
    aarch64|arm64) ARCH_TAG="aarch64" ;;
    *) die "Nicht unterstützte Linux-Architektur: $ARCH" ;;
esac

mkdir -p "$CACHE_ROOT" "$DIST"

INPUTS=(
    "$ROOT/helper/web_admin.py"
    "$ROOT/web/index.html"
    "$ROOT/scripts/build-linux-helper.sh"
)

for f in "${INPUTS[@]}"; do
    [[ -f "$f" ]] || die "Build-Input fehlt: $f"
done

PY_REAL="$("$PYTHON" -c 'import os,sys; print(os.path.realpath(sys.executable))')"
PY_VER="$("$PYTHON" -c 'import sys; print(".".join(map(str,sys.version_info[:3])))')"
GLIBC="$(
  getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' ||
  ldd --version 2>/dev/null | head -1 | grep -Eo '[0-9]+\.[0-9]+' | tail -1 ||
  true
)"

SIG_FILE="$CACHE_ROOT/build.signature"
BIN="$DIST/$NAME"
SIGNATURE="$({
    printf 'python=%s\n' "$PY_REAL"
    printf 'pythonVersion=%s\n' "$PY_VER"
    printf 'arch=%s\n' "$ARCH_TAG"
    printf 'glibc=%s\n' "${GLIBC:-unknown}"
    printf 'mode=onefile-linux-v9\n'
    for f in "${INPUTS[@]}"; do sha256sum "$f"; done
} | sha256sum | awk '{print $1}')"

if [[ -x "$BIN" && -f "$SIG_FILE" && "$(cat "$SIG_FILE" 2>/dev/null || true)" == "$SIGNATURE" ]]; then
    log "Helper unverändert, PyInstaller wird übersprungen"
    exit 0
fi

if [[ ! -x "$VENV/bin/python" ]] || ! "$VENV/bin/python" -m pip --version >/dev/null 2>&1; then
    rm -rf "$VENV"
    "$PYTHON" -m venv "$VENV"
fi

if ! "$VENV/bin/python" -c 'import PyInstaller' >/dev/null 2>&1; then
    log "installiere PyInstaller in Build-Venv"
    "$VENV/bin/python" -m pip install --disable-pip-version-check "pyinstaller>=6.10,<7"
fi

rm -rf "$WORK" "$SPEC" "$BIN"
mkdir -p "$WORK" "$SPEC" "$DIST"

log "baue ONEFILE-Helper ($ARCH_TAG, Python $PY_VER, glibc ${GLIBC:-?})"

"$VENV/bin/pyinstaller" \
    --noconfirm \
    --clean \
    --onefile \
    --name "$NAME" \
    --distpath "$DIST" \
    --workpath "$WORK" \
    --specpath "$SPEC" \
    --add-data "$ROOT/web:web" \
    --exclude-module tkinter \
    --exclude-module tkinter.ttk \
    --exclude-module idlelib \
    --exclude-module ensurepip \
    --exclude-module unittest \
    --exclude-module test \
    "$ROOT/helper/web_admin.py"

[[ -x "$BIN" ]] || die "PyInstaller hat kein Helper-Binary erzeugt: $BIN"
printf '%s\n' "$SIGNATURE" > "$SIG_FILE"

log "gebaut -> $BIN"
if command -v file >/dev/null 2>&1; then
    file "$BIN"
else
    log "Hinweis: file(1) fehlt; ELF-Detailprüfung wird übersprungen"
fi
