# Carracho 1.1.6

Carracho 1.1.6 focuses on **more durable messaging, clearer unread indicators, and a redesigned macOS Server service model**. The macOS Client and Server are version **1.1.6 (build 17)** for this release, with the native Linux Server using the same Server version metadata.

## Highlights

- Message Center history for the selected bookmark is now available immediately after launching the client, even before reconnecting to the server.
- Added an optional Dock badge showing the total number of unread private messages, including unread conversations on connected background bookmarks.
- Added a News sidebar badge showing the total number of unread threaded News posts.
- Reworked the macOS Server and Tracker into independent launchd system services backed by a compact shared headless daemon binary instead of copying a second complete Server app into the daemon directory.
- Server and Tracker installation, removal, start/stop and automatic startup are now controlled exclusively from their always-visible **System Service** sections.
- The macOS Server app now detects when an installed daemon differs from the daemon embedded in the updated app and offers **Update Now** on every app launch until the service binary is refreshed.
- Hardened Linux source synchronization so native rebuilds receive the shared version/release metadata and fail before stopping the live service when required source files are missing.
- Updated Carracho and Carracho Server version reporting to **1.1.6 / build 17**.

## Carracho Client 1.1.6

### Message Center history while offline

The selected server bookmark now restores its persisted Message Center history as soon as the client starts, without requiring a successful connection first. Stable account-UUID conversations are restored directly from the bookmark's server/account scope.

For peers that still rely on the boot-scoped fallback introduced in 1.1.5, Carracho can display the most recently observed server-boot history while disconnected. A real connection still revalidates the server boot before a numeric session identity is trusted for new routing or persistence.

Switching to a saved bookmark while disconnected also loads that bookmark's locally persisted Message Center history, making previous conversations useful even when the remote server is unavailable.

### Unread private-message Dock badge

Carracho can now show the total number of unread private messages directly on its Dock icon. The count includes the active server as well as connected background bookmarks, and unread state is only cleared when the relevant conversation is actually visible in the active key window.

The feature is enabled by default and can be switched off under **Settings → General → App Behavior → Show unread private messages on the Dock icon**. Disabling it clears the Dock badge immediately.

### Unread News sidebar badge

The main **News** sidebar item now shows the total number of unread threaded News posts using the same red badge presentation as the other unread counters in the client.

The count comes from the existing per-server/per-account News read state, updates during background News polling, decreases as individual threads are actually read, and is restored correctly when switching back to a connected bookmark session. Merely opening the News workspace does not clear unread posts.

## Carracho Server 1.1.6

### Dedicated Server and Tracker system services

The macOS Server and Tracker can now run as two independent launchd system services. Both jobs use the same compact carracho-serverd helper embedded in the Server app, while Server and Tracker retain separate launchd jobs and separate running/automatic-start state.

Installing a service copies only the headless daemon binary and the service definitions required to run it. The daemon directory no longer needs a second complete copy of **Carracho Server.app**, avoiding duplicated application bundles under /Applications and the service installation.

The helper is built as a Universal 2 binary and contains the headless Server/Tracker runtime rather than the AppKit administration UI or Sparkle updater.

### System Service is the single control surface

Server and Tracker runtime control is now consolidated under the always-visible **System Service** section for each component. The old duplicate Start/Stop controls in the page header, application menu and status menu have been removed.

Each service can be installed or uninstalled independently, started or stopped independently, and configured independently for automatic startup with macOS. Current running state and startup-at-boot state are separate: disabling automatic startup does not stop a service that is already running.

The **System Service** section is permanently expanded and no longer has a disclosure arrow, so installation and runtime controls remain visible without another layer of navigation.

### Daemon update reminder after an app update

The Server app now compares the daemon helper embedded in the current app with the binary installed for the system services. The comparison is byte-for-byte, so rebuilt hotfixes are detected even if their marketing version happens to be unchanged.

When an installed daemon differs from the helper in the updated app, **Reinstall** changes to **Update Now**. On every normal launch of the Server app, a warning explains that the application was updated and the system service must also be refreshed. The warning continues to appear until the installed daemon matches the current app.

Choosing **Update Now** performs the same privileged service refresh used by the System Service controls while preserving the installed sibling service's running and automatic-start state. Because Server and Tracker share the daemon binary, updating either installed service refreshes the common executable.

## Release tooling

### Safer Linux source synchronization

The Xcode **Sync Server** target now transfers the shared scripts directory together with Version-Server.xcconfig and Release.xcconfig into /opt/carracho/sources. Native Linux builds therefore receive the version loader and metadata required by the split Client/Server version configuration.

compile.sh now validates all required synchronized source files before stopping the live service. An incomplete source upload fails immediately with a clear error instead of taking the running Carracho Server offline and only then discovering missing build metadata.

### Release packaging for the headless macOS daemon

The macOS Server release publisher now validates and signs the embedded carracho-serverd helper together with the application bundle. The packaged Server app therefore contains the exact helper used by the System Service installer and daemon-update comparison.

## Compatibility notes

- Classic/Legacy protocol packet layouts remain unchanged in 1.1.6.
- Message Center offline restoration remains scoped by server/account identity; numeric fallback history is still limited to the most recently known server-boot namespace.
- The Dock badge is a client preference and does not change server behavior or private-message persistence.
- Threaded News unread badges require the modern threaded-News query support already used by the 1.1.5 News read-state system.
- macOS Server and Tracker remain independently controllable launchd jobs even though they share one installed carracho-serverd executable.
- After updating the macOS Server app, an already installed system service should be updated from **System Service → Update Now** before relying on the new daemon code.
- Client, macOS Server and native Linux Server are all **1.1.6 / build 17** in this release.
