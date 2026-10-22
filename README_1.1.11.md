# Carracho 1.1.11

Carracho **Client 1.1.11 (build 22)** fixes user icons disappearing after an automatic reconnect. Activating a bookmark that reconnected in the background now preserves the latest user pictures, online users and status messages. Missing pictures can also be recovered through user information requests. This is a Client update; **Server 1.1.8 (build 19)** remains the current Server version.

## Highlights

- User icons remain visible when activating a bookmark after a background reconnect.
- The latest user list, presence and status messages survive reconnect setup.
- User information refreshes recover missing avatars without requiring a manual disconnect and reconnect.
- Delayed replies cannot overwrite newer user pictures or update another server's visible user list.
- Updated the Client to **1.1.11 / build 22**. The Server remains **1.1.8 / build 19**.

## Carracho Client 1.1.11

### Preserve user icons after automatic reconnect

Fixed user icons occasionally reverting to the default icon after an automatic reconnect. When activating a bookmark that had reconnected in the background, the Client could replace the updated user list with the initial login list, which intentionally contains no avatars on modern connections. Reconnect setup now preserves the pictures and user updates already received from the Server, including users who arrived after login, presence and status messages.

If a background login finishes while its bookmark is being activated, the new session snapshot is installed before live updates are processed. This avoids restoring an older connection's user list during the transition. Regression checks cover the background reconnect and subsequent foreground setup with a local test Server.

### Recover missing avatars and guard delayed replies

User information refreshes now restore the user's picture as well as their status message and group color. Responses are checked against the originating connection, authenticated session and requested user record before being applied. A delayed reply therefore cannot overwrite a newer picture update or repaint another Server's user list after a bookmark switch.

If the originating bookmark was moved to the background while the request was in flight, its recovered picture is saved in that bookmark's session snapshot. No manual disconnect and reconnect is needed to recover an avatar through the user information refresh. Connection tests verify picture recovery, preservation of newer updates and isolation between bookmark views.

## Carracho Server 1.1.8

### Send exact 64-bit sizes to modern clients

The macOS Server and native Linux Server now send exact file sizes in modern-only metadata for directory listings and file information replies. Previously, both Server implementations clamped these values to the historical 32-bit maximum of 4,294,967,295 bytes even for modern connections. Large-file sizes are now retained before encoding, and each directory page carries one 64-bit value for each entry.

The Classic packed records remain unchanged and retain their historical 32-bit size field. Extra size metadata is sent only to modern connections. This also works when Legacy compatibility is enabled on the Server; enabling compatibility does not limit modern peers to Classic file sizes.

### Preserve full sizes in filesystem and indexed searches

Modern file searches can opt into 64-bit result records. Both Server implementations retain full sizes during filesystem searches and resolve saturated 32-bit sizes from existing search indexes against the current file metadata. Existing indexes therefore support the correction without a database schema migration or a mandatory index rebuild.

The extended search format is sent only after a modern Client requests it. Classic clients and earlier modern clients continue to receive the original record format. Regression checks cover the 4 GiB boundary, larger sizes, pagination, malformed metadata, folder item counts, filesystem searches, indexed searches and complete modern/Legacy Client connections to both Server implementations.

## Compatibility notes

- **Client:** 1.1.11 (build 22).
- **Server:** 1.1.8 (build 19), unchanged. The Server section above documents the current Server release.
- The reconnect avatar correction requires only the updated Client. No Server update, database migration or index rebuild is needed for this correction.
- The 64-bit file-size improvements from Client 1.1.10 remain included; exact large-file sizes still require Server 1.1.8 or later and a modern connection.
- Modern and explicit Classic/Legacy connections remain supported. No wire-protocol changes were introduced in Client 1.1.11.

Previous release notes: [`README_1.1.10.md`](README_1.1.10.md).
