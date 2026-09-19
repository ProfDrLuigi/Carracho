#!/bin/bash
set -euo pipefail

# Als Xcode Run Script Build Phase verwenden. Der Helper muss vorher einmal mit
# scripts/build-helper.sh erzeugt worden sein.
ROOT="${SRCROOT}/WebAdmin"
HELPER="$ROOT/dist/carracho-web-admin-helper"
DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/CarrachoWebAdmin"

if [[ ! -x "$HELPER/carracho-web-admin-helper" ]]; then
  echo "error: WebAdmin Helper fehlt: $HELPER" >&2
  echo "error: Einmal ${ROOT}/scripts/build-helper.sh ausführen." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
ditto "$HELPER" "$DEST"

echo "Carracho WebAdmin Helper -> $DEST"
