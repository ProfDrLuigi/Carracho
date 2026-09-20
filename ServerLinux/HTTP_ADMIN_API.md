# Carracho HTTP Administration API

Both the native Linux server and the Swift/macOS server include the same optional JSON HTTP administration API.

## Configuration

On macOS, the dedicated **Carracho Server** app exposes the same settings under **Server → HTTP Administration API**. The disclosure contains the enable switch, bind address, TCP port, secure bearer-token field, token generator/copy actions, the effective endpoint, and Apply. Saving while the GUI-managed server is running restarts its listeners; an installed running system service is restarted as well.

The macOS app keeps `etc/carracho-server.json` at mode `0600` because the file can contain the bearer token. Existing configuration files are tightened to `0600` when the app loads them. `CARRACHO_HTTP_ADMIN_TOKEN` still takes precedence at runtime, but the GUI requires a stored token when enabling the API so a LaunchDaemon restart does not depend on a transient shell environment.

The API is disabled by default and binds to loopback by default.

~~~json
"httpAdmin": {
  "enabled": true,
  "bind": "127.0.0.1",
  "port": 6780
}
~~~

Set the bearer token with the environment variable:

~~~sh
export CARRACHO_HTTP_ADMIN_TOKEN='<a-long-random-token>'
~~~

A token property inside httpAdmin is also accepted, but the environment variable is recommended so the token does not need to be stored in the server JSON file. An enabled API requires a token of at least 24 characters.

Requests authenticate with:

~~~http
Authorization: Bearer <token>
~~~

The server keeps only a SHA-256 digest of the token in the live runtime.

The built-in listener is plain HTTP. Keep it on loopback and put a TLS reverse proxy such as Caddy or nginx in front of it when remote administration is required.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | /api/v1/status | Server, uptime, connection, transfer and search-index status |
| GET | /api/v1/users | Connected users and client metadata |
| GET | /api/v1/transfers | Active uploads/downloads with progress, rate and ETA |
| POST | /api/v1/transfers/{id}/cancel | Cancel an active transfer |
| GET | /api/v1/log?limit=200 | Most recent persistent server-log entries (1-1000, default 200) |
| GET | /api/v1/accounts | Accounts |
| POST | /api/v1/accounts | Create an account |
| PATCH | /api/v1/accounts/{login} | Modify an account |
| DELETE | /api/v1/accounts/{login} | Delete an account |
| GET | /api/v1/conferences | Conferences |
| POST | /api/v1/conferences | Create a conference |
| DELETE | /api/v1/conferences/{id} | Delete a conference; Public cannot be deleted |
| GET | /api/v1/settings | Current administration settings |
| PATCH | /api/v1/settings | Modify supported server settings |
| POST | /api/v1/broadcast | Send a server broadcast |
| GET | /api/v1/search-index/status | Search-index status |
| POST | /api/v1/search-index/rebuild | Start a full search-index rebuild |

All responses are JSON except successful DELETE requests, which return HTTP 204.

## Live Log

Read the most recent persistent server-log entries:

~~~http
GET /api/v1/log?limit=200
Authorization: Bearer <token>
~~~

The response is a JSON array ordered oldest-to-newest within the requested tail:

~~~json
[
  {
    "time": "2026-09-20T11:48:12+0200",
    "type": "log",
    "message": "Connection established from 127.0.0.1"
  }
]
~~~

limit defaults to 200 and accepts values from 1 through 1000.
The WebAdmin polls this endpoint when no Server-Sent Events stream is available.
GET /api/v1/events remains optional; it is not required for live-log operation.

## Transfers

List active transfers:

~~~http
GET /api/v1/transfers
Authorization: Bearer <token>
~~~

The response is a JSON array. Each active transfer includes:

- `id` — server-local transfer identifier
- `direction` — `download` or `upload`
- `userID`, `accountID`, `login`, `user`, `nickname`, `peerIP`
- `path` and `fileName`
- `sizeBytes`
- `transferredBytes`
- `wireBytesTransferred`
- `resumedBytes`
- `speedBytesPerSecond`
- `etaSeconds` — `-1` when no meaningful ETA is currently available
- `isDirectory`
- `status` — `active`, `paused`, or `cancelling`

Cancel an active transfer:

~~~http
POST /api/v1/transfers/42/cancel
Authorization: Bearer <token>
~~~

A successful cancellation request returns HTTP 202:

~~~json
{
  "accepted": true,
  "id": 42,
  "status": "cancelling"
}
~~~

Cancellation uses the same runtime transfer-control path as the native
administration protocol. The transfer socket is interrupted immediately and
the transfer worker then performs its normal cleanup. A transfer that no
longer exists returns HTTP 404.

## Accounts

Create:

~~~http
POST /api/v1/accounts
Content-Type: application/json

{
  "login": "member",
  "name": "Member",
  "password": "<new-account-password>"
}
~~~

If no groupID is supplied, a new account uses the Account Holder group. permissionBits, groupID, and colorRGB can be supplied when individual overrides are required.

Modify:

~~~http
PATCH /api/v1/accounts/member
Content-Type: application/json

{
  "name": "New display name"
}
~~~

Fields not present in a PATCH retain their current values. Connected sessions are refreshed after account changes.

## Conferences

~~~http
POST /api/v1/conferences
Content-Type: application/json

{
  "name": "Development",
  "permanent": true,
  "restrictedChat": false
}
~~~

An optional password field can be supplied. Names and passwords must fit the Classic Carracho limits and be representable in MacRoman.

## Settings

Supported PATCH fields are:

- serverName
- description
- maxConnections
- maxConnectionsPerIP
- maxSimultaneousFileTransfers
- maxFileTransfersPerUser
- maxFolderDownloadDepth
- searchIndexRebuildIntervalHours
- searchIndexExclusions

Changes are written through the normal server-state code and persisted back to the startup configuration.

## Request limits

The first implementation deliberately keeps HTTP simple:

- HTTP/1.x, one request per connection
- Connection: close
- maximum 64 KiB request headers
- maximum 1 MiB JSON request body
- no chunked request bodies
- no CORS headers
- no built-in TLS

On both server implementations, the API uses the same runtime/state operations as the native administration protocol rather than modifying SQLite databases directly.
