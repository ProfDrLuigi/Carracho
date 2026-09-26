# Carracho 1.0.8

Carracho 1.0.8 adds **message editing** for modern clients and servers, introduces configurable **Bot File Watchers**, improves direct navigation from Bot announcements into the Files browser, and removes duplicate Bot greeting controls from the macOS Server application.

Both the Swift/macOS server and the native Linux server implement the new modern protocol features while keeping Classic/Legacy protocol behavior unchanged.

## Highlights

- Edit your own **Conference and Private Messages** for up to five minutes after sending.
- Edited messages are marked in the client and Private Message edit state is preserved locally.
- New **Bot File Watchers** can announce newly created files and folders in a selected Conference.
- File Watcher templates support **`{folder}`** and **`{file}`** placeholders.
- Use **`.`** as the watched path to monitor the complete server Files root.
- Bot folder links can be opened directly in the client's **Files** browser.
- File Watcher administration is available through the Carracho client and the HTTP Administration API.
- The macOS and native Linux server implementations support the same File Watcher and message-editing protocol extensions.
- Updated the macOS application icon and expanded English/German localization.
- Removed the duplicate Automatic Greeting editor from the macOS Server window.

## Carracho Client 1.0.8

### Message editing

Messages sent to a modern Carracho Server can now be edited for up to **five minutes** after sending.

Editing is available for:

- your own Conference messages;
- your own Private Messages in Message Center.

The client shows an **Edit** action while a message is still inside the edit window and marks changed messages as **Edited** afterwards.

Private Message edit metadata is stored in the local Message Center database, so the edited state remains visible with the rest of the local conversation history.

Message editing is intentionally limited to normal text messages. Messages containing image or other media references are not editable.

Classic/Legacy connections continue to use the original protocol and do not receive modern edit metadata or edit events.

### Bot File Watcher administration

The Bot administration panel now includes a dedicated **File Watcher** section.

Administrators can configure multiple watchers with:

- enable/disable state;
- a folder below the server Files root;
- a target Conference;
- a custom announcement template.

Watcher paths are relative to the normal server Files root.

For example:

```text
Incoming
Incoming/Uploads
```

To watch the Files root itself, use:

```text
.
```

Announcement templates support:

```text
{folder}
{file}
```

`{folder}` inserts a clickable link to the affected folder.

`{file}` inserts the detected file or folder name.

Example:

```text
New {file} in {folder}
```

A File Watcher folder link can be clicked directly in Conference Chat. The client switches to **Files** and opens the corresponding server folder.

### Interface and compatibility

- Added File Watcher controls to remote Bot administration.
- Added capability detection so unsupported servers do not expose unavailable File Watcher actions.
- Added direct handling for `carracho-file:///` links.
- Updated the application icon artwork.
- Expanded English and German localization for File Watchers and message editing.

## Carracho Server 1.0.8

### Server-side message editing

The modern server protocol now supports message identifiers, server timestamps, edit capability negotiation, and edit events.

The server enforces the edit rules rather than relying on the client's clock.

An editable message must:

- belong to the user requesting the edit;
- still be inside the five-minute edit window;
- be a modern text message;
- contain no media attachment references.

Conference edits are propagated to modern members of the Conference.

Private Message edits are propagated to the modern participants in the conversation.

Classic/Legacy clients never receive modern edit packets, so their historical protocol layout and behavior remain unchanged.

The feature is implemented in both:

- the Swift/macOS Carracho Server runtime;
- the native Linux/C server runtime.

### Bot File Watchers

Carracho Server now supports persistent **Bot File Watchers**.

A watcher monitors a configured directory below the normal Files root and can post an announcement to a selected Conference when new files or folders appear.

Watcher configuration includes:

- unique watcher ID;
- enable/disable state;
- relative watched path;
- target Conference;
- announcement template.

Up to **32 File Watchers** can be configured.

Use `.` as the path to monitor the Files root itself.

Watcher paths are validated so they cannot escape the configured Files root.

### File Watcher announcements

File Watchers support two template variables:

```text
{folder}
{file}
```

`{folder}` becomes a clickable `carracho-file:///` link pointing to the affected folder.

`{file}` becomes the name of the detected file or folder.

Example:

```text
New {file} in {folder}
```

Filesystem event bursts are coalesced before posting, and repeated announcements for the same watcher/folder are rate-limited.

Hidden filesystem entries are ignored.

### macOS implementation

The Swift/macOS server uses native filesystem event sources and recursively tracks configured watcher directories.

Watcher configuration is reloaded while the server is running, so changes made through Administration do not require restarting the server.

### Native Linux implementation

The native Linux server includes the matching File Watcher implementation using **inotify**.

It supports:

- recursive directory monitoring;
- new file and folder detection;
- configuration reloads;
- debounce/coalescing;
- announcement cooldowns;
- the same `{folder}` / `{file}` template behavior as the macOS server.

### Remote administration and HTTP API

File Watchers can be managed through the modern Carracho administration protocol.

The HTTP Administration API also exposes File Watcher configuration:

```http
GET /api/v1/bot/file-watchers
PUT /api/v1/bot/file-watchers
```

The server validates watcher IDs, paths, target Conferences, templates, and watcher-count limits before saving the configuration.

### macOS Server interface cleanup

The duplicate **Automatic Greeting** editor has been removed from the macOS Server window.

Bot greetings remain fully supported. They are now configured centrally from:

**Carracho Client → Administration → Bot**

The underlying greeting configuration remains part of the Bot configuration and is preserved when other Bot settings are changed.

## Compatibility

Carracho 1.0.8 continues to preserve Classic/Legacy compatibility.

The new features are modern protocol extensions:

- message editing is negotiated as a modern capability;
- edit packets are not sent to Classic clients;
- File Watcher administration requires a modern server;
- the existing Classic chat, Private Message, file and Conference packet formats are not changed.

For the complete 1.0.8 feature set, use a Carracho 1.0.8 client with a matching Carracho Server 1.0.8.
