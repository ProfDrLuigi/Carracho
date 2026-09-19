#!/bin/bash
set -euo pipefail

# Einmaliger Cleanup für alte Webinterface-Buildartefakte im Source Tree.
# Das repariert NICHT automatisch project.pbxproj. Der Webinterface-Ordner muss
# im Xcode-Target aus "Copy Bundle Resources" / Target Membership raus.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "WebAdmin cleanup: $ROOT"

for d in \
  "$ROOT/.xcode-build" \
  "$ROOT/build" \
  "$ROOT/dist" \
  "$ROOT/__pycache__" \
  "$ROOT/helper/__pycache__"
do
  if [[ -e "$d" ]]; then
    echo "entferne: $d"
    rm -rf "$d"
  fi
done

find "$ROOT" -name '.DS_Store' -delete 2>/dev/null || true

cat <<'EOF'

Source-Tree ist bereinigt.

Jetzt in Xcode:
  Carracho Server -> Build Phases -> Copy Bundle Resources

Dort darf NICHTS aus Webinterface enthalten sein.

Am saubersten:
  1. Webinterface im Project Navigator auswählen.
  2. File Inspector -> Target Membership -> "Carracho Server" AUS.
  3. Falls Xcode die bereits erzeugten Einzel-Resource-Einträge behält:
     Webinterface nur als Reference aus dem Projekt entfernen (NICHT löschen),
     danach erneut hinzufügen mit "Add to targets: NONE".
  4. Clean Build Folder.

Die einzige Einbettung erfolgt danach über:
  scripts/xcode-build-phase.sh

EOF
