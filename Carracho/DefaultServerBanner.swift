import AppKit
import Foundation

/// Produces the built-in Carracho logo as PNG data for a newly-created server.
/// This is deliberately an app/bootstrap concern rather than a ServerState default:
/// once an administrator removes or replaces the banner, reopening that server must
/// never silently put the bundled logo back.
enum CarrachoDefaultServerBanner {
    static func pngData() -> Data? {
        guard let image = NSImage(named: "CarrachoLogo"),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
