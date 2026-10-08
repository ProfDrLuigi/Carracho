# Carracho 1.1.7

Carracho **Client 1.1.7 (build 18)** brings improved user context menus, personal Ignore controls, bookmark organization, more reliable reconnection and accurate read status. It also consolidates the existing multi-bookmark stability improvements into this release. **Carracho Server remains 1.1.6 (build 17)**; Classic/Legacy packet layouts are unchanged.

## Highlights

- Edit a connected user's account directly from the user-list context menu as an authorized administrator, without visiting **Accounts** first.
- Use the same context menu in the conference participant list, with actions bound to the actual clicked user.
- Ignore or unignore users without administrator privileges; hide their private messages and conference messages, and suppress new-message notifications and unread counts.
- See ignored users with a strikethrough nickname in the regular and conference user lists.
- Switch immediately from a stalled/offline server bookmark to another connected server without leaving the previous server's empty workspace on screen.
- Restore the correct status and control state when selecting an existing server connection, and prevent late callbacks from one server affecting another.
- Correct the German/English localization of the new context-menu actions.
- Fixed a multi-bookmark reconnect bug that could leave one bookmark selected while its underlying client reconnected with another bookmark's host and login, causing data such as the Files view to come from the wrong server.
- Auto-reconnect state is now isolated per saved bookmark instead of sharing one global retry identity.
- Connected background bookmarks with auto-reconnect enabled now retry independently after an unexpected disconnect.
- Preserved each bookmark's last valid session snapshot across connection loss so switching bookmarks during a reconnect cannot replace one server's UI state with another server's state.
- Hardened background reconnect handling for server agreements and boot-scoped Message Center history.
- Kept the server header at a fixed height across bookmarks so the center workspace no longer jumps vertically when optional banner or server-detail rows appear or disappear.
- News threads and Message Center conversations are now marked read automatically when their content is actually opened or becomes visible again, including already-selected items that received new content while another workspace was active.
- Saved server bookmarks can now be reordered directly in the sidebar by dragging their server icon; the custom order is persisted across launches without changing bookmark identities or connection state.
- Updated the macOS Client to **1.1.7 / build 18**; Carracho Server remains **1.1.6 / build 17**.

## Carracho Client 1.1.7

## User-list and conference context menus
Both the main server user list and each conference's participant list now offer the same right-click menu. Depending on connection state and permissions, it provides **Info**, **Message**, **Ignore User / Stop Ignoring**, **Edit User Account…**, **Kick** and **Ban**. The own-user **Sleep** action remains available where applicable.

Conference actions are attached to the exact clicked user ID, rather than relying on a potentially unrelated selection in the main user list. Sorting the participant list therefore does not redirect a menu action to another user.

### Direct administrator account editing

The **Edit User Account…** action is available only to authorized administrators. It resolves the selected live user's login and opens the existing account editor, with the usual server-side permission checks. On modern servers, the client automatically requests account groups and membership if the **Accounts** page has not been opened yet. On Classic servers, the existing Classic account editor is used. The account must expose an editable login.

This fixes the error that previously appeared on the first direct edit attempt until the administrator visited **Accounts** to initialize the groups.

### Personal Ignore action

Any user can choose **Ignore User** on someone else. This is a **local display/notification preference**, not a kick or a server-side ban:

- New private messages and conference chat entries from that user are not shown or saved to the local conversation/transcript during the ignore.
- Existing private conversations are hidden rather than deleted. They become visible again after **Stop Ignoring**.
- Ignored conversations no longer contribute new-message notifications or unread badges, including when other connected bookmarks are running in the background.
- In the normal user list and the conference participant list, the ignored user's **nickname is struck through**, preserving its existing name color. Both lists refresh as soon as the setting changes.
- Users cannot ignore their own account through this action.

For modern peers with **stable account UUIDs**, an ignore is saved per server endpoint and local login, persists across application restarts and follows that account's identity. On older/Classic peers that provide only reusable numeric session IDs, the ignore applies **only to the current connection** to avoid mistakenly silencing someone else after a reconnect. If a stable identity becomes available during the session, the ignore can be promoted to that identity.

## Bookmark switching and failed connections

Switching away from an offline server while its TCP connection is still pending no longer leaves the previous bookmark's empty workspace visible. The destination bookmark becomes active immediately, including an already-established session on another server.

- The new bookmark's own session snapshot, workspace data, status label and Connect/Disconnect control are restored together.
- The shared presentation is cleared before loading a different bookmark's state, avoiding stale Files or Overview content.
- Connection callbacks are tied to the originating client. A timeout or login result that arrives later for the old bookmark cannot replace the selected server's UI.
- A connecting bookmark can continue its own connection attempt in the background. A server agreement is never accepted on the user's behalf.

This addresses the case where a failed **Zeb's** connection left an empty Files/Overview panel displayed even after selecting the already-connected **Admin** bookmark.

## Localization

The English and German `Localizable.strings` resources now correctly parse the new context-menu entries. In German, the actions are **Benutzerkonto bearbeiten…**, **Ignorieren** and **Ignorieren aufheben**. The issue was a malformed newline sequence in the resource file, not missing translations.

### Multi-bookmark reconnect isolation

Reconnect ownership is now tied to the bookmark and LegacyControlClient that actually lost its connection. A stale reconnect marker from a previously selected bookmark can no longer win over the active connection and reconnect that client using another bookmark's host, login or password.

This fixes the failure mode where the sidebar could still show one bookmark as connected while workspaces such as **Files** were actually displaying data from a different server after sleep/wake or another transient disconnect.

### Independent background auto-reconnect

Each saved bookmark now maintains its own reconnect timer and retry backoff. If several bookmarks are connected and one of the background connections drops, that bookmark can reconnect independently when **Auto-Reconnect** is enabled instead of relying on the single foreground retry state.

When a foreground reconnect is already pending and the user switches to another bookmark, the pending retry is transferred to that bookmark's background context without losing its retry state. Merely selecting a bookmark that was never connected does not cause it to start connecting in the background.

### Session snapshot safety during reconnects

An unexpected disconnect now preserves the bookmark's last valid session snapshot before the shared presentation is reset. Switching away while a reconnect is pending therefore keeps Files, News, users, channels and related per-server presentation state associated with the correct bookmark.

Once a background reconnect succeeds, server information, the root directory, channels and News groups are refreshed against that bookmark's own client before its snapshot is reused.

### Reorder saved bookmarks

Saved server bookmarks in the **Bookmarks** sidebar section can now be reordered by dragging the server icon on the left side of a bookmark row.

The new order is stored through the existing bookmark persistence layer and restored on the next launch. Reordering only changes presentation order: bookmark UUIDs, Keychain passwords, selected bookmark identity, live connection contexts, unread state and reconnect state remain attached to the same bookmark.

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

- Classic/Legacy protocol packet layouts are unchanged in Client 1.1.7.
- Account editing requires server-granted administrator/account-management rights; Ignoring users is a local feature that does not require administrator privileges.
- Auto-reconnect continues to apply only to saved bookmarks with the option enabled. Selecting a previously unconnected bookmark does not automatically start a background connection.
- Background reconnects never bypass server agreement prompts.
- Message Center conversations with stable account UUIDs remain durable across reconnects; numeric routing identities are protected by server-boot scoping.
- Modern-user Ignore settings can persist using stable account UUIDs; Classic/numeric-only ignores are limited to their current connection to avoid blocking the wrong person.
- A successful client build does not replace user-to-user integration testing, app signing, notarization or distribution verification.
- The macOS Client is **1.1.7 / build 18**. macOS Server and native Linux Server remain **1.1.6 / build 17**.
