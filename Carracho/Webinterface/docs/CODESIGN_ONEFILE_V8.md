# v8 – CodeSign Fix: PyInstaller als ONEFILE

## Der konkrete Fehler

Xcode meldete:

    code object is not signed at all
    In subcomponent:
    Contents/Helpers/CarrachoWebAdmin/_internal/base_library.zip

Der Fehler entsteht durch die alte `--onedir`-Struktur unter
`Contents/Helpers`. `Contents/Helpers` ist ein spezieller macOS-Ort für
verschachtelten ausführbaren Code. Dort lag aber ein kompletter
PyInstaller-Dateibaum mit `_internal`, ZIP-Dateien, Python-Libraries usw.

Das ist für die äußere App-Signatur eine ausgesprochen schlechte Mischung.

## v8

PyInstaller baut jetzt:

    --onefile

Dadurch enthält:

    Contents/Helpers/CarrachoWebAdmin/

nur noch:

    carracho-web-admin-helper

Python, Standardbibliothek und `web/index.html` stecken im ONEFILE-Archiv des
Executables und werden von PyInstaller beim Start in sein temporäres
Runtime-Verzeichnis extrahiert.

`web_admin.py` unterstützt das bereits über `sys._MEIPASS`.

## Signing

Die Xcode-Buildphase signiert den Helper **vor** Xcodes finalem `CodeSign`
der äußeren `Carracho Server.app`.

Debug / Sign to Run Locally:

    codesign --force --sign - ...

Release / Archive:

    EXPANDED_CODE_SIGN_IDENTITY

Bei aktivierter Hardened Runtime erhält auch der Helper `--options runtime`.

## Erwartetes Bundle

    Carracho Server.app/
      Contents/
        Helpers/
          CarrachoWebAdmin/
            carracho-web-admin-helper

Es darf dort KEIN `_internal` und keine `base_library.zip` mehr geben.

## Nach Update auf v8

Einmal:

    Product -> Clean Build Folder

Falls du den alten Debug-Build manuell betrachten willst, lösch ihn vorher
oder lass Xcode einen vollständigen Clean durchführen.

Danach neu bauen.

## Prüfen

    ./scripts/verify-bundle.sh \
      "/Pfad/zu/Carracho Server.app"

Das Script prüft:

- genau ein ONEFILE-Helper im Helper-Verzeichnis
- Helper-Signatur
- Architektur
- komplette Parent-App-Signatur
