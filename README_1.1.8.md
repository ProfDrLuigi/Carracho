# Carracho 1.1.8

Carracho 1.1.8 is a focused **macOS Client reliability release** for bookmark reconnection after sleep/wake and transient connection loss. The Client advances to **1.1.8 (build 19)**, while Carracho Server remains at **1.1.6 (build 17)** because this release contains no Server changes.

## Highlights

- Fixed a multi-bookmark reconnect bug that could leave one bookmark selected while its underlying client reconnected with another bookmark's host and login, causing data such as the Files view to come from the wrong server.
- Auto-reconnect state is now isolated per saved bookmark instead of sharing one global retry identity.
- Connected background bookmarks with auto-reconnect enabled now retry independently after an unexpected disconnect.
- Preserved each bookmark's last valid session snapshot across connection loss so switching bookmarks during a reconnect cannot replace one server's UI state with another server's state.
- Hardened background reconnect handling for server agreements and boot-scoped Message Center history.
- Kept the server header at a fixed height across bookmarks so the center workspace no longer jumps vertically when optional banner or server-detail rows appear or disappear.
- News threads and Message Center conversations are now marked read automatically when their content is actually opened or becomes visible again, including already-selected items that received new content while another workspace was active.
- Updated the macOS Client to **1.1.8 / build 19**; Carracho Server remains **1.1.6 / build 17**.

## Carracho Client 1.1.8

### Multi-bookmark reconnect isolation

Reconnect ownership is now tied to the bookmark and LegacyControlClient that actually lost its connection. A stale reconnect marker from a previously selected bookmark can no longer win over the active connection and reconnect that client using another bookmark's host, login or password.

This fixes the failure mode where the sidebar could still show one bookmark as connected while workspaces such as **Files** were actually displaying data from a different server after sleep/wake or another transient disconnect.

### Independent background auto-reconnect

Each saved bookmark now maintains its own reconnect timer and retry backoff. If several bookmarks are connected and one of the background connections drops, that bookmark can reconnect independently when **Auto-Reconnect** is enabled instead of relying on the single foreground retry state.

When a foreground reconnect is already pending and the user switches to another bookmark, the pending retry is transferred to that bookmark's background context without losing its retry state. Merely selecting a bookmark that was never connected does not cause it to start connecting in the background.

### Session snapshot safety during reconnects

An unexpected disconnect now preserves the bookmark's last valid session snapshot before the shared presentation is reset. Switching away while a reconnect is pending therefore keeps Files, News, users, channels and related per-server presentation state associated with the correct bookmark.

Once a background reconnect succeeds, server information, the root directory, channels and News groups are refreshed against that bookmark's own client before its snapshot is reused.

### Automatic read state when content is opened

News and Message Center now treat actually viewing content as the read action, including the awkward case where the same thread or conversation was already selected before new content arrived.

Returning to **News** with an already-selected thread refreshes that thread when new replies are waiting, then marks the visible posts read. Re-clicking the selected topic does the same instead of relying on AppKit to emit a new selection-change notification.

Returning to **Message Center** clears unread state for the already-selected conversation or Offline Messages once the content is visible in the active key window. Re-clicking an already-selected unread conversation also marks it read immediately. Persisted Message Center state, the sidebar badge and the optional Dock badge are updated together.

### Stable server header height

The server header now keeps a fixed 72-point height regardless of whether a server provides a banner, description or Legacy-mode status line. Switching between bookmarks therefore keeps the top edge of the center workspace in the same position instead of moving Files, Overview and the other workspaces up or down as optional header content changes.

### Safe background reconnect bootstrap

Server agreements are never accepted automatically during a hidden background reconnect. If a reconnect requires an agreement, the connection is deferred until that bookmark is brought to the foreground so the user can make the decision explicitly.

Message Center handling also revalidates the server boot namespace after a background reconnect. Stable account-UUID conversations can survive the reconnect, while numeric routing-ID history is only restored or persisted again after the current server boot has been confirmed from server uptime.

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

## Compatibility notes

- Classic/Legacy protocol packet layouts are unchanged in Client 1.1.8.
- This release changes Client bookmark/reconnect state management only; Carracho Server remains **1.1.6 / build 17**.
- Auto-reconnect continues to apply to saved bookmarks that have the option enabled; merely selecting an unconnected bookmark does not implicitly start a background connection.
- Background reconnects do not bypass server agreement prompts.
- Message Center conversations with stable account UUIDs remain durable across reconnects; numeric session identities remain protected by the server-boot namespace.
- The macOS Client is **1.1.8 / build 19**. macOS Server and native Linux Server remain **1.1.6 / build 17**.
