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
- Optional **Guest upload approval** keeps completed Guest uploads hidden until an Administrator approves or rejects them.
- Pending uploads show destination, uploader, size and upload time in Administration.
- Guest upload moderation is persistent and implemented on both macOS and native Linux.
- The File Watcher Guest-delivery policy and Guest upload approval setting are exposed through the normal server settings and HTTP Administration API.

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

### Guest upload moderation

Administration now also exposes **Guest uploads require approval** under **Advanced → Guest Upload Approval**.

The setting defaults to off. When enabled, completed uploads from **Guest** accounts are not published immediately. Instead, Administrators receive a pending-upload queue showing:

- file or destination path;
- uploader;
- size;
- upload time.

The queue provides **Approve**, **Reject**, and **Refresh** actions. Account Holder and Administrator uploads continue to publish immediately.

After a moderated upload has been received completely and safely moved into the pending area, a modern Guest client receives an explicit notice that the upload succeeded but is still awaiting Administrator approval. Folder uploads produce this notice only once, after the complete folder tree and all contained file data have been received and verified; individual child files do not generate separate approval notices.

The moderation commands use stable pending-upload IDs rather than exposing internal filesystem paths to the client. Older modern servers that do not support the feature leave the approval controls unavailable without breaking the rest of Administration.

## Carracho Server 1.0.9

### Cleaner File Watcher events

Bot File Watchers now ignore Carracho's internal transfer-staging paths on both server implementations.

Names matching the internal `.carracho` staging forms are excluded from recursive scans and filesystem-event processing. Descendants of staging directories are ignored as well.

This prevents a normal upload from producing announcements for temporary transfer artifacts before the final file or folder is in place.

The behavior is implemented in:

- the Swift/macOS filesystem watcher;
- the native Linux **inotify** watcher.

### Guest upload approval

Both server implementations can optionally moderate completed uploads from Guest accounts.

The setting is stored as:

```text
guestUploadApprovalEnabled
```

and defaults to `false` for existing configurations.

When enabled, a Guest upload still uses the normal `.carracho` transfer staging while bytes are arriving. After the transfer has been fully verified, the payload is moved into a hidden `.carracho-pending` area beside its intended destination instead of being published under its final name.

Before approval, the pending payload is:

- absent from normal Files listings;
- unavailable through normal download paths;
- excluded from the filename search index;
- ignored by Bot File Watchers.

The intended final destination remains reserved while the item is pending. This prevents another Guest, Account Holder, or Administrator upload from taking the same name before moderation is complete.

**Approve** performs a no-overwrite atomic move into the intended destination. Only after publication is the normal search index updated and the final filesystem event becomes visible to File Watchers.

**Reject** permanently deletes the hidden pending payload.

The pending manifest survives server restarts. Classic/Legacy Guest clients can still upload using the historical transfer protocol; moderation is a server-side decision and therefore does not require the uploading client to understand the new feature. Approval and rejection are modern Administrator operations.

### Configurable Guest delivery

File Watcher delivery now has an explicit server-side policy.

By default:

- **Administrator** members receive File Watcher announcements;
- **Account Holder** members receive File Watcher announcements;
- **Guest** members do not receive File Watcher announcements.

Administrators can enable Guest delivery from the Carracho client's Advanced server settings. The decision is applied by the server when each File Watcher announcement is published, so it is not merely a client-side display filter.

Normal Bot chat and RSS behavior remain separate from this File Watcher-specific policy.

### Persistence and remote administration

The File Watcher Guest-delivery setting is stored as:

```text
fileWatcherGuestsEnabled
```

Guest upload moderation uses:

```text
guestUploadApprovalEnabled
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
- The File Watcher Guest-delivery and Guest upload approval fields are modern server extensions.
- Older modern servers may omit the new fields; the 1.0.9 client handles those cases without making the rest of Advanced Administration unavailable.
- Classic/Legacy Guest clients can still be subject to server-side upload moderation, but approval and rejection require a modern Administrator client.

For the complete 1.0.9 feature set, use a Carracho 1.0.9 client with a matching Carracho Server 1.0.9.
