import AppKit
import CryptoKit
import Foundation
import WebKit

struct CarrachoPreparedMediaImage {
    var filename: String
    var data: Data
}

enum CarrachoMediaImageProcessor {
    static let maximumComposeDimension: CGFloat = 2048

    static func prepare(url: URL) throws -> CarrachoPreparedMediaImage {
        guard let image = NSImage(contentsOf: url) else { throw LegacyMediaClientError.invalidImage }
        return try prepare(image: image, suggestedFilename: url.lastPathComponent,
                           preferPNG: url.pathExtension.lowercased() == "png")
    }

    static func prepare(data: Data, suggestedFilename: String = "clipboard.png") throws -> CarrachoPreparedMediaImage {
        guard let image = NSImage(data: data) else { throw LegacyMediaClientError.invalidImage }
        return try prepare(image: image, suggestedFilename: suggestedFilename, preferPNG: true)
    }

    private static func prepare(image: NSImage, suggestedFilename: String, preferPNG: Bool) throws -> CarrachoPreparedMediaImage {
        guard image.size.width > 0, image.size.height > 0 else { throw LegacyMediaClientError.invalidImage }
        let scale = min(1, maximumComposeDimension / max(image.size.width, image.size.height))
        let size = NSSize(width: max(1, floor(image.size.width * scale)), height: max(1, floor(image.size.height * scale)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw LegacyMediaClientError.invalidImage }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor.clear.setFill(); NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()

        let stem = URL(fileURLWithPath: suggestedFilename).deletingPathExtension().lastPathComponent
        let safeStem = String((stem.isEmpty ? "image" : stem).prefix(220))
        if preferPNG, let png = bitmap.representation(using: .png, properties: [:]), png.count <= LegacyMediaTransfer.maximumImageBytes {
            return CarrachoPreparedMediaImage(filename: safeStem + ".png", data: png)
        }
        for quality in [0.88, 0.78, 0.68, 0.56] as [CGFloat] {
            if let jpg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpg.count <= LegacyMediaTransfer.maximumImageBytes {
                return CarrachoPreparedMediaImage(filename: safeStem + ".jpg", data: jpg)
            }
        }
        throw LegacyMediaClientError.invalidImage
    }
}

final class CarrachoYouTubeThumbnailCache {
    static let shared = CarrachoYouTubeThumbnailCache()

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: [() -> Void]] = [:]
    private var failures = Set<String>()

    func image(videoID: String) -> NSImage? {
        memory.object(forKey: videoID as NSString)
    }

    func request(videoID: String, completion: @escaping () -> Void) {
        if image(videoID: videoID) != nil || failures.contains(videoID) { return }
        if inFlight[videoID] != nil {
            inFlight[videoID, default: []].append(completion)
            return
        }
        inFlight[videoID] = [completion]

        guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg") else {
            failures.insert(videoID)
            inFlight.removeValue(forKey: videoID)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self else { return }
                if let image {
                    self.memory.setObject(image, forKey: videoID as NSString)
                } else {
                    self.failures.insert(videoID)
                }
                let callbacks = self.inFlight.removeValue(forKey: videoID) ?? []
                callbacks.forEach { $0() }
            }
        }.resume()
    }
}

final class CarrachoYouTubePreviewAttachmentCell: NSTextAttachmentCell {
    private let previewImage: NSImage?
    private let previewSize: NSSize

    init(previewImage: NSImage?, width: CGFloat) {
        self.previewImage = previewImage
        self.previewSize = NSSize(width: max(120, width), height: 200)
        super.init(textCell: "")
        isEnabled = false
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var cellSize: NSSize { previewSize }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let frame = cellFrame.integral
        let rounded = NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState()
        rounded.addClip()

        if let previewImage, previewImage.size.width > 0, previewImage.size.height > 0 {
            let imageRatio = previewImage.size.width / previewImage.size.height
            let frameRatio = frame.width / frame.height
            let source: NSRect
            if imageRatio > frameRatio {
                let sourceWidth = previewImage.size.height * frameRatio
                source = NSRect(x: (previewImage.size.width - sourceWidth) / 2,
                                y: 0,
                                width: sourceWidth,
                                height: previewImage.size.height)
            } else {
                let sourceHeight = previewImage.size.width / frameRatio
                source = NSRect(x: 0,
                                y: (previewImage.size.height - sourceHeight) / 2,
                                width: previewImage.size.width,
                                height: sourceHeight)
            }
            previewImage.draw(in: frame, from: source, operation: .sourceOver, fraction: 1,
                              respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            NSColor.controlBackgroundColor.setFill()
            frame.fill()
            let label = NSString(string: L("YouTube Preview"))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: CarrachoTheme.secondaryText,
            ]
            let labelSize = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: frame.midX - labelSize.width / 2,
                                   y: frame.midY - labelSize.height / 2 - 30),
                       withAttributes: attributes)
        }

        NSColor.black.withAlphaComponent(0.16).setFill()
        frame.fill(using: .sourceOver)

        let playDiameter: CGFloat = 58
        let playRect = NSRect(x: frame.midX - playDiameter / 2,
                              y: frame.midY - playDiameter / 2,
                              width: playDiameter,
                              height: playDiameter)
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(ovalIn: playRect).fill()

        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: playRect.midX - 7, y: playRect.midY - 11))
        triangle.line(to: NSPoint(x: playRect.midX - 7, y: playRect.midY + 11))
        triangle.line(to: NSPoint(x: playRect.midX + 12, y: playRect.midY))
        triangle.close()
        NSColor.white.setFill()
        triangle.fill()

        NSGraphicsContext.restoreGraphicsState()

        CarrachoTheme.hairline.setStroke()
        rounded.lineWidth = 1
        rounded.stroke()
    }
}

/// Lightweight overlay for a YouTube attachment. It stays transparent until the user clicks the
/// preview, then replaces only that preview with an embedded YouTube player. This avoids creating
/// dozens of WKWebViews for long chat transcripts while still keeping playback inside Carracho.
final class CarrachoYouTubeInlinePlayerView: NSView, WKNavigationDelegate {
    let videoID: String
    private var webView: WKWebView?

    init(videoID: String) {
        self.videoID = videoID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("YouTube Video"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if webView == nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard webView == nil else {
            super.mouseDown(with: event)
            return
        }
        startPlayback()
    }

    private static var embedReferrer: URL {
        if let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           let feedURL = URL(string: feed),
           let scheme = feedURL.scheme,
           let host = feedURL.host,
           let url = URL(string: "\(scheme)://\(host)/carracho/") {
            return url
        }
        return URL(string: "https://wired.istation.pw/carracho/")!
    }

    private func startPlayback() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let player = WKWebView(frame: bounds, configuration: configuration)
        player.navigationDelegate = self
        player.autoresizingMask = [.width, .height]
        player.translatesAutoresizingMaskIntoConstraints = false
        addSubview(player)
        NSLayoutConstraint.activate([
            player.leadingAnchor.constraint(equalTo: leadingAnchor),
            player.trailingAnchor.constraint(equalTo: trailingAnchor),
            player.topAnchor.constraint(equalTo: topAnchor),
            player.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        webView = player
        discardCursorRects()

        let referrer = Self.embedReferrer
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube-nocookie.com"
        components.path = "/embed/\(videoID)"
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "origin", value: "\(referrer.scheme ?? "https")://\(referrer.host ?? "wired.istation.pw")"),
            URLQueryItem(name: "widget_referrer", value: referrer.absoluteString),
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer")
        player.load(request)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The separate text link below the player is the deliberate route to youtube.com.
        // Keep popup targets and unrelated top-frame navigation out of the inline player.
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true,
           let host = navigationAction.request.url?.host?.lowercased(),
           host != "youtube-nocookie.com", host != "www.youtube-nocookie.com" {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

final class CarrachoMediaCache {
    private let memory = NSCache<NSString, NSImage>()
    private let root: URL
    private let namespace: String

    init(namespace: String) {
        self.namespace = namespace
        let hash = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        root = caches.appendingPathComponent("Carracho/Media/\(hash)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func image(id: UUID) -> NSImage? {
        let key = id.uuidString.lowercased() as NSString
        if let image = memory.object(forKey: key) { return image }
        let url = root.appendingPathComponent(id.uuidString.lowercased() + ".bin")
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    func store(_ content: LegacyMediaContent) {
        guard let image = NSImage(data: content.data) else { return }
        let key = content.id.uuidString.lowercased() as NSString
        memory.setObject(image, forKey: key)
        try? content.data.write(to: root.appendingPathComponent(content.id.uuidString.lowercased() + ".bin"), options: [.atomic])
    }

    func remove(id: UUID) {
        let key = id.uuidString.lowercased() as NSString
        memory.removeObject(forKey: key)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString.lowercased() + ".bin"))
    }
}

private enum CarrachoMediaPasteboard {
    static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let values = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        return values.map { $0 as URL }.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
    }

    static func bitmapData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }

        // Preview and other AppKit applications do not necessarily expose copied artwork as
        // a raw PNG/TIFF pasteboard item. Ask AppKit for the image first so PDF-backed,
        // JPEG-backed and other image representations can use the normal NSImage paste path.
        if let image = NSImage(pasteboard: pasteboard), let png = pngData(from: image) {
            return png
        }

        // Keep the explicit TIFF path as a compatibility fallback for older producers.
        if let tiff = pasteboard.data(forType: .tiff), let image = NSImage(data: tiff) {
            return pngData(from: image)
        }
        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        if let tiffData = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }

        let width = max(1, Int(ceil(image.size.width)))
        let height = max(1, Int(ceil(image.size.height)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: width,
                                            pixelsHigh: height,
                                            bitsPerSample: 8,
                                            samplesPerPixel: 4,
                                            hasAlpha: true,
                                            isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0,
                                            bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

final class CarrachoMediaComposerTextField: NSTextField, NSTextFieldDelegate {
    var imageFileHandler: (@MainActor ([URL]) -> Void)?
    var imageDataHandler: (@MainActor (Data) -> Void)?
    var mediaPastePayloadProvider: (() -> (urls: [URL], data: Data?))?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard NSStringFromSelector(commandSelector) == "paste:" else { return false }
        return handleMediaPasteboard(.general)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        return !CarrachoMediaPasteboard.imageFileURLs(from: pb).isEmpty || CarrachoMediaPasteboard.bitmapData(from: pb) != nil ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handleMediaPasteboard(sender.draggingPasteboard)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           handleMediaPasteboard(.general) { return true }
        return super.performKeyEquivalent(with: event)
    }
    @discardableResult private func handleMediaPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        let payload = mediaPastePayloadProvider?()
        let urls = payload?.urls ?? CarrachoMediaPasteboard.imageFileURLs(from: pasteboard)
        if !urls.isEmpty { imageFileHandler?(urls); return imageFileHandler != nil }
        let data = payload?.data ?? CarrachoMediaPasteboard.bitmapData(from: pasteboard)
        if let data { imageDataHandler?(data); return imageDataHandler != nil }
        return false
    }
}

final class CarrachoMediaComposerTextView: NSTextView {
    var imageFileHandler: (@MainActor ([URL]) -> Void)?
    var imageDataHandler: (@MainActor (Data) -> Void)?
    var youTubeURLHandler: (@MainActor (LegacyYouTubeReference) -> Bool)?
    var mediaPastePayloadProvider: (() -> (urls: [URL], data: Data?))?

    // NSTextContainer only keeps a weak link back to its layout manager. Retain the
    // programmatic text system here so an editor created with init(frame:) remains usable.
    private var retainedTextStorage: NSTextStorage?
    private var retainedLayoutManager: NSLayoutManager?

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        if let container, container.layoutManager != nil {
            super.init(frame: frameRect, textContainer: container)
        } else {
            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            let textContainer = container ?? NSTextContainer(
                containerSize: NSSize(width: max(frameRect.width, 1), height: .greatestFiniteMagnitude)
            )
            textStorage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(textContainer)
            retainedTextStorage = textStorage
            retainedLayoutManager = layoutManager
            super.init(frame: frameRect, textContainer: textContainer)
        }
        isEditable = true
        isSelectable = true
        allowsUndo = true
        applySystemInsertionPointColor()
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applySystemInsertionPointColor()
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySystemInsertionPointColor()
    }

    private func applySystemInsertionPointColor() {
        // Keep the caret aligned with the system text colour instead of the app/user accent.
        // NSColor.labelColor is dynamic, so it follows Light/Dark appearance automatically.
        insertionPointColor = .labelColor
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        return !CarrachoMediaPasteboard.imageFileURLs(from: pb).isEmpty || CarrachoMediaPasteboard.bitmapData(from: pb) != nil ? .copy : super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if handleMediaPasteboard(sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }
    override func paste(_ sender: Any?) {
        if handleMediaPasteboard(.general) { return }
        super.paste(sender)
    }
    @discardableResult private func handleMediaPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        let payload = mediaPastePayloadProvider?()
        let urls = payload?.urls ?? CarrachoMediaPasteboard.imageFileURLs(from: pasteboard)
        if !urls.isEmpty { imageFileHandler?(urls); return imageFileHandler != nil }
        let data = payload?.data ?? CarrachoMediaPasteboard.bitmapData(from: pasteboard)
        if let data { imageDataHandler?(data); return imageDataHandler != nil }
        if let value = pasteboard.string(forType: .string),
           let reference = LegacyYouTubeReference(urlString: value),
           let youTubeURLHandler,
           youTubeURLHandler(reference) {
            return true
        }
        return false
    }
}


extension NSAttributedString.Key {
    static let carrachoMediaID = NSAttributedString.Key("CarrachoMediaID")
    static let carrachoYouTubeVideoID = NSAttributedString.Key("CarrachoYouTubeVideoID")
    static let carrachoQuoteBlock = NSAttributedString.Key("CarrachoQuoteBlock")
    static let carrachoPostBackground = NSAttributedString.Key("CarrachoPostBackground")
    static let carrachoToolTipText = NSAttributedString.Key("CarrachoToolTipText")
    static let carrachoPostSeparator = NSAttributedString.Key("CarrachoPostSeparator")
}

private final class CarrachoInlineHoverCardView: NSView {
    var mouseEnteredHandler: (() -> Void)?
    var mouseExitedHandler: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
    }

    private func configureAppearance() {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        refreshAppearance()
    }

    private func refreshAppearance() {
        layer?.backgroundColor = CarrachoTheme.cardColor(for: effectiveAppearance).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        mouseEnteredHandler?()
    }

    override func mouseExited(with event: NSEvent) {
        mouseExitedHandler?()
    }
}

/// Read-only rich-content view that exposes owner deletion from the image's context menu.
/// The server remains authoritative about ownership; a forged/foreign UUID is rejected there.
final class CarrachoMediaDisplayTextView: NSTextView, NSTextViewDelegate {
    var mediaDeleteHandler: ((UUID) -> Void)?
    private var youtubePlayers: [String: CarrachoYouTubeInlinePlayerView] = [:]
    private var youtubePlayerSyncScheduled = false
    private var inlineToolTipSyncScheduled = false
    private var inlineHoverTrackingAreas: [NSTrackingArea] = []
    private var inlineHoverWindow: NSPanel?
    private var inlineHoverCloseWorkItem: DispatchWorkItem?
    private var inlineHoverAnchorRect: NSRect?
    /// Handles app-private links embedded in rich display content. Returning true consumes the click;
    /// normal web links keep their standard NSTextView behavior.
    var appLinkHandler: ((Any) -> Bool)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCarrachoDecorations(in: dirtyRect)
        super.draw(dirtyRect)
        scheduleYouTubePlayerSync()
        scheduleInlineToolTipSync()
    }

    override func layout() {
        super.layout()
        scheduleYouTubePlayerSync()
        scheduleInlineToolTipSync()
    }

    private func scheduleYouTubePlayerSync() {
        guard !youtubePlayerSyncScheduled else { return }
        youtubePlayerSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.youtubePlayerSyncScheduled = false
            self.syncYouTubePlayers()
        }
    }

    private func scheduleInlineToolTipSync() {
        guard !inlineToolTipSyncScheduled else { return }
        inlineToolTipSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inlineToolTipSyncScheduled = false
            self.syncInlineToolTips()
        }
    }

    private func syncInlineToolTips() {
        for area in inlineHoverTrackingAreas { removeTrackingArea(area) }
        inlineHoverTrackingAreas.removeAll(keepingCapacity: true)
        guard let storage = textStorage, storage.length > 0,
              let layoutManager, let textContainer else {
            closeInlineHoverPopover()
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.carrachoToolTipText, in: fullRange) { [weak self] value, characterRange, _ in
            guard let self, let text = value as? String, !text.isEmpty else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                guard !rect.isEmpty else { return }
                let viewRect = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -1)
                let area = NSTrackingArea(
                    rect: viewRect,
                    options: [.mouseEnteredAndExited, .activeInKeyWindow],
                    owner: self,
                    userInfo: ["carrachoInlineHoverText": text]
                )
                self.addTrackingArea(area)
                self.inlineHoverTrackingAreas.append(area)
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let area = event.trackingArea,
              inlineHoverTrackingAreas.contains(where: { $0 === area }),
              let text = area.userInfo?["carrachoInlineHoverText"] as? String,
              !text.isEmpty else {
            super.mouseEntered(with: event)
            return
        }
        inlineHoverCloseWorkItem?.cancel()
        inlineHoverCloseWorkItem = nil
        showInlineHoverPopover(text: text, relativeTo: area.rect)
    }

    override func mouseExited(with event: NSEvent) {
        guard let area = event.trackingArea,
              inlineHoverTrackingAreas.contains(where: { $0 === area }) else {
            super.mouseExited(with: event)
            return
        }
        scheduleInlineHoverPopoverClose()
    }

    private func showInlineHoverPopover(text: String, relativeTo anchorRect: NSRect) {
        inlineHoverAnchorRect = anchorRect
        guard let parentWindow = window else { return }

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let font = label.font ?? .systemFont(ofSize: 12)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let width = min(300, max(150, ceil(measured.width) + 20))
        let height = max(34, ceil(measured.height) + 16)

        let content = CarrachoInlineHoverCardView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        content.mouseEnteredHandler = { [weak self] in
            self?.inlineHoverCloseWorkItem?.cancel()
            self?.inlineHoverCloseWorkItem = nil
        }
        content.mouseExitedHandler = { [weak self] in
            self?.scheduleInlineHoverPopoverClose()
        }

        closeInlineHoverWindowOnly()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.collectionBehavior = [.transient, .ignoresCycle]

        let anchorInWindow = convert(anchorRect, to: nil)
        let anchorOnScreen = parentWindow.convertToScreen(anchorInWindow)
        let visibleFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchorOnScreen
        let gap: CGFloat = 6
        var x = anchorOnScreen.midX - width / 2
        x = min(max(x, visibleFrame.minX + 4), visibleFrame.maxX - width - 4)

        var y = anchorOnScreen.maxY + gap
        if y + height > visibleFrame.maxY - 4 {
            y = anchorOnScreen.minY - height - gap
        }
        y = min(max(y, visibleFrame.minY + 4), visibleFrame.maxY - height - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        parentWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        inlineHoverWindow = panel
    }

    private func scheduleInlineHoverPopoverClose() {
        inlineHoverCloseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.mouseIsOverInlineHoverAnchorOrPopover() else { return }
            self.closeInlineHoverPopover()
        }
        inlineHoverCloseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func mouseIsOverInlineHoverAnchorOrPopover() -> Bool {
        let mouse = NSEvent.mouseLocation
        if let anchorRect = inlineHoverAnchorRect, let window {
            let inWindow = convert(anchorRect, to: nil)
            if window.convertToScreen(inWindow).contains(mouse) { return true }
        }
        if let inlineHoverWindow, inlineHoverWindow.frame.contains(mouse) {
            return true
        }
        return false
    }

    private func closeInlineHoverWindowOnly() {
        guard let hoverWindow = inlineHoverWindow else { return }
        hoverWindow.parent?.removeChildWindow(hoverWindow)
        hoverWindow.orderOut(nil)
        hoverWindow.close()
        inlineHoverWindow = nil
    }

    private func closeInlineHoverPopover() {
        inlineHoverCloseWorkItem?.cancel()
        inlineHoverCloseWorkItem = nil
        inlineHoverAnchorRect = nil
        closeInlineHoverWindowOnly()
    }

    private func syncYouTubePlayers() {
        guard let storage = textStorage, let layoutManager, let textContainer else {
            youtubePlayers.values.forEach { $0.removeFromSuperview() }
            youtubePlayers.removeAll()
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        let fullRange = NSRange(location: 0, length: storage.length)
        var activeKeys = Set<String>()
        var occurrences: [String: Int] = [:]

        storage.enumerateAttribute(.carrachoYouTubeVideoID, in: fullRange) { value, characterRange, _ in
            guard let videoID = value as? String, !videoID.isEmpty else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            var frame = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard frame.width > 20, frame.height > 20 else { return }
            frame = frame.offsetBy(dx: origin.x, dy: origin.y).integral

            let occurrence = occurrences[videoID, default: 0]
            occurrences[videoID] = occurrence + 1
            let key = "\(videoID):\(occurrence)"
            activeKeys.insert(key)
            let player: CarrachoYouTubeInlinePlayerView
            if let existing = youtubePlayers[key], existing.videoID == videoID {
                player = existing
            } else {
                youtubePlayers[key]?.removeFromSuperview()
                player = CarrachoYouTubeInlinePlayerView(videoID: videoID)
                youtubePlayers[key] = player
                addSubview(player)
            }
            if player.frame != frame { player.frame = frame }
        }

        let staleKeys = youtubePlayers.keys.filter { !activeKeys.contains($0) }
        for key in staleKeys {
            youtubePlayers.removeValue(forKey: key)?.removeFromSuperview()
        }
    }

    private func drawCarrachoDecorations(in dirtyRect: NSRect) {
        guard let storage = textStorage, storage.length > 0,
              let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        let fullRange = NSRange(location: 0, length: storage.length)

        storage.enumerateAttribute(.carrachoPostBackground, in: fullRange) { value, characterRange, _ in
            guard let alternate = value as? Bool else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            var contentRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard !contentRect.isEmpty else { return }
            contentRect = contentRect.offsetBy(dx: origin.x, dy: origin.y)
            let block = NSRect(x: bounds.minX, y: contentRect.minY - 6,
                               width: bounds.width, height: contentRect.height + 12)
            guard block.intersects(dirtyRect) else { return }
            let color = alternate ? CarrachoTheme.stripedRowAlternateBackground : CarrachoTheme.stripedRowBackground
            color.setFill()
            block.fill()
        }

        storage.enumerateAttribute(.carrachoQuoteBlock, in: fullRange) { value, characterRange, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            var contentRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard !contentRect.isEmpty else { return }
            contentRect = contentRect.offsetBy(dx: origin.x, dy: origin.y)

            let horizontalInset: CGFloat = 7
            let left = origin.x + horizontalInset
            let right = max(left + 40, bounds.width - origin.x - horizontalInset)
            let box = NSRect(x: left, y: contentRect.minY - 6,
                             width: right - left, height: contentRect.height + 12)
            guard box.intersects(dirtyRect) else { return }

            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            CarrachoTheme.selectionSoft.withAlphaComponent(0.62).setFill()
            path.fill()
            CarrachoTheme.hairline.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        storage.enumerateAttribute(.carrachoPostSeparator, in: fullRange) { value, characterRange, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            var effective = NSRange()
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: &effective)
                .offsetBy(dx: origin.x, dy: origin.y)
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            // Exactly two device pixels, independent of Retina/non-Retina backing scale.
            let thickness = 2 / max(1, scale)
            let y = floor((line.midY - thickness / 2) * scale) / scale
            let separator = NSRect(x: bounds.minX, y: y,
                                   width: bounds.width, height: thickness)
            guard separator.intersects(dirtyRect) else { return }
            CarrachoTheme.hairline.setFill()
            separator.fill()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if delegate == nil { delegate = self }
        if window == nil { closeInlineHoverPopover() }
        scheduleYouTubePlayerSync()
        scheduleInlineToolTipSync()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        appLinkHandler?(link) == true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let id = mediaID(at: event) else { return menu }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(title: L("Delete My Image…"), action: #selector(deleteMediaFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id.uuidString.lowercased()
        menu.addItem(item)
        return menu
    }

    private func mediaID(at event: NSEvent) -> UUID? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard glyphRect.insetBy(dx: -4, dy: -4).contains(local) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length,
              let text = storage.attribute(.carrachoMediaID, at: character, effectiveRange: nil) as? String,
              let id = UUID(uuidString: text) else { return nil }
        return id
    }

    @objc private func deleteMediaFromMenu(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text) else { return }
        mediaDeleteHandler?(id)
    }
}

final class CarrachoComposerAttachmentStrip: NSView {
    private enum Kind {
        case image(id: UUID, preview: NSImage, filename: String)
        case youtube(LegacyYouTubeReference)

        var token: String {
            switch self {
            case let .image(id, _, _): return LegacyMediaReference.token(for: id)
            case let .youtube(reference): return reference.token
            }
        }
    }

    private struct Item {
        let key = UUID()
        let kind: Kind
    }

    var onChange: (() -> Void)?
    var onRemoveImage: ((UUID) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let document = NSView()
    private var items: [Item] = []

    override var intrinsicContentSize: NSSize {
        // Do not reserve an invisible 68 pt attachment strip in composers that have no media.
        // NSStackView can otherwise leave a large blank band above the editor even though the
        // strip itself is hidden. It grows back to its normal height as soon as an item exists.
        NSSize(width: NSView.noIntrinsicMetric, height: items.isEmpty ? 0 : 68)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        document.addSubview(stack)
        scrollView.documentView = document
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: document.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var imageCount: Int {
        items.reduce(0) { count, item in
            if case .image = item.kind { return count + 1 }
            return count
        }
    }

    var youtubeCount: Int {
        items.reduce(0) { count, item in
            if case .youtube = item.kind { return count + 1 }
            return count
        }
    }

    var tokens: [String] { items.map(\.kind.token) }

    func addImage(id: UUID, prepared: CarrachoPreparedMediaImage) {
        guard let preview = NSImage(data: prepared.data) else { return }
        items.append(Item(kind: .image(id: id, preview: preview, filename: prepared.filename)))
        reload()
    }

    /// Adds an image that is already stored on the server. Edit composers use this to make
    /// existing post attachments removable without re-uploading them.
    func addExistingImage(id: UUID, preview: NSImage?, filename: String = L("Posted image")) {
        let fallback = NSImage(size: NSSize(width: 48, height: 48))
        items.append(Item(kind: .image(id: id, preview: preview ?? fallback, filename: filename)))
        reload()
    }

    var imageIDs: [UUID] {
        items.compactMap { item in
            if case let .image(id, _, _) = item.kind { return id }
            return nil
        }
    }

    func addYouTube(_ reference: LegacyYouTubeReference) {
        guard !items.contains(where: {
            if case let .youtube(existing) = $0.kind { return existing.videoID == reference.videoID }
            return false
        }) else { return }
        items.append(Item(kind: .youtube(reference)))
        reload()
    }

    func clear() {
        items.removeAll()
        reload()
    }

    private func reload() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for item in items { stack.addArrangedSubview(makeChip(item)) }
        isHidden = items.isEmpty
        invalidateIntrinsicContentSize()
        onChange?()
    }

    private func makeChip(_ item: Item) -> NSView {
        let chip = NSView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 8
        chip.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.separatorColor.cgColor

        let remove = CarrachoClosureButton(title: "×")
        remove.toolTip = L("Remove attachment")
        remove.bezelStyle = .inline
        remove.isBordered = false
        remove.font = .systemFont(ofSize: 15, weight: .semibold)
        remove.handler = { [weak self] in
            guard let self else { return }
            if case let .image(id, _, _) = item.kind { self.onRemoveImage?(id) }
            self.items.removeAll { $0.key == item.key }
            self.reload()
        }

        let content: NSView
        switch item.kind {
        case let .image(_, preview, filename):
            let image = NSImageView()
            image.image = preview
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: 48),
                image.heightAnchor.constraint(equalToConstant: 48),
            ])
            let label = NSTextField(labelWithString: filename)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 2
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
            content = horizontal([image, label, remove], spacing: 6)
        case let .youtube(reference):
            let icon = NSImageView()
            if #available(macOS 11.0, *) {
                icon.image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "YouTube")
                icon.contentTintColor = .systemRed
            }
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 22),
            ])
            let label = NSTextField(labelWithString: "\(L("YouTube"))\n\(reference.videoID)")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.maximumNumberOfLines = 2
            content = horizontal([icon, label, remove], spacing: 6)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 7),
            content.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -7),
            content.topAnchor.constraint(equalTo: chip.topAnchor, constant: 5),
            content.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -5),
            chip.heightAnchor.constraint(equalToConstant: 58),
        ])
        return chip
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let value = NSStackView(views: views)
        value.orientation = .horizontal
        value.alignment = .centerY
        value.spacing = spacing
        return value
    }
}

final class CarrachoClosureTarget: NSObject {
    private let handler: (Any?) -> Void

    init(_ handler: @escaping (Any?) -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) {
        handler(sender)
    }
}

final class CarrachoClosureButton: NSButton {
    var handler: (() -> Void)?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); target = self; action = #selector(trigger) }
    convenience init(title: String) { self.init(frame: .zero); self.title = title; bezelStyle = .rounded }
    required init?(coder: NSCoder) { super.init(coder: coder); target = self; action = #selector(trigger) }
    @objc private func trigger() { handler?() }
}
