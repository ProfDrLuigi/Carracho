# Carracho 1.0.4

Carracho 1.0.4 is a compatibility and administration release. It adds a complete browser-based administration path for modern servers, fixes two important Classic-client interoperability problems, expands Conference moderation, improves the search index, and refreshes large parts of the modern macOS client.

## Highlights

- **Web Administration for Carracho Server** on macOS and Linux.
- Authenticated **HTTP Administration API** with Bearer-token protection.
- Live **transfer monitoring and cancellation** through the WebAdmin/API.
- Fixed the Classic download bug that could crash the original client.
- Added real historical **Classic user-icon support** end to end.
- Added Conference **Operator Mode**, **Speak Permission**, and modern room deletion controls.
- Improved persistent search-index maintenance on both server implementations.
- Refreshed the modern client theme and Conference presentation.

## Carracho Client 1.0.4

### Classic avatars

The modern client can now render the native avatar format used by the historical Carracho client.

Classic sends a 636-byte user-picture payload rather than a PNG. Carracho 1.0.4 decodes the original 16×16 QuickDraw palette image and displays it throughout the modern client.

Classic avatars are now shown in:

- Users
- Conferences
- Private Messages
- News
- Transfers
- User information

Classic artwork keeps its original square shape instead of being cropped by the modern circular avatar mask.

### Classic downloads

A Legacy download-protocol mismatch has been fixed.

The original client negotiates separate data-fork and resource-fork resume values. Carracho Server now consumes both values and returns both fork lengths before transmitting the file data. This fixes a stream desynchronization that could make the Classic client interpret file bytes as a resource-fork length and crash.

### Conferences

Conference operators can now grant or remove:

- Operator Mode
- Speak Permission

Administrators connected to a modern server can also permanently delete non-Public Conferences.

### Interface updates

The client received a broader visual refresh:

- quieter full-row selections
- improved side-column colors
- more consistent dark-mode backgrounds
- redesigned Conference transcript layout with avatars and timestamps
- improved text-selection preservation during live chat refreshes
- improved News scroll-position preservation
- denser Files rows with scalable icons

## Carracho Server 1.0.4

### Web Administration

Carracho Server now includes a bundled Web Administration interface.

The WebAdmin covers:

- server status
- connected users
- active transfers
- accounts
- Conferences
- settings
- search-index status/rebuild
- broadcasts
- activity/log information

The browser UI talks to the server through the new authenticated HTTP Administration API.

Default local endpoints are:

```text
HTTP Admin API   127.0.0.1:6780
Web Admin        127.0.0.1:6781
```

The API is protected by a Bearer token. For public access, the WebAdmin should remain on loopback and be exposed through a properly authenticated TLS reverse proxy.

### Transfer API

The administration API now exposes active transfers:

```http
GET /api/v1/transfers
POST /api/v1/transfers/{id}/cancel
```

Transfer records include progress, direction, user, path, rate, ETA, and state.

### Linux deployment

On Linux the WebAdmin is bundled as a self-contained helper. The normal `carracho-server` process starts and stops it as a child process.

There is therefore still only one systemd service:

```text
carracho.service
```

### Classic compatibility

The server now:

- handles the Classic two-fork download negotiation correctly;
- accepts native 636-byte Classic icons during login and user updates;
- persists Classic icons on the account;
- forwards Classic icon payloads unchanged to compatible Legacy clients;
- preserves the same compatibility behavior in both the macOS/Swift and Linux/C server implementations.

### Conferences and search index

- Conference Operator Mode and Speak Permission updates are supported.
- Modern administrators can delete non-Public Conferences.
- Room deletion is propagated to modern clients while preserving Classic leave/update behavior.
- The persistent search index has improved incremental upserts, trigram maintenance, subtree deletion, and path handling.

## Upgrade note

Carracho 1.0.4 remains designed to interoperate with Classic Carracho software while extending the modern protocol and administration stack. Features that rely on the new HTTP Administration API, transfer API, or modern Conference deletion require a matching 1.0.4 server.
