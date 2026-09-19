# Xcode Buildphase – korrigierte Integration

## Warum die alte Variante kaputtging

`Webinterface` war im Target als Resource enthalten. Dadurch behandelte Xcode
nicht nur `index.html` und `web_admin.py`, sondern auch den erzeugten
`.xcode-build/venv` als Bundle-Ressource. Das führt zu hunderten
`duplicate output file`-Warnungen und kopiert Build-Werkzeuge nach
`Contents/Resources`.

Der Build-Cache liegt deshalb ab v6 ausschließlich in DerivedData.

## 1. Webinterface NICHT als Bundle Resource eintragen

Im Target **Carracho Server**:

1. `Build Phases`
2. `Copy Bundle Resources`
3. Alles entfernen, was aus `Webinterface` stammt.
4. Falls `Webinterface` als blaues Folder-Reference oder synchronisierte Gruppe
   Target Membership besitzt: Target Membership für **Carracho Server**
   deaktivieren.

Der Ordner bleibt ganz normal im Repository. Xcode muss ihn nicht als Resource
kopieren. Die Run-Script-Phase liest ihn direkt aus dem Source Tree.

## 2. Buildphase

Target **Carracho Server** → `Build Phases` → `+` → `New Run Script Phase`

Name:

    Build & Embed Carracho Web Admin

Script:

    "${SRCROOT}/Carracho/Webinterface/scripts/xcode-build-phase.sh"

Wenn dein `Webinterface` direkt neben der `.xcodeproj` liegt:

    "${SRCROOT}/Webinterface/scripts/xcode-build-phase.sh"

Die Phase nach **Copy Bundle Resources** platzieren.

`Based on dependency analysis` darf AUS sein. Das Script besitzt selbst einen
Source-Hash und startet PyInstaller nur bei Änderungen.

## 3. Script Sandbox

Build Settings:

    ENABLE_USER_SCRIPT_SANDBOXING = NO

## 4. Build-Python

Optional, aber empfohlen:

    CARRACHO_WEBADMIN_PYTHON =
    /Library/Frameworks/Python.framework/Versions/3.11/bin/python3

Python ist nur auf dem Build-Rechner erforderlich.

## 5. Erwartetes Ergebnis

Nach erfolgreichem Build:

    Carracho Server.app/
      Contents/
        MacOS/
        Resources/
        Helpers/
          CarrachoWebAdmin/
            carracho-web-admin-helper
            _internal/
              ...

NICHT korrekt ist:

    Contents/Resources/site-packages/
    Contents/Resources/web_admin.py
    Contents/Resources/xcode-build-phase.sh

## 6. Prüfen

    APP="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
    test -x "$APP/Contents/Helpers/CarrachoWebAdmin/carracho-web-admin-helper"

oder außerhalb Xcodes:

    find "/Pfad/zu/Carracho Server.app/Contents/Helpers/CarrachoWebAdmin" -maxdepth 2 -type f | head

## 7. Sparkle

Wenn Xcode bereits vor der Run-Script-Phase mit

    There is no XCFramework found at ... Sparkle.xcframework

abbricht, zuerst in Xcode:

    File → Packages → Reset Package Caches
    File → Packages → Resolve Package Versions

Falls das nicht reicht, DerivedData für das Carracho-Projekt löschen und das
Package erneut auflösen. Dieser Fehler ist unabhängig vom WebAdmin.
