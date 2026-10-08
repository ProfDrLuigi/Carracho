# Carracho 1.1.8

Carracho **Client 1.1.8 (build 19)** is a focused private-message reliability and identity-safety update. It prevents stored conversations from being attached to a different user when Classic or older Carracho servers reuse a numeric user ID. **Carracho Server remains 1.1.6 (build 17)**. No protocol changes or Server update are required.

## Highlights

- Fixed the Message Center issue where a message from one user could appear in another user's private conversation after numeric session IDs were reused.
- Each new Classic/Legacy private conversation now has a unique storage identity independent of transient server-assigned user IDs.
- Older private-message histories without a verifiable account UUID remain available as read-only **Unverified legacy history** archives, rather than being assigned to whoever currently has the same user ID.
- Removed stale live user routing when a person disconnects, reconnects or their account identity changes, including in background bookmarks.
- Incoming messages with an unknown current sender are rejected instead of being assigned to a possibly unrelated conversation.
- Preserved separation between server bookmarks and local account scopes when saving, reading, editing and deleting conversation history.
- Added English and German localization for the **Unverified legacy history** label.
- Added regression coverage for two different users sharing the same recycled numeric ID, including independent history deletion.
- Added an interactive search and category filter to **Administration → Server Log**; narrow log entries by IP, username, text, errors, warnings, connections or authentication activity without modifying the source log.
- Updated the macOS Client to **1.1.8 / build 19**; the Server stays on **1.1.6 / build 17**.

## Carracho Client 1.1.8

### Filter server log by text and activity category

Under **Administration → Server Log**, administrators can now filter the displayed log with a live search field and category menu: **All Log Entries**, **Errors**, **Warnings**, **Connections** or **Authentication**. Search matches IP addresses, nicknames and other message text without case or accent sensitivity. Multiple search terms match lines containing all terms, and the view displays the number of visible lines out of the total.

Category filtering uses common log keywords, since older and Classic server logs do not consistently provide structured severity fields. Filters remain active when refreshing the log and while local log entries arrive. Filtering changes only the displayed lines: the complete unfiltered log remains available, and **Save Log** continues to export it in full so diagnostic information is not lost. The filter controls and counters are localized in English and German. No Server change is necessary.

### Correct private-message sender attribution

Fixed a Message Center issue where a message sent by one person could appear inside a different person's private conversation. On Classic and older Carracho servers, the numeric user ID identifies a live connection, not a permanent account. Reusing that ID after a disconnect could previously cause stored history to be displayed or merged under the wrong nickname.

The client no longer treats a numeric ID by itself as proof that two conversations belong to the same user. Where available, stable account UUIDs continue to identify modern conversations.

### Unique storage identity for each Classic conversation

New private conversations without a stable account UUID now use a separate, randomly generated conversation UUID as their local history namespace. Two different people can receive the same numeric routing ID without sharing saved messages, even when the server has not restarted.

Classic private-message histories remain persistently stored in the existing local SQLite database. No destructive data migration or Server protocol change is needed.

### Preserve old messages as unverified archives

Previously saved Classic/Legacy conversations keyed by numeric routing IDs are kept intact and shown as detached, read-only archives. They are visibly marked **Unverified legacy history** to distinguish them from verified, currently addressable peers. These archives are not automatically attached to the current owner of a reused user ID, and they are never silently rewritten to another person's account.

Existing messages that may already have been incorrectly grouped are **not** automatically reassigned: their original sender cannot always be established from legacy storage metadata alone. Archives can still be cleared or deleted independently.

### Retire stale user IDs on logout and identity changes

When a user leaves a server, appears again or the server announces a different stable account UUID for an existing routing ID, the old conversation is detached from that live ID. The client cannot send a reply to an archived conversation using a reassigned numeric ID.

This prevents a later login or refresh of the user list from reopening somebody else's old messages as if they belonged to the newly connected user.

### Protect incoming messages with unknown sender identity

If an incoming private message refers to a numeric ID that has not yet been identified by the current server user list, the client rejects that event rather than guessing a recipient conversation. The existing private-message workflow continues normally after the sender's current identity is available.

### Consistent safety across background server bookmarks

The same identity checks now apply to active and background-connected bookmarks. New messages, edits, reactions, user arrivals and disconnects use the current bookmark's own live identities and per-conversation storage namespace. A background session cannot revive historical routing IDs when its server reconnects.

### Safe legacy history deletion and read state

Saved Classic conversations are isolated by their own conversation epochs. Clearing or deleting one archive does not remove another conversation belonging to a different person who happened to receive the same numeric user ID. Existing durable histories associated with stable account UUIDs remain unchanged.

### Localized archive label and regression tests

Added **Unverified legacy history** / **Ungeprüfter Legacy-Verlauf** to the English and German Message Center localization. A dedicated SQLite regression test stores two users under the same numeric routing ID, confirms their histories remain separate across server endpoints and verifies independent deletion.

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

- **Client:** 1.1.8 (build 19).
- **macOS and native Linux Server:** unchanged at 1.1.6 (build 17); no Server rebuild is required for this client-side fix.
- Classic/Legacy protocol packet layouts and modern login/transport negotiation are unchanged.
- Previously misattributed messages are preserved, not silently deleted or automatically reassigned.
- Modern private conversations continue using stable peer account UUIDs for durable history; older servers use conversation-scoped storage IDs for safety.
- Release documents and a successful Xcode build are not a substitute for an end-to-end test with two live users reconnecting and exchanging private messages.
- The separate Intel i7/Sequoia account-login report is still being investigated; this Client update does not claim to fix it.

Previous release: [`README_1.1.7.md`](README_1.1.7.md).
