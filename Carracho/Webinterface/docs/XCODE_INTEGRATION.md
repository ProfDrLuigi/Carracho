# Integration in `Carracho Server.app`

## Ergebnis im fertigen Bundle

```text
Carracho Server.app/
└── Contents/
    ├── MacOS/
    │   └── Carracho Server
    └── Helpers/
        └── CarrachoWebAdmin/
            ├── carracho-web-admin-helper
            └── _internal/
                ├── Python
                ├── python3*.zip / stdlib ...
                └── web/index.html
```

`_internal` ist der von PyInstaller erzeugte kleine Python-Runtime-Baum. Der Ziel-Mac
braucht **kein installiertes Python**.

## 1. Helper bauen

Auf dem Build-Mac einmal:

```sh
cd WebAdmin
./scripts/build-helper.sh
```

Für ein Universal-Binary muss der zum Bauen verwendete Python-Interpreter selbst
`universal2` sein. Prüfen:

```sh
lipo -archs "$(python3 -c 'import os,sys; print(os.path.realpath(sys.executable))')"
```

Erwartet:

```text
x86_64 arm64
```

Der Build setzt `MACOSX_DEPLOYMENT_TARGET=10.15`. Auf Intel ist damit Catalina das
Ziel; der arm64-Slice läuft naturgemäß ab macOS 11.

## 2. In Xcode kopieren

Das Verzeichnis `WebAdmin` ins Server-Repository legen, zum Beispiel:

```text
Carracho/
├── Server/
└── WebAdmin/
```

Dann im Target **Carracho Server** eine `Run Script Build Phase` vor der finalen
Signatur hinzufügen:

```sh
"${SRCROOT}/WebAdmin/scripts/xcode-copy-helper.sh"
```

Damit landet der Helper bei jedem App-Build unter:

```text
Contents/Helpers/CarrachoWebAdmin/
```

Nicht erst nach dem Signieren hineinkopieren. macOS findet nachträgliches Herumfummeln
an signierten App-Bundles aus unerfindlichen Gründen nicht romantisch.

## 3. Swift-Service einbauen

`macos/CarrachoWebAdminService.swift` zum Server-Target hinzufügen.

Wenn die HTTP-Admin-API gestartet ist, auch den WebAdmin starten:

```swift
do {
    try CarrachoWebAdminService.shared.startFromEnvironment()
} catch {
    NSLog("WebAdmin konnte nicht gestartet werden: %@", error.localizedDescription)
}
```

Falls der Token bereits als String im Server vorliegt, besser direkt weiterreichen:

```swift
try CarrachoWebAdminService.shared.start(
    token: httpAdminToken,
    upstreamURL: "http://127.0.0.1:6780/api/v1"
)
```

Der Token wird als **Environment des Kindprozesses** übergeben, nicht als
Kommandozeilenargument.

Beim Beenden des Servers:

```swift
CarrachoWebAdminService.shared.stop()
```

Zum Öffnen aus einem Menüpunkt `Web Administration …`:

```swift
CarrachoWebAdminService.shared.openInBrowser()
```

Das öffnet standardmäßig:

```text
http://127.0.0.1:6781/
```

## 4. Empfohlener Lebenszyklus

1. Carracho HTTP Admin API auf `127.0.0.1:6780` starten.
2. Python-WebAdmin-Helper aus dem App-Bundle starten.
3. Optional Browser öffnen.
4. Beim Server-Shutdown den Helper terminieren.

Der Helper hat zusätzlich:

```text
GET /healthz
```

für einen lokalen Readiness-Check.

## 5. Codesigning / Notarisierung

PyInstaller signiert auf Apple Silicon gesammelte Mach-O-Dateien mindestens ad-hoc.
Für einen Release-Build kann beim Helper-Build dieselbe Developer-ID benutzt werden:

```sh
CODESIGN_IDENTITY='Developer ID Application: Example GmbH (TEAMID)' \
  ./scripts/build-helper.sh
```

Danach kopiert Xcode den bereits signierten Helper vor der finalen Signatur ins
Carracho-App-Bundle. Die eigentliche Carracho-App wird anschließend wie bisher von
Xcode signiert und notarisiert.
