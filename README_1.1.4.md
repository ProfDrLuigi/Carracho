# Carracho 1.1.4

Carracho 1.1.4 focuses on **keeping Message Center private conversations tied to the correct account across reconnects and server restarts**. The macOS client and server are version **1.1.4 (build 15)**, and the stable peer-identity extension is implemented by both the Swift/macOS and native Linux servers.

## Highlights

- Fixed a Message Center history bug where a recycled transient server user ID could make an older private conversation appear under a different user after a server restart.
- Private Message history is now keyed by the server account's stable UUID instead of the temporary numeric session user ID.
- The Swift/macOS and native Linux servers now send stable account identity metadata to modern clients while leaving Classic packet layouts unchanged.
- Added a new v2 local Message Center history schema that keeps durable conversations separated by stable account identity.
- Older session-ID-based private-message history is deliberately not imported automatically because its ownership cannot be proven safely after IDs have been recycled.
- Added an optional **Confirm disconnection** client setting that asks before a manual disconnect from an active server.
- Improved Sparkle republishing so metadata for an existing build is regenerated from the replacement Universal 2 archive instead of retaining stale hardware requirements.
- Updated Carracho and Carracho Server version reporting to **1.1.4 / build 15**.

## Carracho Client 1.1.4

### Stable Message Center conversation identity

Private conversations in Message Center no longer use the server's transient numeric `userID` as their durable identity. Modern servers now provide the authenticated account UUID for each visible user, and Carracho stores and selects conversations by that stable account identity while keeping the numeric user ID only as the current live routing address.

This fixes the case where a server restart reused a numeric user ID for a different account. Previously, the stored conversation for that number could be relabelled with the new user's nickname and avatar, making messages from one account appear inside another account's conversation. In 1.1.4, a conversation can only reconnect to the exact same account UUID.

The live mapping is also hardened against incomplete disconnects: a durable conversation with an account UUID can never be rebound merely because a later session happens to reuse the same numeric user ID.

### Safer local private-message history

Message Center now stores durable Private Message conversations in a v2 SQLite schema keyed by stable peer account UUID. Older session-ID-based private-message history is deliberately **not** imported automatically because its account ownership cannot be proven safely after IDs have been recycled; those old rows are left untouched in the local database but ignored by the new history. Message edits, reactions, drafts, unread state, avatars, transport metadata and the existing 500-message per-conversation limit continue to use the same Message Center behavior.

Offline Messages use their separate account-aware storage and are not affected by this private-conversation history change.

### Safe fallback for older servers

If a server does not provide a stable account UUID, Carracho still allows Private Messages during the current connection, but that conversation remains session-only instead of being persisted under an identity that cannot be trusted across reconnects.

This keeps communication compatible with older servers without recreating the history-mixing bug.

### Optional disconnect confirmation

A new **Confirm disconnection** option is available under Carracho Settings → General → App Behavior. When enabled, manually disconnecting from an active server requires confirmation before the connection is closed. Cancelling a pending automatic reconnect and internal protocol-driven disconnects remain immediate and do not show the confirmation dialog.

## Carracho Server 1.1.4

### Stable account identity for modern peer metadata

Both the Swift/macOS server and the native Linux server now include the authenticated account UUID in modern user-arrival and user-update metadata. The stable identifier is sent in initial user snapshots, new-user events and later user metadata refreshes so modern clients can distinguish account identity from the temporary numeric session user ID. Modern observers also receive the stable account identity for Classic peers, while Classic recipients continue to receive the historical packet layouts unchanged.

This identity metadata does not change Private Message routing or grant access to another user's messages. Messages are still routed to the current live session; the UUID is used by modern clients to associate local history with the correct authenticated account.

## Release tooling

### Independent product version metadata

Carracho now keeps Client and Server versions in separate configuration files. `Version-Client.xcconfig` controls the macOS Client, while `Version-Server.xcconfig` controls the macOS Server, native Linux Server and Debian packages. `Release.xcconfig` separately identifies the shared GitHub release/tag, so Client and Server can carry different product versions while their ZIP assets still appear together in one release. Swift runtime version strings continue to come from the generated bundle metadata, so version literals are no longer duplicated in Swift or C source files.

### Safer Sparkle appcast republishing

Republishing an existing build number now removes the old item from the copied appcast before Sparkle regenerates the feed entry. This forces Sparkle to infer system and hardware metadata from the replacement archive instead of carrying forward stale metadata from an earlier artifact.

The publishing scripts also verify that a Universal 2 release does not retain an `arm64`-only hardware requirement before accepting the generated appcast.

## Compatibility notes

- The new stable account-identity field is sent only to modern clients; Classic/Legacy packet layouts are unchanged.
- The 1.1.4 macOS and native Linux servers both provide stable peer account identities to modern clients.
- Against older servers that do not provide a stable account UUID, Private Message conversations remain usable for the current session but are not persisted as durable history.
- Pre-1.1.4 private Message Center history keyed by transient session user IDs is not automatically imported into the v2 history because its account ownership cannot be verified safely. Existing old rows are left untouched on disk.
- Offline Messages are unaffected by the private-conversation storage migration.
