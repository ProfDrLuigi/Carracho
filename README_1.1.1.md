# Carracho 1.1.1

Carracho 1.1.1 improves transparency around **Classic/Legacy compatibility**. Modern users can now immediately see whether the connected server allows Classic clients, and Classic users are clearly identified in the modern user list.

The Swift/macOS and native Linux servers expose the same compatibility state to modern clients while preserving the historical Server Info layout for Classic clients.

## Highlights

- Added a visible **Legacy Mode = On / Off** line below the connected server description.
- The value reflects the server's actual authentication/compatibility configuration.
- Both the Swift/macOS and native Linux servers expose the same modern Server Info capability.
- Classic clients continue to receive the historical Server Info field set unchanged.
- When an Administrator changes the authentication mode, the local server header updates immediately.
- Classic/Legacy users are now shown with the fixed status text **`@ Legacy`** in the modern user list.
- Modern user status messages remain unchanged.
- Fixed **Modern Only** authentication so modern accounts, including Administrators, authenticate independently of the retained Legacy credential.
- Added verifier-based modern login using the existing PBKDF2-SHA256 account verifier and an HMAC challenge/response bound to the login challenge and X25519 client key.
- Guest accounts can no longer send offline messages; the send action is hidden in the client and enforced by both server implementations.
- Removed the visible server address/IP column from Tracker result tables; addresses remain internal for connecting to the selected server.
- Added reactions to modern Private Messages in Message Center, using the same reaction set as News.
- Updated Carracho and Carracho Server version reporting to **1.1.1 / build 12**.

## Carracho Client 1.1.1

### Visible Legacy Mode state

The connected-server header now contains a third line below the server description:

```text
Legacy Mode = On
```

or:

```text
Legacy Mode = Off
```

**Legacy Mode = On** means that the server is configured to allow Classic/Legacy clients in addition to modern clients.

**Legacy Mode = Off** means that Classic/Legacy connections are disabled.

The client does not infer this state from the currently connected users. It reads the value directly from the server's advertised compatibility configuration.

Older modern servers that do not provide the new capability simply omit the Legacy Mode line rather than displaying an assumed value.

When an Administrator changes the authentication mode from Advanced Administration, the displayed Legacy Mode state is refreshed immediately after the setting is saved.

### Cleaner Tracker server list

The Tracker result table no longer displays the server address/IP column. Server endpoints remain available internally for sorting fallback and connection handling, but the visible list now focuses on server name, user count, description, and the remaining Tracker metadata.

### Private Message reactions

Modern Private Messages now support reactions directly in Message Center. Each reactable message shows a **☺ React** action with the same reaction set used by News: 👍, ❤️, 😂, 🎉, 😮, and 😢. Each participant can keep one reaction per message, replace it with another reaction, or remove it again.

Reaction changes are delivered live between the two connected modern clients. The Message Center keeps the local user's reaction and the peer's reaction separately and persists both in `messages.sqlite3`, so they remain visible after reopening the client.

Modern Private Messages now use a shared wire message UUID whenever the server advertises PM reactions. This shared ID is also used for messages with media attachments, while the existing five-minute edit rules remain unchanged and still apply only to eligible text messages. Previously stored PMs whose UUID existed only locally are intentionally not marked as reactable because the other participant never received that historical identifier.

The server only routes reaction events; it does not persist Private Message history or reaction state. Reactions require a current server and two connected modern clients. Classic Private Messages are unchanged and never receive the reaction capability or reaction packets. The Swift/macOS and native Linux servers implement the same reaction protocol.

### Guest offline-message restriction

Guest accounts can still receive and read offline messages, but they can no longer send them. The modern client hides the **Send Offline Messages** action completely for Guests and closes an already-open offline-message composer if the account is changed to Guest while connected.

The restriction is also enforced server-side. Both the Swift/macOS and native Linux servers reject Guest requests to obtain the offline-message recipient list or send an offline message, so older or modified clients cannot bypass the UI restriction. Account Holders and Administrators keep the existing offline-message functionality.

### Modern Only login fix

Modern clients no longer depend on the legacy password representation when authenticating to a current server. This fixes the Modern Only lockout while allowing the server to retain the existing `legacyPassword` for a later switch back to Legacy Compatible mode.

Carracho 1.1.1 introduces a modern verifier-based login preflight. The server supplies the account's PBKDF2-SHA256 salt and iteration count, the client derives the verifier locally from the entered password, and proves possession using HMAC-SHA256 over the fresh login challenge, login name, and X25519 client public key. The password itself is not sent to the server by this new login path.

The resulting authentication binding is then used by the existing X25519/AES-256-GCM transport handshake. **Modern Only** therefore disables the Classic transport without deleting compatible Legacy credentials from persisted account state. Switching back to Legacy Compatible mode does not require password resets as long as those retained credentials still exist.

Classic authentication remains unchanged and is available only while Legacy compatibility is enabled. Older modern clients that do not implement the verifier login cannot authenticate to a Modern Only 1.1.1 server and should be updated to 1.1.1.


### Reversible Legacy Mode switching

Changing between **Legacy Compatible** and **Modern Only** no longer deletes `legacyPassword` from normal network accounts. Modern Only is now a transport/authentication policy rather than a destructive credential migration.

When a compatible password is changed while Modern Only is active, the server updates both the modern PBKDF2 verifier and the retained Legacy credential so switching Legacy Mode back on remains reversible. If a Modern Only password cannot be represented by the Classic protocol, no usable Legacy credential can be stored for that account; enabling Legacy Compatible mode then requires resetting that account to a Classic-compatible password first.

Local server-only accounts such as the built-in Bot remain verifier-only and never retain a network-usable Legacy password.

### Clear Classic-user identification

Classic/Legacy clients cannot publish the modern per-user status message used by current Carracho clients.

The modern user list therefore uses that otherwise unused status row to display:

```text
@ Legacy
```

for users connected through the Classic/Legacy transport.

This leaves normal modern status messages untouched while making it immediately visible which users are connected through the historical protocol.

## Carracho Server 1.1.1

### Public compatibility state for modern clients

The modern Server Info reply now includes the public boolean capability:

```text
legacyCompatibilityEnabled
```

using modern Server Info field:

```text
0xf0000106
```

The value is taken directly from the server configuration:

- Swift/macOS: the configured authentication mode;
- native Linux: the server's `legacy_compatible` state.

This allows a modern client to distinguish between its own secure modern transport and the separate server policy that determines whether Classic clients may also connect.

### Modern verifier authentication

The Swift/macOS and native Linux servers now support the same verifier-based modern authentication preflight. Accounts are authenticated with their persisted `passwordVerifier` even when `legacyPassword` is absent, which is the expected state after enabling **Modern Only**.

Unknown or locally restricted login names receive non-authenticating verifier parameters so the preflight does not simply expose account existence through a different packet shape. The final proof is bound to the server challenge, login identity, and client X25519 key before the normal encrypted transport is established.

### Classic compatibility preserved

The new compatibility field is sent only to modern sessions.

Classic clients continue to receive the historical Server Info fields only, preserving compatibility with original clients that do not safely skip modern extension fields.

### macOS and Linux parity

Both server implementations expose the same Legacy compatibility state to modern clients:

- Swift/macOS Server;
- native Linux Server.

The native Linux Server Info reply and HTTP status version reporting now identify the server as **Carracho Server 1.1.1**.

The Bot RSS user agent has likewise been updated to **Carracho-Bot-RSS/1.1.1** on both server implementations.

## Compatibility

Carracho 1.1.1 does not change the historical Classic protocol.

- The new Legacy Mode capability is a modern Server Info extension.
- Classic clients do not receive the new field.
- Older modern servers can still be used; the 1.1.1 client simply hides the Legacy Mode line when the capability is unavailable.
- Modern Only authentication requires the new verifier-login support; use matching 1.1.1 client/server builds for Modern Only deployments.
- The **`@ Legacy`** marker is a client-side presentation feature and does not modify Classic user data.
- Modern users retain their normal status-message behavior.

For the complete Legacy Mode visibility feature, use a Carracho 1.1.1 client with a matching Carracho Server 1.1.1.
