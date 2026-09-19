# Carracho Web Admin – Python Inside the macOS App Bundle

This variant implements exactly the intended deployment model:

```text
Carracho Server.app
      │
      ├── regular Carracho Server
      │
      └── Contents/Helpers/CarrachoWebAdmin/
               │
               ├── embedded Python interpreter
               ├── Python web server/proxy
               └── Web GUI
```

The macOS server starts the helper itself via `Process`. The target machine does
**not need Python installed**.

## Included

- Python web server/proxy from the previous WebAdmin version
- complete v3 Web GUI with transfer monitor, user kick, live log, and SSE
- PyInstaller build as `onedir`, avoiding runtime extraction on every launch
- Universal2 build (`x86_64` + `arm64`) when using a universal2 Python
- Deployment Target 10.15 for Intel; Apple Silicon from macOS 11 onward
- Swift service for automatically starting/stopping the helper from `Carracho Server.app`
- Xcode copy script for `Contents/Helpers/CarrachoWebAdmin`
- `/healthz` readiness endpoint
- bearer token only in the helper process environment, never in the browser or argv

## Quick Start

On the build Mac:

```sh
./scripts/build-helper.sh
```

The self-contained helper is then available under:

```text
dist/carracho-web-admin-helper/
```

For a manual embedding test:

```sh
./scripts/embed-into-app.sh '/path/to/Carracho Server.app'
```

For the actual Xcode integration, see:

```text
docs/XCODE_INTEGRATION.md
```

## Runtime

The parent process provides:

```text
CARRACHO_HTTP_ADMIN_TOKEN
CARRACHO_HTTP_ADMIN_URL=http://127.0.0.1:6780/api/v1
CARRACHO_WEB_ADMIN_BIND=127.0.0.1
CARRACHO_WEB_ADMIN_PORT=6781
```

The interface is then available at:

```text
http://127.0.0.1:6781/
```

## Build Dependency vs. Runtime Dependency

Building the embedded helper requires Python + PyInstaller once on the build Mac.
PyInstaller bundles the interpreter and required standard library into the helper.
The target server Mac therefore has no Python runtime dependency.

This intentionally does not use `--onefile`: `onedir` starts faster, does not
write into temporary directories at launch, and fits better into a signed macOS
app bundle.

## Fully Automated Xcode Build Phase

New in v5: the helper no longer has to be built manually beforehand. Add a Run
Script Build Phase to the Server target:

```sh
"${SRCROOT}/carracho-web-admin-bundled-python-v5/scripts/xcode-build-phase.sh"
```

The script rebuilds automatically when inputs change and copies the helper into
the finished `.app` bundle. Details: `docs/XCODE_BUILD_PHASE.md`.

## v6 Xcode Fix

The Xcode build phase builds exclusively inside DerivedData. `Webinterface` must
not be included in `Copy Bundle Resources` or as a target resource. Details:
`docs/XCODE_BUILD_PHASE_V6.md`.

## v7 Resource Cleanup

`Webinterface` must not have Target Membership. Run
`scripts/cleanup-old-build-artifacts.sh` once and follow
`docs/COPY_BUNDLE_RESOURCES_CLEANUP.md`. Temporary build artifacts are now also
excluded via `.gitignore`.

## v8 Code Signing

The helper is now built with PyInstaller `--onefile` and explicitly signed before
the final Xcode app signing step. This leaves only a single executable nested-code
object under `Contents/Helpers/CarrachoWebAdmin`. Details:
`docs/CODESIGN_ONEFILE_V8.md`.
