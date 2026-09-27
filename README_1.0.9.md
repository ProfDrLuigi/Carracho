# Carracho 1.0.9

Carracho 1.0.9 is a focused performance, presentation, and server-behavior release. It makes large server-wide Files searches substantially lighter to scroll, keeps Conference message identity intact after users disconnect, refreshes Tracker and macOS Server artwork, and gives administrators explicit control over whether Bot File Watcher announcements are visible to Guest accounts.

The Swift/macOS and native Linux servers continue to share the same modern File Watcher behavior while preserving Classic/Legacy protocol compatibility.

## Highlights

- Significantly smoother scrolling for large **server-wide Files search** result sets.
- More robust processing of very large search streams without deep callback recursion.
- Conference history keeps the sender's **nickname, avatar, and group color** after disconnect.
- Saved Tracker entries now use the dedicated **Carracho Tracker** artwork.
- Refreshed **Carracho Server for macOS** application icon.
- Bot File Watchers ignore internal **`.carracho` transfer-staging** paths.
- File Watcher announcements remain restricted to **Account Holder** and **Administrator** members by default.
- Administrators can optionally allow **Guest** members to receive File Watcher announcements.
- The Guest-delivery policy is persistent and implemented on both macOS and native Linux, including the HTTP Administration API.

## Carracho Client 1.0.9

### Faster large Files searches

Large server-wide search results have been reworked to avoid doing expensive work every time AppKit asks for a visible table cell.

Search results now use lightweight reusable cells rather than constructing the richer normal Files-browser hierarchy for every row entering the viewport.

The client also avoids repeatedly recomputing data while scrolling:

- the sorted search result set is kept as a stable snashot;
- formatted file sizes are cached;
- formatted modification dates are cached;
- file-kind text is cached by extension where possible;
- bundled file-type artworb is cached;
- LaunchServices is queried only for the actual final file extension instead of every dotted suffix in a filename.

This substantially reduces allocation, layout, sorting, and icon-resolution overhead for result sets containing thousands of files.

### More robust search-result streaming

The legacy-compatible file-search reader can receive multiple records from bytes that are already buffered by `NWConnection`.

Previously, immediately reading the next record from inside the completion callback could build a very deep callback chain on sufficiently large result sets.

Carracho 1.0.9 schedules the next buffered record, and Classic keepalive processing, back onto the serial search queue before continuing. This lets the current callback unwind completely and prevents large searches from exhausting the worker thread's stack.

No search protocol change is required for this improvement.

### Conference history keeps sender identity

Conference transcript rows no longer depend entirely on the current online-user table.

When a message is received, Carracho retains the sender information needed to render that historical row. Before a user is removed after disconnect, any older rows that still depend on the live user record are frozen as well.

As a result, previous Conference messages continue to show the sender's:

- nickname;
- avatar;
- group color.

This avoids old rows turning into **Unknown User** or losing their original presentation merely because the sender went offline.

### Tracker presentation

Saved Tracker rows now use the dedicated Carracho **Trackers** artwork instead of the previous generic system network symbol.

The collapsible Tracker section header remains focused on disclosure state, while the actual Tracker entries carry the service-specific icon.

### File Watcher Guest visibility

Administration now exposes a dedicated setting under **Advanced → Bot File Watchers**:

**Show announcements to Guests**

The default remains off. With the setting disabled, File Watcher messages are sent only to **Account Holder** and **Administrator** members of the selected Conference.

When enabled, **Guest** members in that Conference receive the same File Watcher announcement.

The setting is loaded and saved through the normal modern server-settings protocol.

For compatibility with older modern servers, the client treats the field as optional. If a connected server does not expose it, the File Watcher Guest control is disabled and the rest of the Advanced settings page continues to work normally.

## Carracho Server 1.0.9

### Cleaner File Watcher events

Bot File Watchers now ignore Carracho's internal transfer-staging paths on both server implementations.

Names matching the internal `.carracho` staging forms are excluded from recursive scans and filesystem-event processing. Descendants of staging directories are ignored as well.

This prevents a normal upload from producing announcements for temporary transfer artifacts before the final file or folder is in place.

The behavior is implemented in:

- the Swift/macOS filesystem watcher;
- the native Linux **inotify** watcher.

### Configurable Guest delivery

File Watcher delivery now has an explicit server-side policy.

By default:

- **Administrator** members receive File Watcher announcements;
- **Account Holder** members receive File Watcher announcements;
- **Guest** members do not receive File Watcher announcements.

Administrators can enable Guest delivery from the Carracho client's Advanced server settings. The decision is applied by the server when each File Watcher announcement is published, so it is not merely a client-side display filter.

Normal Bot chat and RSS behavior remain separate from this File Watcher-specific policy.

### Persistence and remote administration

The new Guest-delivery setting is stored as:

```text
fileWatcherGuestsEnabled
```

It defaults to `false` when absent from an older configuration.

The setting is supported by both the Swift/macOS and native Linux server state and startup configuration paths, and it survives server restarts.

Remote Carracho Administration uses a modern server-setting field for the same value.

The HTTP Administration API also exposes the boolean through:

```text
GET /api/v1/settings
PATCH /api/v1/settings
```

This keeps GUI administration, protocol administration, startup configuration, and HTTP administration aligned.

### macOS Server artwork

Carracho Server for macOS now uses refreshed application icon artwork and an updated asset-catalog representation for the Server app.

## Compatibility

Carracho 1.0.9 continues to preserve Classic/Legacy behavior.

- The Files-search performance changes are client-side implementation improvements and do not alter the search protocol.
- Conference identity snapshots affect only local transcript rendering.
- The File Watcher Guest-delivery field is a modern server extension.
- Older modern servers may omit the new field; the 1.0.9 client handles that case without making the rest of Advanced Administration unavailable.
- Classic/Legacy clients do not need to understand the new setting.

For the complete 1.0.9 feature set, use a Carracho 1.0.9 client with a matching Carracho Server 1.0.9.
