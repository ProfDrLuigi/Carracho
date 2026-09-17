#if CARRACHO_SERVER
import AppKit
import Foundation
import Darwin

struct CarrachoServerBotStatus: Codable, Equatable {
    var pid: Int32
    var updatedAt: Date
    var connected: Bool
    var pipePath: String
    var lastError: String?
}

private struct CarrachoServerBotConfiguration: Codable {
    var enabled: Bool = false
    /// nil preserves pre-1.0.1 persisted account artwork; an empty string explicitly selects no avatar.
    var avatarPath: String? = nil
    /// Optional for compatibility with bot configuration files created before greeting support.
    var greetNewUsers: Bool? = nil
    var greetingTemplate: String? = nil
    /// Optional for compatibility with configuration files created before command rules.
    var commandRules: [LegacyBotCommandRule]? = nil
}

enum CarrachoServerBotError: LocalizedError {
    case pipePathOccupied(String)
    case fifo(String)
    case invalidInput
    case invalidAvatar(String)

    var errorDescription: String? {
        switch self {
        case let .pipePathOccupied(path):
            return LF("The Bot interface cannot use %@ because another file already exists there.", path)
        case let .fifo(message):
            return LF("The Bot interface could not be opened: %@", message)
        case .invalidInput:
            return L("The Bot interface received text that is not valid UTF-8.")
        case let .invalidAvatar(message):
            return message
        }
    }
}


enum CarrachoServerBotAvatar {
    static let relativePath = "etc/carracho-bot-avatar.png"
    static let pixelSize = 128
    static let maximumWireBytes = Int(UInt16.max)

    static func url(rootURL: URL) -> URL {
        rootURL.standardizedFileURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    static func validatePNG(_ data: Data) throws {
        guard data.count <= maximumWireBytes else {
            throw CarrachoServerBotError.invalidAvatar(
                LF("The Bot avatar is too large for the protocol (%@ bytes).", String(data.count)))
        }
        guard data.count >= 24,
              data.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
              data[12..<16] == Data("IHDR".utf8) else {
            throw CarrachoServerBotError.invalidAvatar(L("The Bot avatar must be a valid PNG image."))
        }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard width == pixelSize, height == pixelSize else {
            throw CarrachoServerBotError.invalidAvatar(L("The Bot avatar must be 128 × 128 pixels."))
        }
    }

    static func normalizedPNG(from url: URL) throws -> Data {
        guard url.pathExtension.lowercased() == "png", let image = NSImage(contentsOf: url) else {
            throw CarrachoServerBotError.invalidAvatar(L("Please choose a PNG image."))
        }
        let width = image.size.width, height = image.size.height
        guard width > 0, height > 0 else {
            throw CarrachoServerBotError.invalidAvatar(L("The PNG image could not be read."))
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: pixelSize, pixelsHigh: pixelSize,
                                             bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB,
                                             bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CarrachoServerBotError.invalidAvatar(L("The Bot avatar could not be rendered."))
        }
        bitmap.size = NSSize(width: pixelSize, height: pixelSize)
        let side = min(width, height)
        let source = NSRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
        let destination = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Keep transparent source pixels transparent. Filling the destination with an opaque
        // background here permanently flattened PNG alpha and produced a light circle around
        // Bot avatars once the client applied its normal circular avatar presentation.
        context.cgContext.clear(destination)
        image.draw(in: destination, from: source, operation: .sourceOver, fraction: 1,
                   respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CarrachoServerBotError.invalidAvatar(L("The Bot avatar could not be rendered."))
        }
        try validatePNG(png)
        return png
    }
}

/// Bridges a local named pipe into the Public conference through the server runtime's synthetic
/// Bot user. The desired state is persisted under the server root so the same control also works
/// when the listener is running in the launchd system-service process.
final class CarrachoServerBotController {
    let rootURL: URL
    let runtime: LegacyServerRuntime
    let pipeURL: URL

    private let queue = DispatchQueue(label: "com.carracho.server.bot", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var serverActive = false
    private var pipeSource: DispatchSourceRead?
    private var pipeFD: Int32 = -1
    private var readBuffer = Data()
    private var lastError: String?

    init(rootURL: URL, runtime: LegacyServerRuntime) {
        self.rootURL = rootURL.standardizedFileURL
        self.runtime = runtime
        self.pipeURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Bot", isDirectory: false)
    }

    deinit {
        timer?.cancel()
        pipeSource?.cancel()
    }

    static func configurationURL(rootURL: URL) -> URL {
        rootURL.standardizedFileURL
            .appendingPathComponent("etc", isDirectory: true)
            .appendingPathComponent("carracho-bot.json", isDirectory: false)
    }

    static func statusURL(rootURL: URL) -> URL {
        rootURL.standardizedFileURL
            .appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent("bot-status.json", isDirectory: false)
    }

    private static func configuration(rootURL: URL) throws -> CarrachoServerBotConfiguration {
        let url = configurationURL(rootURL: rootURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return CarrachoServerBotConfiguration() }
        return try JSONDecoder().decode(CarrachoServerBotConfiguration.self, from: Data(contentsOf: url))
    }

    private static func writeConfiguration(_ value: CarrachoServerBotConfiguration, rootURL: URL) throws {
        let url = configurationURL(rootURL: rootURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func desiredEnabled(rootURL: URL) -> Bool {
        (try? configuration(rootURL: rootURL).enabled) ?? false
    }

    static func setDesiredEnabled(_ enabled: Bool, rootURL: URL) throws {
        var value = try configuration(rootURL: rootURL)
        value.enabled = enabled
        try writeConfiguration(value, rootURL: rootURL)
    }

    static func greetingConfiguration(rootURL: URL) -> (enabled: Bool, template: String) {
        guard let value = try? configuration(rootURL: rootURL) else {
            return (false, LegacyBotAdminStatus.defaultGreetingTemplate)
        }
        let template = value.greetingTemplate?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value.greetNewUsers ?? false,
                template?.isEmpty == false ? template! : LegacyBotAdminStatus.defaultGreetingTemplate)
    }

    static func setGreeting(enabled: Bool, template: String, rootURL: URL) throws {
        let normalized = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 512,
              !normalized.contains("\n"), !normalized.contains("\r") else {
            throw ServerStateError.invalidValue(L("The Bot greeting must be one non-empty line of at most 512 UTF-8 bytes."))
        }
        var value = try configuration(rootURL: rootURL)
        value.greetNewUsers = enabled
        value.greetingTemplate = normalized
        try writeConfiguration(value, rootURL: rootURL)
    }

    static func configuredAvatarPath(rootURL: URL) -> String? {
        try? configuration(rootURL: rootURL).avatarPath
    }

    static func configuredAvatarData(rootURL: URL) -> Data? {
        guard let value = try? configuration(rootURL: rootURL),
              value.avatarPath == CarrachoServerBotAvatar.relativePath,
              let data = try? Data(contentsOf: CarrachoServerBotAvatar.url(rootURL: rootURL)),
              (try? CarrachoServerBotAvatar.validatePNG(data)) != nil else { return nil }
        return data
    }

    static func setAvatarData(_ data: Data?, rootURL: URL) throws {
        var value = try configuration(rootURL: rootURL)
        let avatarURL = CarrachoServerBotAvatar.url(rootURL: rootURL)
        if let data {
            try CarrachoServerBotAvatar.validatePNG(data)
            try FileManager.default.createDirectory(at: avatarURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: avatarURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: avatarURL.path)
            value.avatarPath = CarrachoServerBotAvatar.relativePath
        } else {
            if FileManager.default.fileExists(atPath: avatarURL.path) { try FileManager.default.removeItem(at: avatarURL) }
            value.avatarPath = ""
        }
        try writeConfiguration(value, rootURL: rootURL)
    }

    static func currentStatus(rootURL: URL) -> CarrachoServerBotStatus? {
        let url = statusURL(rootURL: rootURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(CarrachoServerBotStatus.self, from: data),
              Date().timeIntervalSince(value.updatedAt) < 3.5 else { return nil }
        return value
    }

    func serverDidStart() {
        queue.async { [weak self] in
            guard let self else { return }
            serverActive = true
            startTimerIfNeeded()
            reconcile()
        }
    }

    func serverWillStop() {
        queue.sync {
            let wasActive = serverActive
            serverActive = false
            timer?.cancel()
            timer = nil
            stopPipe()
            runtime.disconnectLocalBot()
            if wasActive { writeStatus(connected: false) }
        }
    }

    func desiredStateChanged() {
        queue.async { [weak self] in self?.reconcile() }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.25, repeating: 0.75, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.reconcile() }
        timer = source
        source.resume()
    }

    private func reconcile() {
        guard serverActive, runtime.status.isRunning else {
            writeStatus(connected: false)
            return
        }

        let configuration: CarrachoServerBotConfiguration
        do { configuration = try Self.configuration(rootURL: rootURL) }
        catch {
            lastError = L("Bot configuration is invalid or unreadable.")
            stopPipe(); runtime.disconnectLocalBot(); writeStatus(connected: false); return
        }
        let enabled = configuration.enabled
        var avatarError: String?
        do {
            if let avatarPath = configuration.avatarPath {
                if avatarPath.isEmpty {
                    try runtime.updateLocalBotAvatar(nil)
                } else if avatarPath == CarrachoServerBotAvatar.relativePath {
                    let data = try Data(contentsOf: CarrachoServerBotAvatar.url(rootURL: rootURL))
                    try CarrachoServerBotAvatar.validatePNG(data)
                    try runtime.updateLocalBotAvatar(data)
                } else {
                    throw CarrachoServerBotError.invalidAvatar(L("The Bot avatar path in carracho-bot.json is not supported."))
                }
            }
        } catch {
            avatarError = error.localizedDescription
        }
        if enabled {
            do {
                if pipeSource == nil { try startPipe() }
                if !runtime.isLocalBotConnected { try runtime.connectLocalBot() }
                lastError = avatarError
            } catch {
                lastError = error.localizedDescription
                stopPipe()
                runtime.disconnectLocalBot()
            }
        } else {
            stopPipe()
            runtime.disconnectLocalBot()
            lastError = nil
        }
        writeStatus(connected: enabled && runtime.isLocalBotConnected && pipeSource != nil)
    }

    private func startPipe() throws {
        let path = pipeURL.path
        var info = stat()
        let exists = path.withCString { lstat($0, &info) == 0 }
        if exists {
            guard (info.st_mode & S_IFMT) == S_IFIFO else {
                throw CarrachoServerBotError.pipePathOccupied(path)
            }
            _ = path.withCString { unlink($0) }
        } else if errno != ENOENT {
            throw CarrachoServerBotError.fifo(String(cString: strerror(errno)))
        }

        let makeResult = path.withCString { mkfifo($0, mode_t(0o600)) }
        guard makeResult == 0 else {
            throw CarrachoServerBotError.fifo(String(cString: strerror(errno)))
        }

        let fd = path.withCString { open($0, O_RDWR | O_NONBLOCK) }
        guard fd >= 0 else {
            let message = String(cString: strerror(errno))
            _ = path.withCString { unlink($0) }
            throw CarrachoServerBotError.fifo(message)
        }
        _ = path.withCString { chmod($0, mode_t(0o600)) }

        pipeFD = fd
        readBuffer.removeAll(keepingCapacity: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainPipe() }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        pipeSource = source
        source.resume()
    }

    private func stopPipe() {
        if let source = pipeSource {
            pipeSource = nil
            pipeFD = -1
            source.cancel()
        }
        readBuffer.removeAll(keepingCapacity: false)
        removePipeIfFIFO()
    }

    private func removePipeIfFIFO() {
        let path = pipeURL.path
        var info = stat()
        guard path.withCString({ lstat($0, &info) == 0 }), (info.st_mode & S_IFMT) == S_IFIFO else { return }
        _ = path.withCString { unlink($0) }
    }

    private func drainPipe() {
        guard pipeFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(pipeFD, &buffer, buffer.count)
            if count > 0 {
                readBuffer.append(contentsOf: buffer.prefix(count))
                if readBuffer.count > 128 * 1024 {
                    readBuffer.removeAll(keepingCapacity: true)
                    lastError = L("The Bot interface discarded an oversized input line.")
                    break
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            lastError = LF("The Bot interface could not be read: %@", String(cString: strerror(errno)))
            break
        }
        processCompleteLines()
    }

    private func processCompleteLines() {
        while let newline = readBuffer.firstIndex(of: 0x0a) {
            var line = Data(readBuffer[..<newline])
            readBuffer.removeSubrange(...newline)
            if line.last == 0x0d { line.removeLast() }
            guard !line.isEmpty else { continue }
            guard let text = String(data: line, encoding: .utf8) else {
                lastError = CarrachoServerBotError.invalidInput.localizedDescription
                continue
            }
            do {
                try runtime.postLocalBotMessage(text)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
        writeStatus(connected: runtime.isLocalBotConnected && pipeSource != nil)
    }

    private func writeStatus(connected: Bool) {
        let url = Self.statusURL(rootURL: rootURL)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let snapshot = CarrachoServerBotStatus(pid: getpid(), updatedAt: Date(), connected: connected,
                                                   pipePath: pipeURL.path, lastError: lastError)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Status reporting is diagnostic only; it must never take the server down.
        }
    }
}
#endif
