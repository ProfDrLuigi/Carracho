# Copy Bundle Resources sauber halten

`Webinterface` ist **Build-Input**, aber **keine App-Ressource**.

Im fertigen Bundle sollen die WebAdmin-Dateien ausschließlich hier landen:

    Contents/Helpers/CarrachoWebAdmin/

Nicht in:

    Contents/Resources/

## Einmaliger Cleanup

Im Terminal:

    cd /Pfad/zu/Carracho/Webinterface
    ./scripts/cleanup-old-build-artifacts.sh

Danach in Xcode:

1. `Carracho Server` Target öffnen.
2. `Build Phases`.
3. `Copy Bundle Resources`.
4. Alle Einträge entfernen, die aus `Webinterface` stammen.
5. Im Project Navigator `Webinterface` auswählen.
6. Rechts im File Inspector bei **Target Membership**:
   `Carracho Server` deaktivieren.

Falls Xcode den Ordner als filesystem-synchronized group eingebunden hat und
die alten Einträge trotzdem stehen bleiben:

1. `Webinterface` im Project Navigator auswählen.
2. `Delete`.
3. **Remove Reference** wählen, auf keinen Fall `Move to Trash`.
4. Ordner erneut über `File -> Add Files to "Carracho"...` hinzufügen.
5. Bei **Add to targets**: **keinen Target-Haken setzen**.

Die Scripts bleiben trotzdem im Repository und die Buildphase erreicht sie
über `${SRCROOT}`.

## Run Script Build Phase

Im Target bleibt genau eine WebAdmin-spezifische Phase:

    Build & Embed Carracho Web Admin

mit:

    "${SRCROOT}/Carracho/Webinterface/scripts/xcode-build-phase.sh"

Diese Phase erzeugt:

    Contents/Helpers/CarrachoWebAdmin/
        carracho-web-admin-helper
        _internal/
        ...

## Danach

Einmal:

    Product -> Clean Build Folder

Dann neu bauen.

`Contents/Resources` darf danach keine dieser Dateien mehr enthalten:

    web_admin.py
    build-helper.sh
    xcode-build-phase.sh
    xcode-build-and-embed-helper.sh
    xcode-copy-helper.sh
    embed-into-app.sh
    verify-bundle.sh
    BACKEND_INTEGRATION.md
    README.md
    XCODE_*.md
    site-packages/
    PyInstaller/
    *.dist-info/

## Warum keine automatische project.pbxproj-Manipulation?

Ein Script, das blind `project.pbxproj` per Regex umschreibt, kann bei
gleichnamigen Ressourcen echte Projektdateien erwischen. Target Membership in
Xcode einmal sauber zu entfernen ist wesentlich sicherer. Danach verhindert
`.gitignore`, dass temporäre Build-Ausgaben überhaupt wieder im Source Tree
auftauchen.
