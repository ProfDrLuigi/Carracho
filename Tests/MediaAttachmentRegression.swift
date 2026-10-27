import Cocoa
import ImageIO
@preconcurrency import Network
@testable import Carracho

@MainActor func runRegression() throws {
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        precondition(condition(), "Attachment operation must finish instead of hanging")
    }
    @MainActor func awaitResult<T>(_ operation: @MainActor (@escaping @MainActor @Sendable (Result<T, Error>) -> Void) -> Void) throws -> T {
        var result: Result<T, Error>?
        operation { precondition(Thread.isMainThread); result = $0 }
        waitUntil { result != nil }
        return try result!.get()
    }
    func encodedImage(width: Int, height: Int, type: String, orientation: Int = 1, noisy: Bool = false) -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 12345
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if noisy { seed = seed &* 1664525 &+ 1013904223 }
            pixels[index] = noisy ? UInt8(truncatingIfNeeded: seed >> 24) : 32
            pixels[index + 1] = noisy ? UInt8(truncatingIfNeeded: seed >> 16) : 96
            pixels[index + 2] = noisy ? UInt8(truncatingIfNeeded: seed >> 8) : 192
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
    func dimensions(_ data: Data) -> (Int, Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        return (image.width, image.height)
    }
    let screenshot = encodedImage(width: 4096, height: 2048, type: "public.png", noisy: true)
    let url = root.appendingPathComponent("Screenshot.png")
    try screenshot.write(to: url)
    var heartbeats = 0
    let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in heartbeats += 1 }
    let images: [CarrachoPreparedMediaImage] = try awaitResult {
        CarrachoMediaImageProcessor.prepare(urls: Array(repeating: url, count: 4), completion: $0)
    }
    timer.invalidate()
    precondition(heartbeats > 0, "UI run loop must remain responsive during screenshot preparation")
    precondition(images.count == 4)
    for image in images {
        let size = dimensions(image.data)
        precondition(size.0 == 2048 && size.1 == 1024)
        precondition(!image.data.isEmpty && image.data.count <= LegacyMediaTransfer.maximumImageBytes)
    }
    let clipboard = encodedImage(width: 320, height: 160, type: "public.tiff")
    let pasted: CarrachoPreparedMediaImage = try awaitResult { CarrachoMediaImageProcessor.prepare(data: clipboard, completion: $0) }
    precondition(dimensions(pasted.data) == (320, 160), "Small clipboard images must not be upscaled")
    let rotated = encodedImage(width: 320, height: 160, type: "public.jpeg", orientation: 6)
    let oriented: CarrachoPreparedMediaImage = try awaitResult { CarrachoMediaImageProcessor.prepare(data: rotated, completion: $0) }
    precondition(dimensions(oriented.data) == (160, 320), "Image orientation must be preserved")
    var invalidFinished = false
    CarrachoMediaImageProcessor.prepare(data: Data([0, 1, 2])) { result in
        if case .success = result { fatalError("Invalid image accepted") }
        invalidFinished = true
    }
    waitUntil { invalidFinished }
    
    // A News editor is itself a sheet. Its image picker must attach to that editor,
    // not become an unrelated modal panel that leaves the original editor blocked.
    let controller = ViewController(nibName: nil, bundle: nil)
    controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let window = NSWindow(contentRect: controller.view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = controller.view
    window.orderFront(nil)
    let editor = NSAlert()
    editor.messageText = "Attachment picker regression"
    editor.addButton(withTitle: "Cancel")
    editor.beginSheetModal(for: window)
    waitUntil { window.attachedSheet === editor.window }
    var picked = false
    controller.chooseMediaImages(maximum: 1, for: editor.window) { _ in picked = true }
    waitUntil { editor.window.attachedSheet is NSOpenPanel }
    (editor.window.attachedSheet as! NSOpenPanel).cancel(nil)
    waitUntil { editor.window.attachedSheet == nil }
    precondition(!picked, "Cancelling the image picker must not start an upload")
    window.endSheet(editor.window)
    window.orderOut(nil)

    // The prepared images must remain compatible with the actual encrypted media protocol.
    var store = ServerStateStore(url: root.appendingPathComponent("server/db/server.db"))
    store.passwordIterations = 1000
    let backend = try ModernServerBackend(store: store)
    _ = try backend.createAccount(ServerAccount(login: "attachment-test", name: "Attachment Test", mode: .administrator,
                                                permissions: Set(ServerPermission.allCases)), password: "test-password")
    _ = try backend.createNewsgroup(ServerNewsgroup(name: "Attachment Regression"))
    let server = LegacyServerRuntime(backend: backend, storageRoot: root.appendingPathComponent("server/Files"),
                                    supportRoot: root.appendingPathComponent("server"), databaseRoot: root.appendingPathComponent("server/db"))
    let port = try server.start(port: 0)
    defer { server.stop() }
    let client = LegacyControlClient()
    let login: LegacyLoginResult = try awaitResult {
        client.connect(host: "127.0.0.1", port: port, login: "attachment-test", password: "test-password", nickname: "Attachment Test", completion: $0)
    }
    defer { client.disconnect() }
    let media = try LegacyMediaClient(host: "127.0.0.1", controlPort: port, session: client.transferSession!)
    for item in [images[0], pasted, oriented] {
        let id: UUID = try awaitResult { media.upload(filename: item.filename, data: item.data, completion: $0) }
        let downloaded: LegacyMediaContent = try awaitResult { media.download(id: id, context: .pending, completion: $0) }
        precondition(downloaded.data == item.data)
        let _: Void = try awaitResult { media.delete(id: id, completion: $0) }
    }
    let pmImage: UUID = try awaitResult { media.upload(filename: pasted.filename, data: pasted.data, completion: $0) }
    let _: Void = try awaitResult {
        client.sendPrivateMessage(to: login.session.userID, message: Data(LegacyMediaReference.token(for: pmImage).utf8), completion: $0)
    }
    let newsImage: UUID = try awaitResult { media.upload(filename: pasted.filename, data: pasted.data, completion: $0) }
    let news = try LegacyNewsClient(host: "127.0.0.1", controlPort: port, session: client.transferSession!)
    let _: Void = try awaitResult {
        news.postArticle(group: Data("Attachment Regression".utf8), subject: Data("Screenshot".utf8),
                         text: Data(LegacyMediaReference.token(for: newsImage).utf8), completion: $0)
    }

    // A server that accepts the upload but never acknowledges it must time out,
    // with the UI run loop still running. This matches the reported upload stage.
    let listener = try NWListener(using: .tcp, on: .any)
    var accepted: [NWConnection] = []
    listener.newConnectionHandler = { connection in
        DispatchQueue.main.async {
            accepted.append(connection)
            connection.start(queue: .main)
            // Deliberately send no upload acknowledgement.
        }
    }
    var ready = false
    listener.stateUpdateHandler = { state in
        DispatchQueue.main.async { if case .ready = state { ready = true } }
    }
    listener.start(queue: .main)
    waitUntil { ready }
    defer { listener.cancel(); accepted.forEach { $0.cancel() } }
    let silentMedia = try LegacyMediaClient(host: "127.0.0.1", controlPort: listener.port!.rawValue - 1,
                                          session: client.transferSession!)
    var stalledResult: Result<UUID, Error>?
    var waitingHeartbeats = 0
    let waitingTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in waitingHeartbeats += 1 }
    silentMedia.upload(filename: pasted.filename, data: pasted.data) { stalledResult = $0 }
    waitUntil(timeout: 30) { stalledResult != nil }
    waitingTimer.invalidate()
    guard case .failure = stalledResult else { fatalError("Unacknowledged upload unexpectedly succeeded") }
    precondition(waitingHeartbeats > 0, "Waiting for upload completion must not freeze the UI")
    print("PASS: responsive screenshot preparation, clipboard TIFF, orientation, size limits, invalid input, encrypted upload/download, nested News picker, PM/News sending and stalled-upload timeout")
}
try MainActor.assumeIsolated { try runRegression() }
