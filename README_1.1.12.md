# Carracho 1.1.12

Carracho **Client 1.1.12 (build 23)** corrects the appearance of settings cards on macOS 10.15 Catalina. Card backgrounds now resolve their colors using the window's appearance, addressing white cards with unreadable light text in the dark Settings window. **Server 1.1.8 (build 19)** remains the current Server version; this correction requires only the updated Client.

## Highlights

- Corrected dynamic card background resolution in the macOS 10.15 appearance fallback.
- Settings cards now use their window's appearance when converting background and border colors for display.
- Cards refresh their colors when attached to a window and when their effective appearance changes.
- Added regression coverage for the Catalina fallback, readable text/background contrast and appearance restoration.
- Updated the Client to **1.1.12 / build 23**. The Server remains **1.1.8 / build 19**.

## Carracho Client 1.1.12

### Correct white settings cards in Catalina Dark appearance

Corrected the macOS 10.15 fallback for dynamic card colors to address white cards with unreadable light labels in the dark Settings window. The window explicitly uses Dark appearance, but the previous fallback converted card colors without setting that appearance as the current color-resolution context. Card backgrounds and borders now resolve within the card's effective appearance, keeping their colors consistent with the window and its labels.

On Catalina, the Client temporarily sets the current appearance while resolving the colors and restores the previous value afterwards. Newer macOS versions retain their existing appearance-scoped drawing API. This change applies to the shared card view, including the settings cards shown in the report.

### Refresh card colors when joining a window

Cards now refresh their background and border colors when attached to a window as well as after an effective appearance change. A card created before it inherits the Settings window's Dark appearance therefore updates its layer colors once it joins that window.

### Verify legacy color resolution and appearance restoration

Added a regression check that exercises the Catalina color-resolution fallback directly, including Dark cards in a Light application, the reverse combination, readable text/background contrast and nested restoration of the caller's appearance. It also checks card attachment and subsequent appearance changes. The Client build and these checks pass on the development system.

**Verification limit:** A direct test on macOS 10.15 Catalina is still pending. The regression exercises the fallback implementation on a newer macOS host; it does not replace checking the complete Settings window on Catalina.

## Carracho Server 1.1.8

### Send exact 64-bit sizes to modern clients

The macOS Server and native Linux Server now send exact file sizes in modern-only metadata for directory listings and file information replies. Previously, both Server implementations clamped these values to the historical 32-bit maximum of 4,294,967,295 bytes even for modern connections. Large-file sizes are now retained before encoding, and each directory page carries one 64-bit value for each entry.

The Classic packed records remain unchanged and retain their historical 32-bit size field. Extra size metadata is sent only to modern connections. This also works when Legacy compatibility is enabled on the Server; enabling compatibility does not limit modern peers to Classic file sizes.

### Preserve full sizes in filesystem and indexed searches

Modern file searches can opt into 64-bit result records. Both Server implementations retain full sizes during filesystem searches and resolve saturated 32-bit sizes from existing search indexes against the current file metadata. Existing indexes therefore support the correction without a database schema migration or a mandatory index rebuild.

The extended search format is sent only after a modern Client requests it. Classic clients and earlier modern clients continue to receive the original record format. Regression checks cover the 4 GiB boundary, larger sizes, pagination, malformed metadata, folder item counts, filesystem searches, indexed searches and complete modern/Legacy Client connections to both Server implementations.

## Compatibility notes

- **Client:** 1.1.12 (build 23).
- **Server:** 1.1.8 (build 19), unchanged. The Server section above documents the current Server release.
- The settings-card correction requires only the updated Client. No Server update, database migration or index rebuild is needed.
- The reconnect-avatar, Message Center text-color and attachment improvements from Client 1.1.11 remain included.
- Modern and explicit Classic/Legacy connections remain supported. No wire-protocol changes were introduced in Client 1.1.12.
- A direct check of the complete Settings window on macOS 10.15 remains outstanding before treating the reported rendering problem as verified on that OS.

Previous release notes: [`README_1.1.11.md`](README_1.1.11.md).
