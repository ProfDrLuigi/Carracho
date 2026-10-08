# Carracho 1.1.9

Carracho **Client 1.1.9 (build 20)** improves the Message Center for returning Guest users and safeguards private-message recipient selection. It also fixes Guest nicknames in chatroom departure notices. **Carracho Server 1.1.7 (build 18)** fixes a critical database-safety bug: changing the administrator password in the macOS Server GUI could erase accounts created by the running daemon. Both the macOS Server app and its installed system-service daemon must be updated; no wire-protocol change is required.

## Highlights

- Fixed opening the wrong conversation when selecting a participant, including concurrently connected users sharing an anonymous/Guest account UUID.
- Consolidated repeated Guest sessions under one conversation row in Message Center. Earlier messages remain organized by session with explicit identity warnings, rather than producing one visible orphan chat per reconnect.
- Fixed the grouped Guest chat staying **Offline** after the Guest returned; a uniquely matching live Guest now updates the existing view to **Online** immediately, without requiring a new message and without reusing unverified old session identities.
- Fixed Guest and Classic chatroom departure notices displaying **Unknown User** instead of the participant's nickname when the global user-list entry disappears before the room leave event.
- Updated the macOS Client to **1.1.9 / build 20** and the Server to **1.1.7 / build 18**.
- **Critical Server fix:** Changing the administrator password in the macOS Server GUI no longer silently erases accounts created or edited by the running system-service daemon.
- Server-state changes now reload the latest SQLite data inside a cross-process write transaction instead of persisting stale GUI/daemon snapshots.
- A partially initialized existing server database now causes an explicit error, rather than being silently replaced with a fresh default-account database.
- Added isolation tests for account and newsgroup survival, credential verification, transaction rollback, and incomplete database protection.

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

## Carracho Server 1.1.7

### Critical: prevent account loss when changing the administrator password

Fixed a data-loss defect in the macOS Server administration GUI. When the Server GUI and the background `carracho-serverd` service had independently loaded the same `server.db`, the GUI could retain an outdated account snapshot. Changing the administrator password then saved that stale *entire* server state, replacing the current accounts table and removing accounts created or changed by the daemon since the GUI opened. The updated code applies the password change against the latest database state, preserving all other accounts, credentials, newsgroups and server settings.

### Atomic cross-process SQLite state updates

Every Server state mutation now acquires SQLite's `BEGIN IMMEDIATE` writer lock **before reading the current persisted state**, applies the change to that latest state and commits it atomically. This prevents the independently running Server GUI and system-service daemon from overwriting one another's newer data. An error rolls back the whole transaction. The old API for blindly saving an out-of-date full-state snapshot has been removed.

### Administrator password changes update credentials only

The Server app now uses the backend's dedicated password-change operation rather than submitting its cached administrator account as an entire replacement record. Existing admin metadata, group assignments, profile settings and changes made through a second process remain intact. The normal new-password validation and authentication verifier storage are unchanged.

### Refuse silent database reinitialization on existing installations

An existing `server.db` without a valid persisted Server state is now treated as an error rather than silently replaced with fresh default accounts. First-run initialization is serialized inside the same SQLite write lock so two simultaneous process starts cannot independently bootstrap the database. Fresh installations still initialize normally. This protection **does not recover** accounts already lost to an earlier overwritten state; restore those from a database backup if available.

### Regression coverage for GUI and daemon account safety

Added a standalone SQLite regression test using two separate backend instances pointing to one disposable test database. It confirms that an administrator password change from a stale GUI snapshot preserves accounts created by the other process, including their logins, UUIDs and usable passwords. Tests also check preserved newsgroups and server settings, reverse-direction stale-state changes, rollback after a deliberate failure and safe handling of an incomplete existing database.

### Update the macOS system-service daemon as well as the GUI

The fix changes shared persistence code used by **both** the macOS Server app and its embedded `carracho-serverd` helper. After installing the new app, use **System Service → Update Now** to replace any previously installed system-service helper. Installing only the GUI while leaving an older daemon running does not fully protect the Server database. No SQLite schema migration or Classic/modern packet-format change is required. The shared Server version metadata is also raised to 1.1.7 (build 18) for native Linux build/package reporting, but the reported stale-snapshot bug concerns the macOS Server GUI and daemon.

## Compatibility notes

- **macOS Client:** 1.1.9 (build 20).
- **macOS Server app and Server/Tracker daemon:** 1.1.7 (build 18). Update the installed daemon helper after updating the app.
- **Native Linux Server:** version/build metadata is 1.1.7 (build 18); the fixed GUI/daemon stale-snapshot failure is specific to macOS. No new protocol capabilities were introduced.
- **Server database:** existing schema and accounts are retained without a destructive migration. Before upgrading, back up the complete `db` directory, including `server.db`, `server.db-wal` and `server.db-shm` if present.
- **Recovery:** this fix prevents future overwrites; it cannot reconstruct accounts already removed by the old version.
- User-to-user private-message protocol, account authentication and Classic packet layouts are unchanged.
- Historical Guest sessions are grouped **for display only**. Their stored identities and routing leases remain separate, with unverified session boundaries visibly indicated.
- A Guest returning with a unique matching nickname can appear Online immediately. Concurrent identical Guest nicknames remain ambiguous; the Client must not arbitrarily choose a recipient.
- No previously misattributed historical messages are automatically rewritten or reassigned.
- Interactive testing of Guest disconnect/reconnect, simultaneous Guest nicknames and chatroom presence events is still recommended before public distribution.

Previous release notes: [`README_1.1.8.md`](README_1.1.8.md).
