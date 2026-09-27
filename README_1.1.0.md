# Carracho 1.1.0

Carracho 1.1.0 adds a complete optional moderation workflow for **Guest uploads**. Servers can keep completed Guest uploads outside the published Files tree until an Administrator explicitly approves or rejects them, while Account Holder and Administrator uploads continue to publish normally.

The feature is implemented consistently by the Swift/macOS and native Linux servers, including persistent pending state, remote administration, destination-name reservation, and explicit uploader feedback in the modern client.

## Highlights

- Optional **Guest uploads require approval** policy.
- Dedicated **Pending Guest Uploads** queue in Administration.
- Pending rows show destination, uploader, size, and upload time.
- Administrators can **Approve**, **Reject**, and **Refresh** pending uploads.
- Connected Administrator bookmarks show **🚨** while one or more Guest uploads are awaiting approval.
- Completed Guest payloads remain hidden in a persistent **`.carracho-pending`** area until moderation is complete.
- Pending uploads are excluded from normal Files listings, downloads, filename search, and Bot File Watchers.
- The intended final destination stays reserved while an upload is pending.
- Approval publishes without overwriting an existing destination.
- Modern Guest clients receive an explicit **awaiting approval** notice after the server has accepted the complete upload.
- **Folder uploads** receive that notice only once, after the entire folder tree and all contained file data have been received and verified.
- Pending upload state survives server restarts on both macOS and Linux.
- The policy is available through modern server settings and the HTTP Administration settings API.
- Classic/Legacy Guest uploaders remain compatible because moderation is enforced server-side.

## Carracho Client 1.1.0

### Guest upload moderation in Administration

Administration now includes **Guest Upload Approval** under **Advanced**.

The new **Guest uploads require approval** option is disabled by default. When enabled, completed uploads from Guest accounts are placed into the server's pending queue instead of being published immediately.

Administrators can review pending uploads with the following information:

- destination path;
- uploader;
- size;
- upload time.

The queue provides **Approve**, **Reject**, and **Refresh** actions.

### Bookmark approval alert

A connected Administrator bookmark displays **🚨** whenever that server has one or more Guest uploads awaiting approval. The state is maintained per bookmark, so a background-connected server can raise the alert without being the currently active server.

The server pushes queue-count changes to connected modern Administrators when a new pending upload is created or an item is approved/rejected. On connection or reconnection, the client also loads the existing pending queue so already-waiting uploads are not missed. The alert disappears automatically after the final pending upload has been resolved.

Approval and rejection use stable pending-upload identifiers rather than exposing internal server filesystem paths to the client.

When connected to an older modern server that does not expose Guest upload approval, the client leaves the moderation controls unavailable while keeping the rest of Administration usable.

### Clear feedback for Guest uploaders

A modern Guest client now receives a dedicated notice after a moderated upload has been fully accepted into the server's approval queue.

For a file upload, the client explains that the upload completed successfully but will become visible only after an Administrator approves it.

For a folder upload, Carracho waits until the **entire folder transfer** has completed. The notice is sent only once, after all subfolders and contained files have been received and verified. Individual files inside the folder do not generate separate approval notices.

This keeps the distinction clear between:

- the transfer finishing successfully; and
- the uploaded item becoming publicly visible in Files.

## Carracho Server 1.1.0

### Server-side Guest upload approval

Both server implementations support the persistent setting:

```text
guestUploadApprovalEnabled
```

It defaults to `false` for existing configurations.

When the setting is enabled, Guest uploads continue to use the normal `.carracho` transfer-staging path while data is arriving. After the complete upload has been validated, the payload is moved into a hidden `.carracho-pending` area instead of being published under its intended final name.

Before approval, a pending payload is:

- absent from normal Files listings;
- unavailable through normal download paths;
- excluded from the filename search index;
- ignored by Bot File Watchers.

Account Holder and Administrator uploads are unaffected and continue to publish immediately.

### Complete folder handling

Folder uploads are moderated as one complete upload tree.

The server receives and verifies every transfer entry first, including all nested files and subfolders. Only after the complete tree has passed the final transfer checks is the root folder accepted into the pending area.

The uploader notification is emitted after that point, so a partial or interrupted folder upload cannot be reported as awaiting approval.

### Safe publication and rejection

While an item is pending, its intended final destination remains reserved. A second upload cannot silently claim the same destination name before moderation is resolved.

**Approve** publishes the pending payload using no-overwrite semantics. Once publication succeeds, the normal filename search index is updated and the final filesystem event becomes visible to Bot File Watchers.

**Reject** permanently removes the hidden pending payload.

The pending manifest is persisted and survives server restarts.

### macOS and Linux parity

The Guest upload approval workflow is implemented in both:

- the Swift/macOS server runtime;
- the native Linux server runtime.

Both implementations apply the same core behavior for staging, destination reservation, approval, rejection, persistence, search visibility, and uploader notification.

### Remote configuration

The approval policy is exposed through the normal modern Carracho server-settings protocol.

The native Linux HTTP Administration API also exposes:

```text
guestUploadApprovalEnabled
```

through:

```text
GET /api/v1/settings
PATCH /api/v1/settings
```

The HTTP settings API controls the policy itself. Pending-upload **Approve** and **Reject** actions remain Carracho Administration operations and are not exposed as HTTP moderation endpoints.

## Compatibility

Carracho 1.1.0 keeps the historical transfer protocol compatible while adding modern moderation controls.

- Guest upload approval is a server-side policy.
- Classic/Legacy Guest clients can therefore still upload normally and can still be subject to approval.
- The explicit **awaiting approval** uploader notice is a modern asynchronous extension and is not sent to Classic/Legacy clients.
- Approval and rejection require modern Administrator support.
- Older modern servers may omit the Guest upload approval setting; the 1.1.0 client handles that case without breaking the rest of Administration.
- Account Holder and Administrator uploads retain their existing immediate-publication behavior.

For the complete 1.1.0 workflow, use a Carracho 1.1.0 client with a matching Carracho Server 1.1.0.
