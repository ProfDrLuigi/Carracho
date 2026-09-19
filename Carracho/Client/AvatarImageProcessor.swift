import Cocoa
import UniformTypeIdentifiers

enum AvatarImageError: LocalizedError {
    case notPNG
    case unreadableImage
    case renderFailed
    case encodedImageTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .notPNG:
            return L("Please choose a PNG image.")
        case .unreadableImage:
            return L("The PNG image could not be read.")
        case .renderFailed:
            return L("The avatar could not be rendered.")
        case let .encodedImageTooLarge(bytes):
            return LF("The normalized avatar is too large for the protocol (%@ bytes).", String(bytes))
        }
    }
}

enum AvatarArtwork {
    private static let classicPayloadBytes = 0x27c
    private static let classicPixelBytes = 0x200
    private static let classicWidth = 16
    private static let classicHeight = 16
    private static let classicRowBytes = 32

    static func defaultImage() -> NSImage? {
        if let image = NSImage(named: "CarrachoAvatar") { return image }
        if let image = NSImage(named: NSImage.applicationIconName) { return image }
        if #available(macOS 11.0, *) {
            return NSImage(systemSymbolName: "person.crop.square", accessibilityDescription: L("Avatar"))
        }
        return NSImage(named: NSImage.userName)
    }

    static func decodedImage(from data: Data) -> NSImage? {
        guard !data.isEmpty else { return nil }
        if let image = NSImage(data: data) { return image }
        return classicImage(from: data)
    }

    static func userImage(picture: Data, isLegacyTransport: Bool) -> NSImage? {
        if let image = decodedImage(from: picture) { return image }
        if isLegacyTransport, let image = NSImage(named: NSImage.Name("LegacyAvatar")) {
            return image
        }
        return defaultImage()
    }

    /// Decodes the native 16 × 16 avatar payload emitted by Carracho 1.0b10r4.
    ///
    /// The original client allocates a 512-byte 8-bit PixMap with rowBytes=32,
    /// reads the first 0x200 bytes of the 0x27c-byte picture field into it and
    /// displays the first 16 bytes of each row. Pixel value 0 is transparent;
    /// all other values are indexes into QuickDraw's standard clut #8.
    private static func classicImage(from data: Data) -> NSImage? {
        guard data.count == classicPayloadBytes,
              data.count >= classicPixelBytes,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: classicWidth,
                                            pixelsHigh: classicHeight,
                                            bitsPerSample: 8,
                                            samplesPerPixel: 4,
                                            hasAlpha: true,
                                            isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bitmapFormat: [],
                                            bytesPerRow: classicWidth * 4,
                                            bitsPerPixel: 32),
              let destination = bitmap.bitmapData else {
            return nil
        }

        data.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0 ..< classicHeight {
                for x in 0 ..< classicWidth {
                    let index = source[y * classicRowBytes + x]
                    let offset = (y * classicWidth + x) * 4
                    if index == 0 {
                        destination[offset] = 0
                        destination[offset + 1] = 0
                        destination[offset + 2] = 0
                        destination[offset + 3] = 0
                    } else {
                        let color = classicCLUT8(index)
                        destination[offset] = color.red
                        destination[offset + 1] = color.green
                        destination[offset + 2] = color.blue
                        destination[offset + 3] = 255
                    }
                }
            }
        }

        bitmap.size = NSSize(width: classicWidth, height: classicHeight)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// QuickDraw GetCTable(8): 6×6×6 reversed RGB cube, followed by extra
    /// red/green/blue/gray ramps, with black deliberately placed at index 255.
    private static func classicCLUT8(_ index: UInt8) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let value = Int(index)
        if value < 215 {
            return (
                UInt8((5 - value / 36) * 51),
                UInt8((5 - (value / 6) % 6) * 51),
                UInt8((5 - value % 6) * 51)
            )
        }
        if value == 255 { return (0, 0, 0) }

        let ramp = [14, 13, 11, 10, 8, 7, 5, 4, 2, 1]
        let relative = value - 215
        let component = UInt8(ramp[relative % 10] * 17)
        switch relative / 10 {
        case 0: return (component, 0, 0)
        case 1: return (0, component, 0)
        case 2: return (0, 0, component)
        default: return (component, component, component)
        }
    }
}

enum AvatarImageProcessor {
    static let pixelSize = 128
    static let maximumWireBytes = Int(UInt16.max)

    static func normalizedPNG(from url: URL) throws -> Data {
        guard url.pathExtension.lowercased() == "png" else { throw AvatarImageError.notPNG }
        guard let image = NSImage(contentsOf: url) else { throw AvatarImageError.unreadableImage }
        return try normalizedPNG(from: image)
    }

    static func normalizedPNG(from image: NSImage) throws -> Data {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { throw AvatarImageError.unreadableImage }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw AvatarImageError.renderFailed
        }

        bitmap.size = NSSize(width: pixelSize, height: pixelSize)
        let side = min(width, height)
        let source = NSRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
        let destination = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Preserve PNG transparency when normalizing to 128 × 128. An opaque fill here
        // becomes a visible light circle once the client presents the avatar in its round mask.
        context.cgContext.clear(destination)
        image.draw(in: destination,
                   from: source,
                   operation: .sourceOver,
                   fraction: 1,
                   respectFlipped: false,
                   hints: [.interpolation: NSImageInterpolation.high])
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AvatarImageError.renderFailed
        }
        guard png.count <= maximumWireBytes else { throw AvatarImageError.encodedImageTooLarge(png.count) }
        guard let check = NSBitmapImageRep(data: png), check.pixelsWide == pixelSize, check.pixelsHigh == pixelSize else {
            throw AvatarImageError.renderFailed
        }
        return png
    }
}

final class AvatarDropView: NSView {
    private let imageView = NSImageView()
    private let hintLabel = NSTextField(labelWithString: L("Drop a PNG here"))
    private let statusLabel = NSTextField(labelWithString: L("128 × 128 PNG"))
    private let chooseButton = NSButton(title: L("Choose PNG…"), target: nil, action: nil)
    private let removeButton = NSButton(title: L("Remove"), target: nil, action: nil)

    private(set) var avatarData: Data

    init(initialData: Data) {
        avatarData = initialData
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        registerForDraggedTypes([.fileURL])

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 128).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 128).isActive = true

        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.alignment = .center
        hintLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.alignment = .center
        statusLabel.textColor = .tertiaryLabelColor

        chooseButton.target = self
        chooseButton.action = #selector(choosePNG(_:))
        chooseButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeAvatar(_:))
        removeButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [chooseButton, removeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [imageView, hintLabel, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
        ])

        if let image = NSImage(data: initialData), !initialData.isEmpty {
            imageView.image = image
            statusLabel.stringValue = LF("Current avatar · %@ bytes", String(initialData.count))
        } else {
            setPlaceholder()
        }
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setPlaceholder() {
        imageView.image = AvatarArtwork.defaultImage()
        imageView.contentTintColor = nil
        hintLabel.stringValue = L("Drop a PNG to use your own")
        statusLabel.stringValue = L("Default Carracho avatar")
        statusLabel.textColor = .tertiaryLabelColor
    }

    private func updateButtons() {
        removeButton.isEnabled = !avatarData.isEmpty
    }

    @objc private func choosePNG(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = L("Choose Avatar PNG")
        panel.prompt = L("Use Avatar")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.png]
        } else {
            panel.setValue(["png"], forKey: "allowedFileTypes")
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }

    @objc private func removeAvatar(_ sender: Any?) {
        avatarData = Data()
        imageView.contentTintColor = nil
        setPlaceholder()
        updateButtons()
    }

    private func load(_ url: URL) {
        do {
            let png = try AvatarImageProcessor.normalizedPNG(from: url)
            avatarData = png
            imageView.contentTintColor = nil
            imageView.image = NSImage(data: png)
            hintLabel.stringValue = L("Drop another PNG to replace")
            statusLabel.stringValue = LF("128 × 128 PNG · %@ bytes", String(png.count))
            statusLabel.textColor = .tertiaryLabelColor
            updateButtons()
        } catch {
            statusLabel.stringValue = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            statusLabel.textColor = .systemRed
        }
    }

    private func droppedFileURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return objects?.first(where: { $0.pathExtension.lowercased() == "png" })
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedFileURL(from: sender) != nil else { return [] }
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        guard let url = droppedFileURL(from: sender) else { return false }
        load(url)
        return true
    }
}
