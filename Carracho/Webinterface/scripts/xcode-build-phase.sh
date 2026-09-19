#!/bin/bash
set -euo pipefail

# Carracho Server – WebAdmin build + embed (v8)
#
# Wichtig:
#   - Webinterface ist KEINE Copy-Bundle-Resource.
#   - Build-Cache liegt ausschließlich in DerivedData.
#   - PyInstaller baut ONEFILE, damit Contents/Helpers ausschließlich echten
#     Nested Code enthält und keine base_library.zip / _internal-Daten.
#   - Der Helper wird VOR Xcodes finalem App-CodeSign explizit signiert.

log() { printf 'WebAdmin: %s\n' "$*"; }
die() { printf 'error: WebAdmin: %s\n' "$*" >&2; exit 1; }

: "${SRCROOT:?SRCROOT fehlt}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR fehlt}"
: "${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH fehlt}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="carracho-web-admin-helper"

CACHE_ROOT="${CARRACHO_WEBADMIN_CACHE_ROOT:-${DERIVED_FILE_DIR:-${TEMP_DIR:-/tmp}}/CarrachoWebAdmin}"
BUILD_DIR="$CACHE_ROOT/build"
DIST_DIR="$CACHE_ROOT/dist"
VENV_DIR="$CACHE_ROOT/venv"
STAMP="$CACHE_ROOT/build.signature"

DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/CarrachoWebAdmin"
DIST_BIN="$DIST_DIR/$NAME"
DEST_BIN="$DEST/$NAME"

mkdir -p "$CACHE_ROOT" "$BUILD_DIR" "$DIST_DIR"

# Altlasten aus älteren Versionen entfernen.
rm -rf "$ROOT/.xcode-build" 2>/dev/null || true

if [[ -n "${CARRACHO_WEBADMIN_PYTHON:-}" ]]; then
    PYTHON="$CARRACHO_WEBADMIN_PYTHON"
elif [[ -x /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 ]]; then
    PYTHON=/Library/Frameworks/Python.framework/Versions/3.11/bin/python3
elif command -v python3.11 >/dev/null 2>&1; then
    PYTHON="$(command -v python3.11)"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON="$(command -v python3)"
else
    die "Kein Python 3 auf dem Build-Mac gefunden. Setze CARRACHO_WEBADMIN_PYTHON."
fi
[[ -x "$PYTHON" ]] || die "Python ist nicht ausführbar: $PYTHON"

ARCH_LIST=" ${ARCHS:-${CURRENT_ARCH:-$(uname -m)}} "
if [[ "$ARCH_LIST" == *" arm64 "* && "$ARCH_LIST" == *" x86_64 "* ]]; then
    TARGET_ARCH=universal2
elif [[ "$ARCH_LIST" == *" x86_64 "* ]]; then
    TARGET_ARCH=x86_64
else
    TARGET_ARCH=arm64
fi

DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}"

INPUTS=(
    "$ROOT/helper/web_admin.py"
    "$ROOT/web/index.html"
    "$ROOT/scripts/xcode-build-phase.sh"
)

for f in "${INPUTS[@]}"; do
    [[ -f "$f" ]] || die "Build-Input fehlt: $f"
done

PY_REAL="$("$PYTHON" -c 'import os,sys; print(os.path.realpath(sys.executable))')"
PY_VER="$("$PYTHON" -c 'import sys; print(".".join(map(str,sys.version_info[:3])))')"

if [[ "$TARGET_ARCH" == "universal2" ]]; then
    FOUND="$(lipo -archs "$PY_REAL" 2>/dev/null || true)"
    if [[ "$FOUND" != *"arm64"* || "$FOUND" != *"x86_64"* ]]; then
        die "Archive verlangt universal2, aber Python ist '${FOUND:-unbekannt}'. Setze CARRACHO_WEBADMIN_PYTHON auf einen universal2-Python."
    fi
fi

# Xcodes Signing Identity bestimmen.
#
# Debug / "Sign to Run Locally" endet effektiv bei `codesign --sign -`.
# Release/Archive nutzt EXPANDED_CODE_SIGN_IDENTITY.
SIGN_ID=""
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
    if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        SIGN_ID="$EXPANDED_CODE_SIGN_IDENTITY"
    elif [[ -n "${CODE_SIGN_IDENTITY:-}" && "${CODE_SIGN_IDENTITY}" != "-" ]]; then
        SIGN_ID="$CODE_SIGN_IDENTITY"
    else
        SIGN_ID="-"
    fi
fi

SIGNATURE="$({
    printf 'python=%s\n' "$PY_REAL"
    printf 'pythonVersion=%s\n' "$PY_VER"
    printf 'arch=%s\n' "$TARGET_ARCH"
    printf 'deployment=%s\n' "$DEPLOYMENT_TARGET"
    printf 'pyinstallerMode=onefile-v8\n'
    for f in "${INPUTS[@]}"; do shasum -a 256 "$f"; done
} | shasum -a 256 | awk '{print $1}')"

NEEDS_BUILD=1
if [[ -x "$DIST_BIN" && -f "$STAMP" && "$(cat "$STAMP" 2>/dev/null || true)" == "$SIGNATURE" ]]; then
    NEEDS_BUILD=0
fi

if [[ "$NEEDS_BUILD" -eq 1 ]]; then
    log "baue ONEFILE-Helper ($TARGET_ARCH, macOS $DEPLOYMENT_TARGET) mit Python $PY_VER"

    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        rm -rf "$VENV_DIR"
        "$PYTHON" -m venv "$VENV_DIR"
    fi

    if ! "$VENV_DIR/bin/python" -c 'import PyInstaller' >/dev/null 2>&1; then
        "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check "pyinstaller>=6.10,<7"
    fi

    rm -rf "$BUILD_DIR/pyinstaller" "$BUILD_DIR/spec" "$DIST_BIN"
    mkdir -p "$BUILD_DIR/pyinstaller" "$BUILD_DIR/spec" "$DIST_DIR"

    ARGS=(
        --noconfirm
        --clean
        --onefile
        --name "$NAME"
        --distpath "$DIST_DIR"
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

    # Für eine echte Developer-ID signiert PyInstaller die eingebetteten
    # Mach-O-Komponenten schon vor dem Packen. Bei ad-hoc darf PyInstaller
    # selbst ad-hoc signieren; das finale ONEFILE-Binary signieren wir unten.
    if [[ -n "$SIGN_ID" && "$SIGN_ID" != "-" ]]; then
        ARGS+=(--codesign-identity "$SIGN_ID")
    fi

    export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    "$VENV_DIR/bin/pyinstaller" "${ARGS[@]}" "$ROOT/helper/web_admin.py"

    [[ -x "$DIST_BIN" ]] || die "PyInstaller hat kein ONEFILE-Helper-Binary erzeugt: $DIST_BIN"
    printf '%s\n' "$SIGNATURE" > "$STAMP"
else
    log "Helper unverändert, PyInstaller wird übersprungen"
fi

# Nur EIN ausführbares Nested-Code-Objekt nach Contents/Helpers kopieren.
rm -rf "$DEST"
mkdir -p "$DEST"
ditto "$DIST_BIN" "$DEST_BIN"
chmod 755 "$DEST_BIN"

# Helper explizit signieren, bevor Xcode danach die äußere .app signiert.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
    [[ -n "$SIGN_ID" ]] || SIGN_ID="-"

    CODE_SIGN_ARGS=(
        --force
        --sign "$SIGN_ID"
        --timestamp=none
    )

    if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]]; then
        CODE_SIGN_ARGS+=(--options runtime)
    fi

    log "signiere Nested Helper (${SIGN_ID:0:20})"
    /usr/bin/codesign "${CODE_SIGN_ARGS[@]}" "$DEST_BIN"

    # Sofort hier scheitern, nicht erst 40 Buildschritte später beim Parent-App-Sign.
    /usr/bin/codesign --verify --strict --verbose=2 "$DEST_BIN"
fi

# Alte v7-onedir-Strukturen dürfen niemals neben dem neuen onefile liegen.
if [[ -e "$DEST/_internal" || -e "$DEST/base_library.zip" ]]; then
    die "Unerwartete alte PyInstaller-onedir-Dateien in $DEST"
fi

# Eindeutige Altlasten aus Contents/Resources entfernen.
RES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-${CONTENTS_FOLDER_PATH}/Resources}"
rm -f \
  "$RES/web_admin.py" \
  "$RES/build-helper.sh" \
  "$RES/xcode-build-phase.sh" \
  "$RES/xcode-build-and-embed-helper.sh" \
  "$RES/xcode-copy-helper.sh" \
  "$RES/embed-into-app.sh" \
  "$RES/verify-bundle.sh" \
  "$RES/BACKEND_INTEGRATION.md" \
  "$RES/XCODE_BUILD_PHASE.md" \
  "$RES/XCODE_INTEGRATION.md" \
  2>/dev/null || true

log "eingebettet -> $DEST_BIN"
if command -v lipo >/dev/null 2>&1; then
    ARCH_OUT="$(lipo -archs "$DEST_BIN" 2>/dev/null || true)"
    [[ -n "$ARCH_OUT" ]] && log "Binary arch -> $ARCH_OUT"
fi
