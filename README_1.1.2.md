# Carracho 1.1.2

Carracho 1.1.2 focuses on **Private Message interaction, clearer unread state, tighter Guest restrictions, and Linux server packaging**. The macOS client and server are version **1.1.2 (build 13)**, with matching protocol support in the native Linux server.

## Highlights

- Added reactions to modern Private Messages using the same reaction set as News.
- Guest accounts can no longer send offline messages; the restriction is enforced in the client and on both server implementations.
- Removed the visible address/IP column from Tracker result tables.
- Added red unread badges with white counts for Conference messages, Private Messages, and Offline Messages.
- Added a client preference for hiding user sign-in/sign-out notifications.
- Linux server builds and installers now include the bundled Bot avatar under `etc/` and preserve customized avatars across upgrades.
- Updated Carracho and Carracho Server version reporting to **1.1.2 / build 13**.

## Carracho Client 1.1.2

### Private Message reactions

Modern Private Messages now support reactions directly in Message Center. Each reactable message exposes a **☺ React** action with the same reaction set used by News: 👍, ❤️, 😂, 🎉, 😮, and 😢.

Each participant can keep one reaction per message, replace it with another reaction, or remove it. Reaction changes are delivered live between two connected modern clients. The local user's reaction and the peer's reaction are stored separately in `messages.sqlite3`, so the state remains visible after reopening the client.

Reaction-capable Private Messages use a shared message UUID on the wire, including messages with media attachments. Existing five-minute edit rules remain unchanged and still apply only to eligible text messages. Previously stored Private Messages are intentionally not retrofitted with reactions because their old locally generated UUIDs were never shared with the peer.

Classic Private Messages remain unchanged and never receive reaction capability or reaction packets.

### Guest offline-message restriction

Guest accounts can still receive and read offline messages, but they can no longer send them. The modern client hides **Send Offline Messages** completely for Guests and closes an already-open offline-message composer if the active account is changed to Guest while connected.

The restriction is also enforced by both the Swift/macOS and native Linux servers. Guest requests for the offline-message recipient list or for sending an offline message are rejected server-side, so older or modified clients cannot bypass the client UI restriction.

Account Holders and Administrators retain the existing offline-message functionality.

### Cleaner Tracker server list

The Tracker result table no longer shows the server address/IP column. Endpoints remain available internally for connecting to the selected server, while the visible list focuses on server name, user count, description, and the remaining Tracker metadata.

### Unread badges in the sidebar

Conference messages, Private Messages, and Offline Messages now use compact **red badges with white counts** in the sidebar, matching the existing bookmark notification style.

For Conferences, an expanded section shows the unread badge on the affected room. When the Conferences section is collapsed, the combined unread total moves to the **Conferences** row. Counts above 99 are displayed as **99+**.

### Optional sign-in/sign-out notifications

The General client settings now include **Show user sign-in and sign-out notifications** under **Server Messages**.

The option defaults to enabled so existing behaviour is preserved. When disabled, visual notifications announcing that a user entered or left a server are suppressed. Presence tracking and the user list remain active, and separately configured sign-in/sign-out sounds continue to work.

## Carracho Server 1.1.2

### Private Message reaction routing

The Swift/macOS and native Linux servers advertise the modern Private Message reaction capability and relay reaction changes between connected modern peers. The server does not persist Private Message history or reaction state; that remains client-side.

Classic sessions are excluded from the reaction extension and keep the historical Private Message protocol unchanged.

### Guest offline-message enforcement

Both server implementations now reject Guest requests to obtain the offline-message recipient list or send an offline message. Guests can still receive and read offline messages.

### Linux Bot avatar packaging

Native Linux builds now stage `carracho-bot-avatar.png` together with the server and Bot configuration under `etc/`.

Fresh source installs deploy the bundled 128 × 128 PNG to:

```text
/opt/carracho/etc/carracho-bot-avatar.png
```

Source-based upgrades preserve an existing live Bot avatar instead of replacing an administrator-selected image with the bundled default. Debian server packages also include the PNG and register it as a configuration file so normal package upgrades preserve local customization.

### Version reporting

macOS and Linux server version reporting now identifies the release as **Carracho Server 1.1.2**. The Bot RSS user agent is updated to `Carracho-Bot-RSS/1.1.2` on both server implementations.

## Compatibility notes

- Private Message reactions require a current modern server and modern clients on both ends.
- Classic Private Messages are unchanged.
- Guest offline-message sending is intentionally blocked server-side, including for older clients.
- Existing Message Center databases are migrated in place for reaction metadata.
- Existing customized Linux Bot avatars are preserved during supported source/package upgrades.
