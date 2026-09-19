# Xcode Build Phase – Carracho Server

Im Target **Carracho Server** unter **Build Phases** eine **Run Script Phase**
hinzufügen und sie vor dem fertigen Signieren/Archivieren laufen lassen.

Wenn der Ordner im Repository z.B. `CarrachoWebAdmin` heißt:

```sh
"${SRCROOT}/CarrachoWebAdmin/scripts/xcode-build-phase.sh"
```

Wenn du den gelieferten Ordnernamen unverändert lässt:

```sh
"${SRCROOT}/carracho-web-admin-bundled-python-v5/scripts/xcode-build-phase.sh"
```

Die Phase macht automatisch:

1. Architektur aus Xcodes `ARCHS` bestimmen (`arm64`, `x86_64`, `universal2`).
2. Python auf dem **Build-Mac** finden.
3. Bei geänderten WebAdmin-Quellen den PyInstaller-Helper neu bauen.
4. Unveränderte Helper-Builds überspringen.
5. Den vollständigen Helper inklusive Python-Runtime nach
   `Carracho Server.app/Contents/Helpers/CarrachoWebAdmin/` kopieren.
6. Für signierte Builds die Xcode-Code-Signing-Identity an PyInstaller reichen.

## Wichtig: User Script Sandboxing

PyInstaller liest den installierten Python-Framework-Baum und startet Unterprozesse.
Daher beim **Carracho Server** Target unter Build Settings setzen:

```text
ENABLE_USER_SCRIPT_SANDBOXING = NO
```

Sonst kann Xcode den Build trotz korrektem Script mit Sandbox-Fehlern blockieren.

## Python-Pfad fest einstellen

Für reproduzierbare Builds empfiehlt sich ein universal2 Python 3.11 und ein
User-Defined Build Setting:

```text
CARRACHO_WEBADMIN_PYTHON = /Library/Frameworks/Python.framework/Versions/3.11/bin/python3
```

Das Script findet Python auch automatisch, aber ein expliziter Pfad ist für
Archive/CI weniger magisch und damit erfahrungsgemäß weniger nervig.

## Output im App-Bundle

```text
Carracho Server.app/
└── Contents/
    └── Helpers/
        └── CarrachoWebAdmin/
            ├── carracho-web-admin-helper
            └── _internal/
                └── ... gebündelte Python-Runtime ...
```

Der Ziel-Mac braucht kein Python.
