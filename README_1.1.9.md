# Carracho 1.1.9

Carracho **Client 1.1.9 (build 20)** improves the Message Center for returning Guest users and safeguards private-message recipient selection. It also fixes Guest nicknames in chatroom departure notices. **Carracho Server remains 1.1.6 (build 17)**; no Server rebuild or protocol change is required.

## Highlights

- Fixed opening the wrong conversation when selecting a participant, including concurrently connected users sharing an anonymous/Guest account UUID.
- Consolidated repeated Guest sessions under one conversation row in Message Center. Earlier messages remain organized by session with explicit identity warnings, rather than producing one visible orphan chat per reconnect.
- Fixed the grouped Guest chat staying **Offline** after the Guest returned; a uniquely matching live Guest now updates the existing view to **Online** immediately, without requiring a new message and without reusing unverified old session identities.
- Fixed Guest and Classic chatroom departure notices displaying **Unknown User** instead of the participant's nickname when the global user-list entry disappears before the room leave event.
- Updated the macOS Client to **1.1.9 / build 20**; Carracho Server remains **1.1.6 / build 17**.

## Carracho Client 1.1.9

### Refresh Guest chat Online status on reconnect

The grouped Message Center conversation now switches from **Offline** to **Online** as soon as a returning Guest appears in the current server user list, without waiting for the first new outgoing message. If the user was viewing the previous Guest archive, the selection and reply composer automatically move to a newly created live routing session while the earlier messages remain visible as separately labeled, unverified history.

Presence is matched only when exactly **one** live user has that display nickname. Two simultaneous Guests with the same name are treated as ambiguous rather than automatically selecting a recipient. Previous conversations are never merged into the new session by nickname or shared Guest account UUID. A Guest who reconnects and leaves without exchanging a message does not produce another empty persistent chat history. This change requires only the Client.

### Preserve Guest nicknames in room leave messages

Fixed conference system messages showing **Unknown User left the room** when a Guest/Classic participant disconnects. The Client now captures the participant's display nickname when they enter a room, updates it after nickname changes, and uses that room-specific snapshot if the global online-user list is already missing the participant at departure.

If a global disconnect arrives before the room-leave event, the Client adds the departure notice using the remembered nickname while removing the room membership. A subsequent leave event cannot add a duplicate. Membership snapshots are cleared when the participant leaves, preventing recycled numeric session IDs from acquiring the wrong user's nickname. No Server rebuild or protocol update is required.

### Keep repeated Guest sessions in one Message Center row

Fixed the Guest/Legacy history clutter where each disconnect and reconnect added another separate "Unverified legacy history" chat to the inbox. Previous sessions sharing a visible Guest name now appear together under **one sidebar conversation**. Reconnecting a fourth time does not create a fourth visible orphan entry: the currently active conversation is shown, and earlier messages are available in the same view with dated, explicitly unverified session separators.

**Safety:** A Guest nickname is not an authenticated identity. Stored histories remain isolated by their original per-session IDs, and the client never automatically treats those archives as proof that a newly connected user is the same person. Two simultaneously connected users with the same nickname retain independent live chats. The displayed historical sections are clearly labeled as not identity-verified.

Unread badges, transcript search, and clearing/deleting a grouped conversation handle its underlying session histories together. No existing Guest messages are silently deleted or reassigned. The interface is localized in German and English, and the change requires no Server upgrade.

### Prevent private chats opening for the wrong selected user

Corrected a further Message Center routing issue: choosing **Message** for one online user could open another user's conversation if their concurrent sessions exposed the same account UUID, as can happen with shared or anonymous logins. The client now checks the clicked table row, the active recipient's numeric session ID and nickname, and whether any other live user advertises the same account UUID before reusing stored history.

An ambiguous or mismatching saved conversation is never silently rebound to a different person. The same identity checks apply to background server bookmarks, including late arrivals and recycled IDs. This fix is client-side and does not require the other participant to upgrade. Previously mixed historic messages cannot be safely reassigned automatically.

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

- **macOS Client:** 1.1.9 (build 20).
- **macOS and native Linux Server:** unchanged at 1.1.6 (build 17).
- User-to-user private-message protocol, account authentication and Classic packet layouts are unchanged.
- Historical Guest sessions are grouped **for display only**. Their stored identities and routing leases remain separate, with unverified session boundaries visibly indicated.
- A Guest returning with a unique matching nickname can appear Online immediately. Concurrent identical Guest nicknames remain ambiguous; the Client must not arbitrarily choose a recipient.
- No previously misattributed historical messages are automatically rewritten or reassigned.
- Interactive testing of Guest disconnect/reconnect, simultaneous Guest nicknames and chatroom presence events is still recommended before public distribution.

Previous release notes: [`README_1.1.8.md`](README_1.1.8.md).
