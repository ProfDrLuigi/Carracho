# Carracho 1.1.10

Carracho **Client 1.1.10 (build 21)** and **Server 1.1.8 (build 19)** fix file sizes above 4 GB being displayed as 4.29 GB. Modern connections now carry exact 64-bit sizes for directory listings, file information and search results. Update both Client and Server to use the correction; Classic clients retain their historical protocol format.

## Highlights

- Files larger than 4,294,967,295 bytes now display their correct size on modern connections.
- File-list size sorting, the file information window and search results use the full file size.
- The macOS Server and native Linux Server provide matching 64-bit size metadata, including paginated directory replies.
- Search results preserve exact sizes with both filesystem searches and existing search indexes.
- Classic clients and earlier modern clients remain compatible.
- Updated the Client to **1.1.10 / build 21** and the Server to **1.1.8 / build 19**.

## Carracho Client 1.1.10

### Display correct sizes for files above 4 GB

Fixed large files appearing as 4.29 GB in the file list. The Client now reads the Server's additional 64-bit size metadata and uses the full value for the displayed size, sorting and the file information window. For example, a 10 GiB file is correctly displayed as approximately 10.74 GB instead of the historical 4.29 GB maximum.

The correction applies to modern connections, including connections to a Server with Legacy compatibility enabled. The size cache retains the full 64-bit value, and directory pages are merged with their corresponding size metadata. Folder item counts keep their existing meaning. Client 1.1.10 requires Server 1.1.8 or later for exact large-file sizes; older servers and explicit Legacy connections continue to provide their historical 32-bit values.

### Show full file sizes in search results

File searches now request and decode 64-bit result sizes on modern connections. Search results use the same full-size file-list model as ordinary directory listings, so displayed sizes and size sorting remain consistent after a search. Older servers can still return Classic-format results, which the Client continues to accept.

## Carracho Server 1.1.8

### Send exact 64-bit sizes to modern clients

The macOS Server and native Linux Server now send exact file sizes in modern-only metadata for directory listings and file information replies. Previously, both Server implementations clamped these values to the historical 32-bit maximum of 4,294,967,295 bytes even for modern connections. Large-file sizes are now retained before encoding, and each directory page carries one 64-bit value for each entry.

The Classic packed records remain unchanged and retain their historical 32-bit size field. Extra size metadata is sent only to modern connections. This also works when Legacy compatibility is enabled on the Server; enabling compatibility does not limit modern peers to Classic file sizes.

### Preserve full sizes in filesystem and indexed searches

Modern file searches can opt into 64-bit result records. Both Server implementations retain full sizes during filesystem searches and resolve saturated 32-bit sizes from existing search indexes against the current file metadata. Existing indexes therefore support the correction without a database schema migration or a mandatory index rebuild.

The extended search format is sent only after a modern Client requests it. Classic clients and earlier modern clients continue to receive the original record format. Regression checks cover the 4 GiB boundary, larger sizes, pagination, malformed metadata, folder item counts, filesystem searches, indexed searches and complete modern/Legacy Client connections to both Server implementations.

## Compatibility notes

- **Client:** 1.1.10 (build 21).
- **macOS Server and daemon / native Linux Server:** 1.1.8 (build 19).
- Update **both Client and Server** to display exact sizes above the Classic limit. Updating only the Client cannot restore sizes already clamped by an older Server.
- After updating the macOS Server app, use **System Service → Update Now** to update the installed daemon helper.
- Legacy compatibility can remain enabled. Modern connections receive the full sizes; explicit Classic/Legacy connections retain the historical 32-bit limit.
- Older modern clients continue to use the existing directory and file-info fields and receive Classic search records unless they opt into the extension.
- No Server database migration is required. File transfer payloads and transfer sizes are unchanged.

Previous release notes: [`README_1.1.9.md`](README_1.1.9.md).
