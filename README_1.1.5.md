# Carracho 1.1.5

Carracho 1.1.5 focuses on **Message Center persistence, large Files directories, faster Finder-style preview access, and cleaner independent Client/Server versioning**. The macOS Client and Server are version **1.1.5 (build 16)** for this release, with the native Linux Server using the same Server version metadata.

## Highlights

- Fixed Private Message history disappearing after restarting the Carracho client in several identity and multi-bookmark cases introduced around the stable-account migration.
- Added a safe boot-scoped persistence fallback when a server does not provide a stable peer account UUID, covering original/Classic servers and older modern Carracho servers without allowing recycled numeric user IDs to cross a server restart.
- Private Messages, edits and reactions received on connected background bookmarks are now persisted immediately in the correct server/account scope.
- Added an optional **Confirm disconnection** client setting for manual disconnects.
- Fixed large modern directory listings by transferring them in bounded pages instead of exceeding the legacy 65,535-byte TLV value limit.
- Added Finder-style Quick View from the Files list: pressing the Space bar on a selected previewable file opens the existing preview window.
- Split Client and Server version metadata into independent configuration files while retaining a separate shared GitHub release version.
- Release changelog generation now refreshes an existing version block deterministically instead of leaving stale generated content behind.
- Updated Carracho and Carracho Server version reporting to **1.1.5 / build 16**.

## Carracho Client 1.1.5

### Private-message history survives app restarts

When a Private Message conversation receives its stable account UUID after messages have already arrived, Carracho now persists the complete promoted conversation history rather than only the conversation metadata. Messages collected before identity promotion therefore survive quitting and restarting the app.

The promotion path merges any already restored UUID-backed history with the temporary session conversation before writing it, so a late identity update no longer discards either side of the conversation.

### Boot-scoped fallback when a peer UUID is unavailable

Servers predating stable peer identity, including original/Classic servers and older modern Carracho builds, can still provide only a numeric session user ID. Carracho now persists those conversations inside a separate namespace tied to the current server boot.

The client resolves that namespace from server uptime. Restarting only Carracho restores the same history; restarting the server creates a new namespace, so a recycled numeric user ID cannot inherit another user's messages. If a stable account UUID becomes available later, the boot-scoped history is merged into the UUID-backed conversation and the temporary record is retired only after the durable UUID history has been written successfully.

### Background bookmark Message Center persistence

Private Messages received while another bookmark remains connected in the background are now applied directly to that bookmark's Message Center snapshot and persisted in that bookmark's own server/account scope. Message edits and reactions are persisted there as well.

Quitting Carracho therefore no longer loses background-server Message Center activity merely because that bookmark had not been activated again before the app exited.

### Optional disconnect confirmation

A new **Confirm disconnection** option is available under Carracho Settings → General → App Behavior. When enabled, manually disconnecting from an active server requires confirmation before the connection is closed.

Cancelling a pending automatic reconnect and internal protocol-driven disconnects remain immediate, so the confirmation is limited to the deliberate manual action it is meant to guard.

### Large directory listings

Modern Carracho connections now page directory listings that would exceed the legacy 65,535-byte size of a single TLV value. The client requests successive pages automatically and merges them before presenting the folder, so directories with thousands of files no longer fail to open when their packed listing crosses the historical wire-size limit.

The paging is transparent to the Files UI and preserves entry order, Finder labels and existing directory metadata.

### Space bar opens Quick View

When a single previewable file is selected in the Files list, pressing the Space bar now opens the same Quick View window as the toolbar button and context-menu command.

The shortcut follows the existing Quick View availability rules and does not override normal table behavior for folders, unsupported files, multiple selections or otherwise unavailable previews.

## Carracho Server 1.1.5

### Paged directory replies for modern clients

The Swift/macOS Server and native Linux Server now support modern directory-list paging. Each page stays below the legacy UInt16 TLV-value limit and includes a continuation offset when more entries remain.

Paging is requested explicitly by modern clients. Clients that do not request it continue to receive the historical single-listing response, leaving Classic packet layouts unchanged.

### Shared support for boot-scoped client history

No new durable identity is invented for old peers that cannot provide one. Instead, the client uses the existing server-uptime information to scope numeric user IDs to one server process lifetime. Current servers continue to provide stable account UUID metadata to modern clients as introduced in 1.1.4.

This keeps the 1.1.5 fallback compatible with original/older servers while preserving the 1.1.4 protection against history being rebound after a server restart.

## Release tooling

### Independent Client and Server version metadata

Client and Server versions now have separate configuration sources. Version-Client.xcconfig controls the macOS Client, while Version-Server.xcconfig controls the macOS Server, native Linux Server and Debian packages.

Release.xcconfig separately defines the shared GitHub release/tag version. Client and Server can therefore carry different product versions in future while still publishing their ZIP assets into one shared release when desired. Runtime version strings and native Linux build metadata derive from these configured versions rather than duplicated literals in Swift or C source.

### Refreshable generated changelog blocks

The release renderer now replaces an existing generated version block when rerun instead of assuming that every version is new. This keeps the rolling Client and Server changelogs synchronized with the current release notes during release preparation and republishing.

## Compatibility notes

- Classic/Legacy packet layouts remain unchanged.
- Large-directory paging requires a paging-capable modern client and server. Older servers retain their historical single-TLV directory-size limit.
- Servers without stable peer UUID metadata use the boot-scoped Message Center fallback. A real server restart intentionally starts a fresh numeric-ID history namespace.
- Current 1.1.5 servers continue to provide stable account UUID metadata to modern clients, which remains the preferred durable Message Center identity.
- Pre-1.1.4 session-ID-only Message Center rows are still not automatically imported because their original account ownership cannot be proven safely.
- Client and Server version sources are now independent even though both products are **1.1.5 / build 16** in this release.
