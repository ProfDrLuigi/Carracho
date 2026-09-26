import Foundation
import Dispatch
import CryptoKit
import CoreFoundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum LegacyServerRuntimeError: LocalizedError {
    case alreadyRunning
    case socket(String)
    case protocolFailure(String)
    case stopped

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "The server is already running."
        case let .socket(message): return "Server socket error: \(message)"
        case let .protocolFailure(message): return "Legacy protocol error: \(message)"
        case .stopped: return "The server stopped."
        }
    }
}

struct LegacyServerRuntimeStatus: Equatable {
    var isRunning: Bool
    var port: UInt16?
    var transferPort: UInt16?
    var connectedClients: Int
    var activeFileTransfers: Int
}

/// Cross-platform Carracho 1.x control listener. The implementation deliberately uses
/// POSIX/BSD sockets instead of Network.framework so the same runtime can compile on Linux.
final class LegacyServerRuntime {
    static let publicChannelID: UInt32 = 1
    static let publicChannelName = Data("Public".utf8)
    private static let classicAvatarMaximumBytes = 0x27c
    private static let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    private static let channelOperatorMode: UInt8 = 0x80
    private static let channelSpeechMode: UInt8 = 0x40
    private static let channelPermanentFlag: UInt16 = 0x8000

    private static func classicAvatarPayload(from source: Data) -> Data {
        guard !source.isEmpty else { return Data() }

        // Carracho 1.0b10r4 sends its native user icon as exactly 0x27c bytes.
        // This is not PNG data; Classic expects the historical payload unchanged.
        if source.count == classicAvatarMaximumBytes {
            return source
        }

        guard source.count >= pngSignature.count,
              source.prefix(pngSignature.count) == pngSignature else { return Data() }
#if canImport(AppKit)
        guard let image = NSImage(data: source) else { return Data() }
        if source.count <= classicAvatarMaximumBytes,
           let rep = NSBitmapImageRep(data: source),
           rep.pixelsWide <= 16, rep.pixelsHigh <= 16 {
            return source
        }
        for side in [16, 14, 12, 10, 8] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: side,
                                                pixelsHigh: side,
                                                bitsPerSample: 8,
                                                samplesPerPixel: 4,
                                                hasAlpha: true,
                                                isPlanar: false,
                                                colorSpaceName: .deviceRGB,
                                                bytesPerRow: side * 4,
                                                bitsPerPixel: 32) else { continue }
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.current = context
                NSColor.clear.setFill()
                NSRect(x: 0, y: 0, width: side, height: side).fill()
                image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                           from: .zero,
                           operation: .copy,
                           fraction: 1,
                           respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high])
            }
            NSGraphicsContext.restoreGraphicsState()
            if let png = bitmap.representation(using: .png, properties: [:]),
               png.count <= classicAvatarMaximumBytes {
                return png
            }
        }
#endif
        return Data()
    }
    private static let channelPreservedFlag1: UInt16 = 0x4000
    private static let channelRestrictedChatFlag: UInt16 = 0x1000
    private static let channelRestrictedTopicFlag: UInt16 = 0x0800
    private static let defaultBotGreetingTemplate = "Welcome, {name}! Nice to have you here."
    private static let maximumBotGreetingTemplateBytes = 512

    private struct RuntimeChannel {
        var id: UInt32
        var name: Data
        var password: Data
        var topic: Data = Data()
        var flags: UInt16 = 0
        var members: [UInt32: UInt8] = [:]
    }

    private struct ActiveTransferDescriptor {
        var transferID: UInt32
        var kind: UInt8
        var userID: UInt32
        var socketFD: Int32
        var path: Data = Data()
        var bytesTransferred: UInt64 = 0
        var wireBytesTransferred: UInt64 = 0
        var totalBytes: UInt64 = 0
        var isDirectory = false
        var paused = false
        var aborting = false
        var rateWindowStartUptime: TimeInterval = 0
        var lastProgressUptime: TimeInterval = 0
        var rateWindowBytes: UInt64 = 0
        var bytesPerSecond: UInt64 = 0
        var nextDownloadSendUptime: TimeInterval = 0
        var downloadPacingGeneration: UInt64 = 0
    }

    let backend: ModernServerBackend
    private(set) var storageRoot: URL
    private let serverSupportRoot: URL
    let newsStore: ServerNewsStore
    let flatNewsStore: ServerFlatNewsStore
    let mediaStore: ServerMediaStore
    let trashRoot: URL
    let personalHomeRoot: URL
    private let fileMetadataDatabaseURL: URL
    private let fileMetadataLegacyJSONURL: URL
    private let legacyFileMetadataLegacyJSONURL: URL
    private let fileSearchIndexURL: URL
    let logFileURL: URL
    let eventFileURL: URL
    private let logFileLock = NSLock()
    private let eventFileLock = NSLock()
    private var fileMetadataStore: ServerFileMetadataStore?
    private var legacyFileMetadataStore: ServerFileMetadataStore?
    private var fileSearchIndex: ServerFileSearchIndex?
    private let fileSearchIndexStateLock = NSLock()
    private let fileSearchIndexRebuildQueue = DispatchQueue(label: "com.carracho.server-file-search-rebuild", qos: .utility)
    private var fileSearchIndexRebuildGeneration: UInt64 = 0
    private var fileSearchIndexRebuildWorkerActive = false
    private let fileSearchIndexScheduleQueue = DispatchQueue(label: "com.carracho.server-file-search-schedule", qos: .utility)
    private let fileSearchIndexScheduleLock = NSLock()
    private var fileSearchIndexScheduleTimer: DispatchSourceTimer?
    var onStatus: ((LegacyServerRuntimeStatus) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChanged: (() -> Void)?
    var onNewsChanged: (() -> Void)?

    private let stateLock = NSLock()
    private var listenerFD: Int32 = -1
    private var transferListenerFD: Int32 = -1
    private var boundPort: UInt16?
    private var boundTransferPort: UInt16?
    private var running = false
    private var startedAt: Date?
    private var sessions: [ObjectIdentifier: LegacyServerSession] = [:]
    private var authenticatedByUserID: [UInt32: LegacyServerSession] = [:]
    /// Synthetic local user used by the macOS Server Bot. It participates in the same user/channel
    /// collections as a network session, but has no socket and cannot access files or admin APIs.
    private var localBotSession: LegacyServerSession?
    private var channels: [UInt32: RuntimeChannel] = [:]
    private struct EditableMessage {
        let senderID: UInt32
        let kind: UInt8
        let scope: UInt32
        let createdAt: Date
        let sentUptime: TimeInterval
    }
    /// Only recent text messages are retained. Edits require the original live sender.
    private var editableMessages: [UUID: EditableMessage] = [:]

    private func registerEditableMessage(id: UUID, senderID: UInt32, kind: UInt8, scope: UInt32, createdAt: Date) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let uptime = ProcessInfo.processInfo.systemUptime
        editableMessages = editableMessages.filter {
            uptime - $0.value.sentUptime <= LegacyMessageEdit.maximumAge
        }
        guard editableMessages[id] == nil else { return false }
        editableMessages[id] = EditableMessage(senderID: senderID, kind: kind, scope: scope, createdAt: createdAt, sentUptime: uptime)
        return true
    }
    private var nextChannelID: UInt32 = 2
    private var nextUserID: UInt32 = 0x1000
    private var activeFileTransfers = 0
    private var activeFileTransfersByUser: [UInt32: Int] = [:]
    private var activeTransferDescriptors: [UInt32: ActiveTransferDescriptor] = [:]
    private var nextTransferID: UInt32 = 1
    /// Aggregate server outbound file bandwidth. Zero means unlimited.
    private var downloadBandwidthLimitBytesPerSecond: UInt64 = 0
    private var downloadBandwidthGeneration: UInt64 = 1
    private var downloadTrafficWindowStartUptime: TimeInterval = 0
    private var downloadTrafficWindowBytes: UInt64 = 0
    private var downloadTrafficBytesPerSecond: UInt64 = 0
    private var downloadTrafficLastActivityUptime: TimeInterval = 0
    private let acceptQueue = DispatchQueue(label: "com.carracho.server.accept", qos: .userInitiated)
    private let transferAcceptQueue = DispatchQueue(label: "com.carracho.server.transfer-accept", qos: .userInitiated)
    private let httpAdminQueue = DispatchQueue(label: "com.carracho.server.http-admin", qos: .utility)
    private var httpAdminEnabled = false
    private var httpAdminBindAddress = "127.0.0.1"
    private var httpAdminPort: UInt16 = 6780
    private var httpAdminTokenDigest = Data()
    private var httpAdminListenerFD: Int32 = -1
    private var boundHTTPAdminPort: UInt16?
    private let newsExpirationQueue = DispatchQueue(label: "com.carracho.server.news-expiration", qos: .utility)
    private let newsTimerLock = NSLock()
    private var newsExpirationTimer: DispatchSourceTimer?
    private let trackerNotificationQueue = DispatchQueue(label: "com.carracho.server.tracker-notifier", qos: .utility)
    private let trackerTimerLock = NSLock()
    private var trackerNotificationTimer: DispatchSourceTimer?
    private let presenceMonitorQueue = DispatchQueue(label: "com.carracho.server.presence-monitor", qos: .utility)
    private let presenceTimerLock = NSLock()
    private var automaticSleepTimer: DispatchSourceTimer?
    private let automaticSleepAfter: TimeInterval
    private lazy var botRSSService = LegacyBotRSSService(
        configURL: localBotConfigurationURL,
        databaseURL: fileMetadataDatabaseURL.deletingLastPathComponent().appendingPathComponent("bot-rss.db"),
        canPublish: { [weak self] in self?.isLocalBotConnected == true },
        articleHandler: { [weak self] feed, article in self?.publishLocalBotRSSArticle(feed: feed, article: article) ?? false },
        logHandler: { [weak self] message in self?.log(message) }
    )
    private lazy var botFileWatcherService = LegacyBotFileWatcherService(
        configURL: localBotConfigurationURL,
        filesRootURL: storageRoot,
        canPublish: { [weak self] in self?.isLocalBotConnected == true },
        announcementHandler: { [weak self] announcement in
            self?.publishLocalBotFileWatcherAnnouncement(announcement) ?? false
        },
        logHandler: { [weak self] message in self?.log(message) }
    )

    init(backend: ModernServerBackend, storageRoot: URL? = nil, newsRoot: URL? = nil,
         supportRoot: URL? = nil, databaseRoot: URL? = nil,
         automaticSleepAfter: TimeInterval = 5 * 60) {
        self.automaticSleepAfter = max(0.1, automaticSleepAfter)
        self.backend = backend
        self.downloadBandwidthLimitBytesPerSecond = backend.snapshot().runtime.uploadBandwidthLimitBytesPerSecond
        let files = storageRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Files", isDirectory: true)
        self.storageRoot = files
        // File storage may live on another disk. Keep databases, news, Trash, user homes,
        // metadata and the disposable search index under the server's support directory.
        let serverRoot = supportRoot ?? files.deletingLastPathComponent()
        let databases = databaseRoot ?? serverRoot
        self.serverSupportRoot = serverRoot
        let newsDatabase = databases.appendingPathComponent("news.db", isDirectory: false)
        let legacyNewsRoot = newsRoot ?? serverRoot.appendingPathComponent("News", isDirectory: true)
        self.newsStore = ServerNewsStore(databaseURL: newsDatabase, legacyRootURL: legacyNewsRoot)
        self.flatNewsStore = ServerFlatNewsStore(databaseURL: newsDatabase,
                                                 legacyURL: serverRoot.appendingPathComponent("flat-news.json"),
                                                 classicURL: legacyNewsRoot.appendingPathComponent("Flat News", isDirectory: false))
        self.mediaStore = ServerMediaStore(databaseURL: databases.appendingPathComponent("media.db", isDirectory: false),
                                           objectsRoot: serverRoot.appendingPathComponent("Media", isDirectory: true)
                                            .appendingPathComponent("objects", isDirectory: true))
        self.trashRoot = serverRoot.appendingPathComponent("Trash", isDirectory: true)
        self.personalHomeRoot = serverRoot.appendingPathComponent("Users", isDirectory: true)
            .appendingPathComponent("Home", isDirectory: true)
        self.fileMetadataDatabaseURL = databases.appendingPathComponent("server.db", isDirectory: false)
        self.fileMetadataLegacyJSONURL = serverRoot.appendingPathComponent("file-metadata.json")
        self.legacyFileMetadataLegacyJSONURL = serverRoot.appendingPathComponent("file-metadata-legacy.json")
        self.fileSearchIndexURL = databases.appendingPathComponent("file-index.db")
        self.logFileURL = serverRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("carracho-server.log", isDirectory: false)
        self.eventFileURL = serverRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("carracho-events.log", isDirectory: false)
        try? FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    deinit { stop() }

    /// Updates the published file root while the listener is stopped. The search index and
    /// metadata stores are reopened against this root on the next start.
    func configureStorageRoot(_ root: URL) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { throw LegacyServerRuntimeError.alreadyRunning }
        storageRoot = root.standardizedFileURL
    }

    func configureDownloadBandwidthLimit(_ bytesPerSecond: UInt64) {
        setDownloadBandwidthLimit(bytesPerSecond)
    }

    func configureHTTPAdministration(enabled: Bool, bindAddress: String, port: UInt16, token: String) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running, httpAdminListenerFD < 0 else {
            throw LegacyServerRuntimeError.protocolFailure("HTTP administration configuration cannot change while the server is running")
        }
        if enabled {
            guard token.utf8.count >= 24 else {
                throw LegacyServerRuntimeError.protocolFailure("HTTP administration requires a token of at least 24 UTF-8 bytes")
            }
            httpAdminTokenDigest = Data(SHA256.hash(data: Data(token.utf8)))
        } else {
            httpAdminTokenDigest.removeAll(keepingCapacity: false)
        }
        httpAdminEnabled = enabled
        httpAdminBindAddress = bindAddress
        httpAdminPort = port
    }

    private static func isTransferStagingName(_ name: String) -> Bool {
        name.hasSuffix(".carracho") || name.hasPrefix(".carracho.")
    }

    var status: LegacyServerRuntimeStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return LegacyServerRuntimeStatus(isRunning: running, port: boundPort, transferPort: boundTransferPort,
                                         connectedClients: authenticatedByUserID.count,
                                         activeFileTransfers: activeFileTransfers)
    }

    var isLocalBotConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return localBotSession != nil
    }

    /// Registers the persisted localhost-only Bot account as an ordinary visible user and joins it to Public.
    /// The session intentionally has no socket; profile, avatar, group, color and permissions come from
    /// the normal account store, while activation remains exclusively controlled by the local Bot controller.
    func connectLocalBot() throws {
        guard let account = backend.localBotAccount(), account.isLocalLoginOnly else {
            throw LegacyServerRuntimeError.protocolFailure("Local Bot account is unavailable")
        }
        guard account.permissions.contains(.joinChatRooms) else {
            throw LegacyServerRuntimeError.protocolFailure("Local Bot account does not have permission to join chat rooms")
        }
        let displayName = account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? account.login : account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedNickname = Self.macRoman(displayName)
        let nicknameData = Data(encodedNickname.prefix(64))
        guard !nicknameData.isEmpty else {
            throw LegacyServerRuntimeError.protocolFailure("Local Bot account has no usable nickname")
        }

        // The built-in Bot is deliberately an in-process localhost-only session. There is no
        // host/port parameter here, so this path cannot ever be redirected to a remote server.
        let session = LegacyServerSession(localBotRuntime: self)

        var existingSessions: [LegacyServerSession] = []
        var priorPublicRecipients: [LegacyServerSession] = []
        var userID: UInt32 = 0
        let publicMode: UInt8 = account.mode == .administrator ? Self.channelOperatorMode : 0

        stateLock.lock()
        guard running else {
            stateLock.unlock()
            throw LegacyServerRuntimeError.stopped
        }
        guard localBotSession == nil else {
            stateLock.unlock()
            return
        }
        userID = nextUserID
        nextUserID &+= 1
        session.userID = userID
        session.account = account
        session.nickname = nicknameData
        session.picture = account.picture ?? Data()
        session.statusMessage = Self.macRoman("Local server bot")
        session.sleeping = false
        session.loginAt = Date()
        session.lastActivityAt = session.loginAt
        sessions[ObjectIdentifier(session)] = session
        authenticatedByUserID[userID] = session
        existingSessions = authenticatedByUserID.values.filter { $0 !== session }

        var publicChannel = channels[Self.publicChannelID]
            ?? RuntimeChannel(id: Self.publicChannelID, name: Self.publicChannelName, password: Data())
        priorPublicRecipients = publicChannel.members.keys.compactMap { authenticatedByUserID[$0] }
        publicChannel.members[userID] = publicMode
        channels[Self.publicChannelID] = publicChannel
        localBotSession = session
        stateLock.unlock()

        recordLoginSuccess(mode: account.mode)
        try? backend.recordSuccessfulLogin(accountID: account.id)
        try? backend.updateLastNickname(accountID: account.id, nickname: displayName)
        appendUserEvent(session: session, category: "session", action: "login", detail: "local-bot connected")
        notifyUserArrived(session, to: existingSessions)
        let joined = LegacyPacket(command: LegacyCommand.channelUserJoined, transactionID: 0, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(Self.publicChannelID)),
            LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
            LegacyTLV(type: LegacyChannelField.userMode, value: Data([publicMode])),
        ])
        priorPublicRecipients.forEach { try? $0.sendAuthenticated(joined) }
        emitStatus()
        log("Local Bot account \(account.login) connected as user \(userID) and joined Public")
    }

    func disconnectLocalBot() {
        stateLock.lock()
        guard let session = localBotSession else { stateLock.unlock(); return }
        localBotSession = nil
        stateLock.unlock()
        session.close()
        sessionEnded(session)
        log("Local Bot disconnected")
    }

    /// Sends one terminal/FIFO line into Public.
    func postLocalBotMessage(_ text: String, source: String = "fifo") throws {
        try postLocalBotMessage(text, channelID: Self.publicChannelID, source: source)
    }

    /// Sends one line as the local Bot into a conference. The Bot joins a non-Public room on first
    /// addressed use so its messages have normal conference membership semantics.
    private func postLocalBotMessage(_ text: String, channelID: UInt32, source: String) throws {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let message = try CarrachoTextWire.encode(normalized, maximumBytes: 0x800)

        var recipients: [LegacyServerSession] = []
        var priorRecipients: [LegacyServerSession] = []
        var botSession: LegacyServerSession?
        var userID: UInt32 = 0
        var botMode: UInt8 = 0
        var canSpeak = false
        var joinedRoom = false
        stateLock.lock()
        if let bot = localBotSession, let id = bot.userID, var channel = channels[channelID],
           bot.account?.permissions.contains(.joinChatRooms) == true {
            botSession = bot
            userID = id
            if let existingMode = channel.members[id] {
                botMode = existingMode
            } else {
                priorRecipients = channel.members.keys.compactMap { authenticatedByUserID[$0] }
                botMode = bot.account?.mode == .administrator ? Self.channelOperatorMode : 0
                channel.members[id] = botMode
                channels[channelID] = channel
                joinedRoom = true
            }
            canSpeak = (channel.flags & Self.channelRestrictedChatFlag) == 0 ||
                (botMode & (Self.channelOperatorMode | Self.channelSpeechMode)) != 0
            recipients = channel.members.keys.compactMap { authenticatedByUserID[$0] }
        }
        stateLock.unlock()

        guard let botSession else { throw LegacyServerRuntimeError.protocolFailure("Bot is not connected or conference does not exist") }
        guard canSpeak else { throw LegacyServerRuntimeError.protocolFailure("Bot cannot speak in the restricted conference") }
        if joinedRoom {
            let joined = LegacyPacket(command: LegacyCommand.channelUserJoined, transactionID: 0, fields: [
                LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
                LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
                LegacyTLV(type: LegacyChannelField.userMode, value: Data([botMode])),
            ])
            priorRecipients.forEach { try? $0.sendAuthenticated(joined) }
        }
        markUserActive(botSession)

        var delivered = false
        for recipient in recipients {
            let wireMessage: Data
            if recipient.isLegacyTransport, CarrachoTextWire.isTaggedUTF8(message) {
                guard let classic = CarrachoTextWire.macRomanDescribingEmoji(from: message, maximumBytes: 0x800),
                      !classic.isEmpty else { continue }
                wireMessage = classic
            } else {
                wireMessage = message
            }
            let packet = LegacyPacket(command: LegacyCommand.channelChat, transactionID: 0, fields: [
                LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
                LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
                LegacyTLV(type: LegacyChannelField.message, value: wireMessage),
                LegacyTLV(type: LegacyChannelField.chatAttribute, value: Data([0])),
            ])
            do { try recipient.sendAuthenticated(packet); delivered = true }
            catch {
                if recipient !== botSession { log("Bot message delivery failed: \(error.localizedDescription)") }
            }
        }
        if delivered { recordMessage() }
        appendUserEvent(session: botSession, category: "chat", action: "message",
                        detail: "channel=\(channelID) source=\(source)")
    }

    private func postLocalBotPrivateMessage(_ text: String, to recipient: LegacyServerSession, source: String) throws {
        guard let bot = localBotSession, let botUserID = bot.userID else {
            throw LegacyServerRuntimeError.protocolFailure("Bot is not connected")
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let message = try CarrachoTextWire.encode(normalized, maximumBytes: 0x8000)
        let wireMessage: Data
        if recipient.isLegacyTransport, CarrachoTextWire.isTaggedUTF8(message) {
            guard let classic = CarrachoTextWire.macRomanDescribingEmoji(from: message, maximumBytes: 0x8000),
                  !classic.isEmpty else { return }
            wireMessage = classic
        } else {
            wireMessage = message
        }
        markUserActive(bot)
        try recipient.sendAuthenticated(LegacyPacket(command: LegacyCommand.privateMessage, transactionID: 0, fields: [
            LegacyTLV(type: 1, value: LegacyWire.uint32BE(botUserID)),
            LegacyTLV(type: 2, value: wireMessage),
        ]))
        recordMessage()
        appendUserEvent(session: bot, category: "messages", action: "private-message", detail: "source=\(source)")
    }

    /// Pass port 0 in tests to request an ephemeral operating-system-selected control port.
    /// The transfer listener is always bound to controlPort + 1.
    @discardableResult
    func start(port overridePort: UInt16? = nil) throws -> UInt16 {
        stateLock.lock()
        if running { stateLock.unlock(); throw LegacyServerRuntimeError.alreadyRunning }
        stateLock.unlock()

        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personalHomeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let configuredLegacyRoot = backend.snapshot().runtime.legacyFilesRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredLegacyRoot.isEmpty {
            guard NSString(string: configuredLegacyRoot).isAbsolutePath else {
                throw LegacyServerRuntimeError.protocolFailure("legacy Files root must be an absolute path")
            }
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: configuredLegacyRoot, isDirectory: true), withIntermediateDirectories: true)
        }
        fileMetadataStore = try ServerFileMetadataStore(databaseURL: fileMetadataDatabaseURL, scope: .published,
                                                        legacyJSONURL: fileMetadataLegacyJSONURL)
        legacyFileMetadataStore = try ServerFileMetadataStore(databaseURL: fileMetadataDatabaseURL, scope: .legacy,
                                                              legacyJSONURL: legacyFileMetadataLegacyJSONURL)
        prepareFileSearchIndex()
        for account in backend.snapshot().accounts where account.personalDirectory != .none {
            _ = try personalHomeURL(for: account, createIfNeeded: true)
        }
        // Open/migrate both News views before accepting clients. Threaded News and
        // Classic flat News share the dedicated news.db through separate connections.
        _ = try flatNewsStore.all()
        try mediaStore.cleanup()
        try synchronizeNewsState()
        _ = try runNewsExpiration(now: Date())
        let configured = backend.snapshot().advanced.controlPort
        let requestedPort = overridePort ?? configured
        let pair = try LegacySocket.makeListenerPair(controlPort: requestedPort)

        stateLock.lock()
        let shouldStartHTTPAdmin = httpAdminEnabled
        let adminBindAddress = httpAdminBindAddress
        let adminRequestedPort = httpAdminPort
        stateLock.unlock()

        var adminFD: Int32 = -1
        var adminBoundPort: UInt16?
        if shouldStartHTTPAdmin {
            do {
                adminFD = try LegacySocket.makeIPv4Listener(bindAddress: adminBindAddress, port: adminRequestedPort, backlog: 16)
                adminBoundPort = try LegacySocket.localPort(fd: adminFD)
            } catch {
                LegacySocket.shutdownAndClose(pair.controlFD)
                LegacySocket.shutdownAndClose(pair.transferFD)
                throw error
            }
        }

        stateLock.lock()
        listenerFD = pair.controlFD
        transferListenerFD = pair.transferFD
        httpAdminListenerFD = adminFD
        boundHTTPAdminPort = adminBoundPort
        if channels[Self.publicChannelID] == nil {
            channels[Self.publicChannelID] = RuntimeChannel(id: Self.publicChannelID, name: Self.publicChannelName, password: Data())
        }
        boundPort = pair.controlPort
        boundTransferPort = pair.transferPort
        running = true
        startedAt = Date()
        stateLock.unlock()
        emitStatus()
        log("Listening on TCP \(pair.controlPort) (legacy control) and TCP \(pair.transferPort) (transfers)")

        acceptQueue.async { [weak self] in self?.acceptLoop(fd: pair.controlFD) }
        transferAcceptQueue.async { [weak self] in self?.transferAcceptLoop(fd: pair.transferFD) }
        if let adminBoundPort {
            log("HTTP administration API listening on http://\(adminBindAddress):\(adminBoundPort)/api/v1/")
            httpAdminQueue.async { [weak self] in self?.httpAdminAcceptLoop(fd: adminFD) }
        }
        scheduleNextNewsExpiration()
        refreshTrackerConfiguration()
        refreshSearchIndexRebuildSchedule()
        scheduleAutomaticSleepMonitor()
        botRSSService.start()
        botFileWatcherService.start()
        return pair.controlPort
    }

    func stop() {
        botFileWatcherService.stop()
        botRSSService.stop()
        disconnectLocalBot()
        let clients: [LegacyServerSession]
        let fd: Int32
        let transferFD: Int32
        let httpAdminFD: Int32
        let activeTransferFDs: [Int32]
        stateLock.lock()
        guard running || listenerFD >= 0 || transferListenerFD >= 0 || httpAdminListenerFD >= 0 else { stateLock.unlock(); return }
        running = false
        fd = listenerFD
        transferFD = transferListenerFD
        httpAdminFD = httpAdminListenerFD
        listenerFD = -1
        transferListenerFD = -1
        httpAdminListenerFD = -1
        boundPort = nil
        boundTransferPort = nil
        boundHTTPAdminPort = nil
        startedAt = nil
        clients = Array(sessions.values)
        activeTransferFDs = activeTransferDescriptors.values.map(\.socketFD)
        stateLock.unlock()
        cancelNewsExpirationTimer()
        cancelTrackerNotificationTimer()
        cancelSearchIndexRebuildSchedule()
        cancelAutomaticSleepMonitor()

        if fd >= 0 { LegacySocket.shutdownAndClose(fd) }
        if transferFD >= 0 { LegacySocket.shutdownAndClose(transferFD) }
        if httpAdminFD >= 0 { LegacySocket.shutdownAndClose(httpAdminFD) }
        activeTransferFDs.forEach { LegacySocket.interrupt($0) }
        clients.forEach { $0.close() }
        stateLock.lock()
        sessions.removeAll()
        authenticatedByUserID.removeAll()
        channels.removeAll()
        nextChannelID = 2
        activeFileTransfers = 0
        activeFileTransfersByUser.removeAll()
        activeTransferDescriptors.removeAll()
        nextTransferID = 1
        stateLock.unlock()
        emitStatus()
        log("Server stopped")
    }

    fileprivate func allowsLegacyTransport() -> Bool {
        backend.snapshot().authentication.mode == .legacyCompatible
    }

    private func acceptLoop(fd: Int32) {
        while true {
            stateLock.lock(); let shouldRun = running && listenerFD == fd; stateLock.unlock()
            guard shouldRun else { return }
            do {
                let accepted = try LegacySocket.accept(fd: fd)
                let admission = admit(peerIP: accepted.peerIP)
                if !admission.allowed {
                    log("Rejected connection from \(accepted.peerIP): \(admission.reason)")
                    LegacySocket.shutdownAndClose(accepted.fd)
                    continue
                }
                let session = LegacyServerSession(fd: accepted.fd, peerIP: accepted.peerIP, runtime: self)
                stateLock.lock(); sessions[ObjectIdentifier(session)] = session; stateLock.unlock()
                emitStatus()
                log("Connection established from \(accepted.peerIP)")
                DispatchQueue.global(qos: .userInitiated).async { session.run() }
            } catch {
                stateLock.lock(); let stillRunning = running; stateLock.unlock()
                if stillRunning { log("Accept failed: \(error.localizedDescription)") }
                return
            }
        }
    }

    // MARK: - HTTP administration

    private static let httpAdminMaximumHeaderBytes = 64 * 1024
    private static let httpAdminMaximumBodyBytes = 1024 * 1024

    private func httpAdminAcceptLoop(fd: Int32) {
        while true {
            stateLock.lock()
            let shouldRun = running && httpAdminListenerFD == fd
            stateLock.unlock()
            guard shouldRun else { return }
            do {
                let accepted = try LegacySocket.accept(fd: fd)
                LegacySocket.setTimeouts(fd: accepted.fd, seconds: 5)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    defer { LegacySocket.shutdownAndClose(accepted.fd) }
                    self?.handleHTTPAdminConnection(fd: accepted.fd)
                }
            } catch {
                stateLock.lock()
                let stillRunning = running && httpAdminListenerFD == fd
                stateLock.unlock()
                if stillRunning { log("HTTP administration accept failed: \(error.localizedDescription)") }
                return
            }
        }
    }

    private func handleHTTPAdminConnection(fd: Int32) {
        do {
            var input = Data()
            let delimiter = Data("\r\n\r\n".utf8)
            var headerRange: Range<Data.Index>?
            while input.count <= Self.httpAdminMaximumHeaderBytes {
                if let range = input.range(of: delimiter) {
                    headerRange = range
                    break
                }
                input.append(try LegacySocket.readSome(fd: fd, maximum: 4096))
            }
            guard let headerRange else {
                try sendHTTPAdminResponse(fd: fd, status: 413,
                                          object: httpAdminError(code: "header_too_large",
                                                                 message: "HTTP header is too large or incomplete"))
                return
            }
            let headerLength = headerRange.upperBound
            guard headerLength <= Self.httpAdminMaximumHeaderBytes,
                  let headerText = String(data: input[..<headerRange.lowerBound], encoding: .utf8) else {
                try sendHTTPAdminResponse(fd: fd, status: 400,
                                          object: httpAdminError(code: "bad_request", message: "Malformed HTTP request"))
                return
            }
            let lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                try sendHTTPAdminResponse(fd: fd, status: 400,
                                          object: httpAdminError(code: "bad_request", message: "Malformed HTTP request"))
                return
            }
            let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
            guard requestParts.count == 3,
                  requestParts[2].hasPrefix("HTTP/1."),
                  requestParts[0].count <= 15,
                  requestParts[1].count <= 2047 else {
                try sendHTTPAdminResponse(fd: fd, status: 400,
                                          object: httpAdminError(code: "bad_request", message: "Malformed HTTP request"))
                return
            }
            let method = String(requestParts[0])
            var path = String(requestParts[1])
            var query: String?
            if let queryIndex = path.firstIndex(of: "?") {
                query = String(path[path.index(after: queryIndex)...])
                path = String(path[..<queryIndex])
            }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else {
                    try sendHTTPAdminResponse(fd: fd, status: 400,
                                              object: httpAdminError(code: "bad_request", message: "Malformed HTTP header"))
                    return
                }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    try sendHTTPAdminResponse(fd: fd, status: 400,
                                              object: httpAdminError(code: "bad_request", message: "Malformed HTTP header"))
                    return
                }
                headers[name] = value
            }

            if headers["transfer-encoding"] != nil {
                try sendHTTPAdminResponse(fd: fd, status: 400,
                                          object: httpAdminError(code: "bad_request",
                                                                 message: "Chunked request bodies are not supported"))
                return
            }
            let contentLength: Int
            if let raw = headers["content-length"] {
                guard let parsed = Int(raw), parsed >= 0 else {
                    try sendHTTPAdminResponse(fd: fd, status: 400,
                                              object: httpAdminError(code: "bad_request", message: "Invalid Content-Length"))
                    return
                }
                guard parsed <= Self.httpAdminMaximumBodyBytes else {
                    try sendHTTPAdminResponse(fd: fd, status: 413,
                                              object: httpAdminError(code: "payload_too_large", message: "JSON body is too large"))
                    return
                }
                contentLength = parsed
            } else {
                contentLength = 0
            }

            guard let authorization = headers["authorization"],
                  authorization.hasPrefix("Bearer "),
                  httpAdminTokenMatches(String(authorization.dropFirst(7))) else {
                try sendHTTPAdminResponse(fd: fd, status: 401,
                                          object: httpAdminError(code: "unauthorized", message: "Valid Bearer token required"))
                return
            }

            while input.count - headerLength < contentLength {
                input.append(try LegacySocket.readSome(
                    fd: fd, maximum: min(4096, contentLength - (input.count - headerLength))))
            }
            let bodyData = contentLength == 0 ? Data()
                : input.subdata(in: headerLength..<(headerLength + contentLength))
            let body: Any?
            if bodyData.isEmpty {
                body = nil
            } else {
                do {
                    body = try JSONSerialization.jsonObject(with: bodyData)
                } catch {
                    try sendHTTPAdminResponse(fd: fd, status: 400,
                                              object: httpAdminError(code: "invalid_json",
                                                                     message: "Request body must contain valid JSON"))
                    return
                }
            }

            let response = httpAdminDispatch(method: method, path: path, query: query, body: body)
            try sendHTTPAdminResponse(fd: fd, status: response.status, object: response.object)
        } catch LegacyServerRuntimeError.stopped {
            // A health probe may connect only to test the port and close without an HTTP request.
            return
        } catch {
            try? sendHTTPAdminResponse(fd: fd, status: 500,
                                       object: httpAdminError(code: "internal_error",
                                                              message: "HTTP administration request failed"))
            log("HTTP administration request failed: \(error.localizedDescription)")
        }
    }

    private func httpAdminTokenMatches(_ token: String) -> Bool {
        stateLock.lock()
        let expected = httpAdminTokenDigest
        stateLock.unlock()
        guard expected.count == 32 else { return false }
        let candidate = Data(SHA256.hash(data: Data(token.utf8)))
        return Self.constantTimeEqual(candidate, expected)
    }

    private func httpAdminError(code: String, message: String) -> [String: Any] {
        ["error": ["code": code, "message": message]]
    }

    private func sendHTTPAdminResponse(fd: Int32, status: Int, object: Any?) throws {
        let body = status == 204 ? Data()
            : try JSONSerialization.data(withJSONObject: object ?? [:], options: [])
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 202: reason = "Accepted"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        let header =
            "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n" +
            "Cache-Control: no-store\r\n" +
            "X-Content-Type-Options: nosniff\r\n\r\n"
        try LegacySocket.writeAll(fd: fd, data: Data(header.utf8))
        if !body.isEmpty { try LegacySocket.writeAll(fd: fd, data: body) }
    }

    private func httpAdminDispatch(method: String, path: String, query: String?, body: Any?) -> (status: Int, object: Any?) {
        do {
            switch (method, path) {
            case ("GET", "/api/v1/status"):
                return (200, httpAdminStatusJSON())
            case ("GET", "/api/v1/users"):
                return (200, httpAdminUsersJSON())
            case ("GET", "/api/v1/transfers"):
                return (200, httpAdminTransfersJSON())
            case ("GET", "/api/v1/log"):
                guard let limit = httpAdminLogLimit(query: query) else {
                    return (400, httpAdminError(code: "invalid_limit",
                                                message: "limit must be an integer from 1 to 1000"))
                }
                return (200, try httpAdminLogJSON(limit: limit))
            case ("GET", "/api/v1/accounts"):
                return (200, httpAdminAccountsJSON())
            case ("GET", "/api/v1/conferences"):
                return (200, httpAdminConferencesJSON())
            case ("GET", "/api/v1/bot/file-watchers"):
                do { return (200, try httpAdminBotFileWatchersJSON()) }
                catch {
                    return (500, httpAdminError(code: "bot_file_watchers_failed", message: error.localizedDescription))
                }
            case ("PUT", "/api/v1/bot/file-watchers"):
                guard let object = body as? [String: Any] else {
                    return (400, httpAdminError(code: "invalid_bot_file_watchers",
                                                message: "File Watcher payload must be a JSON object"))
                }
                do {
                    try httpAdminSetBotFileWatchers(object)
                    return (200, try httpAdminBotFileWatchersJSON())
                } catch {
                    return (400, httpAdminError(code: "invalid_bot_file_watchers", message: error.localizedDescription))
                }
            case ("GET", "/api/v1/settings"):
                return (200, httpAdminSettingsJSON())
            case ("GET", "/api/v1/search-index/status"):
                return (200, httpAdminSearchIndexJSON())
            case ("PATCH", "/api/v1/settings"):
                guard let object = body as? [String: Any] else {
                    return (400, httpAdminError(code: "invalid_settings",
                                                message: "Settings payload must be a JSON object"))
                }
                try httpAdminPatchSettings(object)
                return (200, httpAdminSettingsJSON())
            case ("POST", "/api/v1/search-index/rebuild"):
                let wasRunning = httpAdminSearchIndexRebuilding()
                rebuildSearchIndexInBackground(reason: "HTTP administration request")
                return (202, ["accepted": true, "alreadyRunning": wasRunning])
            case ("POST", "/api/v1/broadcast"):
                guard let object = body as? [String: Any], let message = object["message"] as? String else {
                    return (400, httpAdminError(code: "invalid_broadcast",
                                                message: "A non-empty message up to 509 UTF-8 bytes is required"))
                }
                try httpAdminBroadcast(message)
                return (200, ["ok": true])
            case ("POST", "/api/v1/accounts"):
                guard let object = body as? [String: Any] else {
                    return (400, httpAdminError(code: "account_save_failed",
                                                message: "Account payload must be a JSON object"))
                }
                let account = try httpAdminCreateAccount(object)
                return (201, httpAdminAccountJSON(account))
            case ("POST", "/api/v1/conferences"):
                guard let object = body as? [String: Any] else {
                    return (400, httpAdminError(code: "conference_create_failed",
                                                message: "Invalid conference payload"))
                }
                switch try httpAdminCreateConference(object) {
                case let .success(id): return (201, ["id": NSNumber(value: id)])
                case .duplicate:
                    return (409, httpAdminError(code: "conference_create_failed",
                                                message: "A conference with that name already exists"))
                }
            default:
                break
            }

            if path.hasPrefix("/api/v1/transfers/") {
                let suffix = String(path.dropFirst("/api/v1/transfers/".count))
                let parts = suffix.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[1] == "cancel",
                      let id = UInt32(parts[0]), id > 0 else {
                    return (400, httpAdminError(code: "invalid_transfer_id",
                                                message: "Transfer path must be /api/v1/transfers/{id}/cancel"))
                }
                guard method == "POST" else {
                    return (405, httpAdminError(code: "method_not_allowed",
                                                message: "Only POST is supported for transfer cancellation"))
                }
                do {
                    try applyTransferControl(LegacyTransferControlRequest(transferID: id, action: .abort))
                } catch {
                    return (404, httpAdminError(code: "transfer_not_found",
                                                message: "Active transfer not found"))
                }
                log("Transfer \(id) cancellation requested through HTTP administration API")
                return (202, ["accepted": true, "id": NSNumber(value: id), "status": "cancelling"])
            }

            if path.hasPrefix("/api/v1/accounts/") {
                let encoded = String(path.dropFirst("/api/v1/accounts/".count))
                guard let login = encoded.removingPercentEncoding, !login.isEmpty else {
                    return (400, httpAdminError(code: "invalid_login", message: "Malformed account login in URL"))
                }
                if method == "PATCH" {
                    guard let object = body as? [String: Any] else {
                        return (400, httpAdminError(code: "account_save_failed",
                                                    message: "Account payload must be a JSON object"))
                    }
                    guard let account = try httpAdminPatchAccount(login: login, object) else {
                        return (404, httpAdminError(code: "account_save_failed", message: "Account not found"))
                    }
                    return (200, httpAdminAccountJSON(account))
                }
                if method == "DELETE" {
                    guard try httpAdminDeleteAccount(login: login) else {
                        return (404, httpAdminError(code: "account_delete_failed", message: "Account not found"))
                    }
                    return (204, nil)
                }
                return (405, httpAdminError(code: "method_not_allowed",
                                            message: "Use PATCH or DELETE for an account resource"))
            }

            if path.hasPrefix("/api/v1/conferences/") {
                guard method == "DELETE" else {
                    return (405, httpAdminError(code: "method_not_allowed",
                                                message: "Only DELETE is supported for this conference resource"))
                }
                let raw = String(path.dropFirst("/api/v1/conferences/".count))
                guard let id = UInt32(raw), id > 0 else {
                    return (400, httpAdminError(code: "invalid_conference_id",
                                                message: "Conference ID must be a positive integer"))
                }
                guard httpAdminDeleteConference(id: id) else {
                    return (404, httpAdminError(code: "conference_delete_failed",
                                                message: "Conference not found or Public cannot be deleted"))
                }
                return (204, nil)
            }

            return (404, httpAdminError(code: "not_found", message: "Unknown API endpoint"))
        } catch {
            return (400, httpAdminError(code: "invalid_request", message: error.localizedDescription))
        }
    }

    private func httpAdminStatusJSON() -> [String: Any] {
        let state = backend.snapshot()
        stateLock.lock()
        let controlPort = boundPort
        let transferPort = boundTransferPort
        let userCount = authenticatedByUserID.count
        let transferCount = activeFileTransfers
        let start = startedAt
        stateLock.unlock()
        return [
            "serverName": state.identity.name,
            "software": "Carracho Server 1.0.8",
            "uptimeSeconds": NSNumber(value: max(0, Int64(Date().timeIntervalSince(start ?? Date())))),
            "usersOnline": userCount,
            "maxConnections": Int(state.advanced.maxConnections),
            "activeTransfers": transferCount,
            "controlPort": Int(controlPort ?? 0),
            "transferPort": Int(transferPort ?? 0),
            "searchIndex": httpAdminSearchIndexJSON(),
        ]
    }

    private func httpAdminUsersJSON() -> [[String: Any]] {
        stateLock.lock()
        let current = authenticatedByUserID.values.map { session -> [String: Any] in
            let account = session.account
            let nickname = String(data: session.nickname, encoding: .macOSRoman) ?? account?.login ?? ""
            let status = String(data: session.statusMessage, encoding: .macOSRoman) ?? ""
            return [
                "userID": NSNumber(value: session.userID ?? 0),
                "accountID": account?.id.uuidString.lowercased() ?? "",
                "login": account?.login ?? "",
                "nickname": nickname,
                "mode": account?.mode.rawValue ?? ServerAccountMode.guest.rawValue,
                "peerIP": session.peerIP,
                "transport": session.isLegacyTransport ? "legacy-Blowfish" : "AES-256-GCM",
                "sleeping": session.sleeping,
                "loginUnix": NSNumber(value: Int64(session.loginAt.timeIntervalSince1970)),
                "lastActivityUnix": NSNumber(value: Int64(session.lastActivityAt.timeIntervalSince1970)),
                "status": status,
                "operatingSystem": String(data: session.clientOperatingSystem, encoding: .utf8) ?? "",
                "cpuArchitecture": String(data: session.clientCPUArchitecture, encoding: .utf8) ?? "",
                "clientVersion": String(data: session.clientVersion, encoding: .utf8) ?? "",
                "clientBuild": String(data: session.clientBuild, encoding: .utf8) ?? "",
            ]
        }
        stateLock.unlock()
        return current.sorted {
            (($0["userID"] as? NSNumber)?.uint32Value ?? 0) < (($1["userID"] as? NSNumber)?.uint32Value ?? 0)
        }
    }

    private func httpAdminTransferPath(_ path: Data) -> String {
        guard !path.isEmpty else { return "/" }
        let components = path.split(separator: LegacyPath.separator, omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty }) else { return "<invalid-path>" }
        return "/" + components.map { CarrachoTextWire.string(from: Data($0)) }.joined(separator: "/")
    }

    private func httpAdminLogLimit(query: String?) -> Int? {
        guard let query, !query.isEmpty else { return 200 }
        var result = 200
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.first == "limit" else { continue }
            guard pair.count == 2, let value = Int(pair[1]), (1...1000).contains(value) else {
                return nil
            }
            result = value
        }
        return result
    }

    private func httpAdminLogJSON(limit: Int) throws -> [[String: Any]] {
        logFileLock.lock()
        defer { logFileLock.unlock() }

        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: logFileURL)
        defer { try? handle.close() }

        let total = handle.seekToEndOfFile()
        var position = total
        var chunks: [Data] = []
        var newlineCount = 0
        while position > 0 && newlineCount <= limit {
            let chunkSize = min(UInt64(64 * 1024), position)
            position -= chunkSize
            handle.seek(toFileOffset: position)
            let chunk = handle.readData(ofLength: Int(chunkSize))
            if chunk.isEmpty { break }
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0a { count += 1 }
            }
            chunks.append(chunk)
        }

        var data = Data()
        data.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks.reversed() { data.append(chunk) }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).suffix(limit)
        return lines.map { rawLine in
            let line = String(rawLine)
            if let split = line.firstIndex(of: " ") {
                return [
                    "time": String(line[..<split]),
                    "type": "log",
                    "message": String(line[line.index(after: split)...]),
                ]
            }
            return ["time": "", "type": "log", "message": line]
        }
    }

    private func httpAdminTransfersJSON() -> [[String: Any]] {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        let result = activeTransferDescriptors.values.sorted { $0.transferID < $1.transferID }.map { descriptor -> [String: Any] in
            let session = authenticatedByUserID[descriptor.userID]
            let account = session?.account
            let login = account?.login ?? ""
            let nickname = session.map { CarrachoTextWire.string(from: $0.nickname) } ?? login
            let path = httpAdminTransferPath(descriptor.path)
            let fileName = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
            let speed = currentTransferRate(descriptor, now: now)
            let resumed = descriptor.bytesTransferred >= descriptor.wireBytesTransferred
                ? descriptor.bytesTransferred - descriptor.wireBytesTransferred : 0
            let eta: Double
            if descriptor.totalBytes > 0, descriptor.bytesTransferred >= descriptor.totalBytes {
                eta = 0
            } else if descriptor.totalBytes > descriptor.bytesTransferred, speed > 0 {
                eta = Double(descriptor.totalBytes - descriptor.bytesTransferred) / Double(speed)
            } else {
                eta = -1
            }
            return [
                "id": NSNumber(value: descriptor.transferID),
                "direction": descriptor.kind == LegacyTransferKind.download ? "download" : "upload",
                "userID": NSNumber(value: descriptor.userID),
                "accountID": account?.id.uuidString.lowercased() ?? "",
                "login": login,
                "user": nickname,
                "nickname": nickname,
                "peerIP": session?.peerIP ?? "",
                "path": path,
                "fileName": fileName,
                "sizeBytes": NSNumber(value: descriptor.totalBytes),
                "transferredBytes": NSNumber(value: descriptor.bytesTransferred),
                "wireBytesTransferred": NSNumber(value: descriptor.wireBytesTransferred),
                "resumedBytes": NSNumber(value: resumed),
                "speedBytesPerSecond": NSNumber(value: speed),
                "etaSeconds": eta,
                "isDirectory": descriptor.isDirectory,
                "status": descriptor.aborting ? "cancelling" : (descriptor.paused ? "paused" : "active"),
            ]
        }
        stateLock.unlock()
        return result
    }

    private func httpAdminAccountsJSON() -> [[String: Any]] {
        let state = backend.snapshot()
        return state.accounts.map { httpAdminAccountJSON($0, state: state) }
    }

    private func httpAdminPermissionBits(_ account: ServerAccount) -> UInt64 {
        var bits: UInt64 = 0
        func set(_ bit: Int) {
            guard bit >= 0, bit < 64 else { return }
            bits |= UInt64(1) << UInt64(bit)
        }
        switch account.mode {
        case .administrator: set(LegacyAccountPermissionBit.administrator)
        case .accountHolder: set(LegacyAccountPermissionBit.accountHolder)
        case .guest: break
        }
        switch account.personalDirectory {
        case .none: break
        case .nestedInRoot: set(LegacyAccountPermissionBit.personalDirectoryNestedInRoot)
        case .rootDirectory: set(LegacyAccountPermissionBit.personalDirectoryIsRoot)
        }
        account.permissions.forEach { set($0.rawValue) }
        return bits
    }

    private func httpAdminAccountJSON(_ account: ServerAccount, state: ServerState? = nil) -> [String: Any] {
        let state = state ?? backend.snapshot()
        let formatter = ISO8601DateFormatter()
        var result: [String: Any] = [
            "id": account.id.uuidString.lowercased(),
            "login": account.login,
            "name": account.name,
            "profileName": account.profileName ?? "",
            "mode": account.mode.rawValue,
            "groupID": account.groupID?.uuidString.lowercased() ?? "",
            "permissionBits": NSNumber(value: httpAdminPermissionBits(account)),
            "colorRGB": NSNumber(value: state.accountColorRGB(for: account) ?? 0),
            "hasColorOverride": account.colorOverridesGroupDefault == true,
            "personalDirectory": account.personalDirectory == .rootDirectory ? "root"
                : (account.personalDirectory == .nestedInRoot ? "nested" : "none"),
            "createdAt": formatter.string(from: account.createdAt),
            "modifiedAt": formatter.string(from: account.modifiedAt),
            "lastLoginAt": account.lastLoginAt.map(formatter.string(from:)) ?? "",
            "localLoginOnly": account.isLocalLoginOnly,
        ]
        if let email = account.email { result["email"] = email }
        return result
    }

    private func httpAdminConferencesJSON() -> [[String: Any]] {
        stateLock.lock()
        let result = channels.values.map { channel -> [String: Any] in
            [
                "id": NSNumber(value: channel.id),
                "name": String(data: channel.name, encoding: .macOSRoman) ?? "Channel \(channel.id)",
                "topic": String(data: channel.topic, encoding: .macOSRoman) ?? "",
                "members": channel.members.count,
                "passwordProtected": !channel.password.isEmpty,
                "restrictedChat": (channel.flags & Self.channelRestrictedChatFlag) != 0,
                "permanent": (channel.flags & Self.channelPermanentFlag) != 0,
            ]
        }
        stateLock.unlock()
        return result.sorted {
            (($0["id"] as? NSNumber)?.uint32Value ?? 0) < (($1["id"] as? NSNumber)?.uint32Value ?? 0)
        }
    }

    private func httpAdminBotFileWatchersJSON() throws -> [String: Any] {
        let watchers = localBotFileWatchers()
        return ["watchers": watchers.map { watcher in
            [
                "id": watcher.id.uuidString.lowercased(),
                "enabled": watcher.enabled,
                "path": watcher.path,
                "channelID": NSNumber(value: watcher.channelID),
                "messageTemplate": watcher.messageTemplate,
            ] as [String: Any]
        }]
    }

    private func httpAdminSetBotFileWatchers(_ object: [String: Any]) throws {
        guard let rawWatchers = object["watchers"] as? [[String: Any]],
              rawWatchers.count <= LegacyBotFileWatcher.maximumCount else {
            throw ServerStateError.invalidValue("watchers must be an array with at most 32 entries.")
        }

        stateLock.lock()
        let conferenceIDs = Set(channels.keys)
        stateLock.unlock()

        var watchers: [LegacyBotFileWatcher] = []
        watchers.reserveCapacity(rawWatchers.count)
        for raw in rawWatchers {
            let id: UUID
            if let rawID = raw["id"] as? String, let parsed = UUID(uuidString: rawID) {
                id = parsed
            } else if raw["id"] == nil {
                id = UUID()
            } else {
                throw ServerStateError.invalidValue("Each Bot File Watcher id must be a UUID.")
            }
            guard let enabled = raw["enabled"] as? Bool,
                  let path = raw["path"] as? String,
                  let messageTemplate = raw["messageTemplate"] as? String,
                  let channelNumber = raw["channelID"] as? NSNumber,
                  CFGetTypeID(channelNumber) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(channelNumber),
                  channelNumber.int64Value > 0, channelNumber.int64Value <= Int64(UInt32.max) else {
                throw ServerStateError.invalidValue("Each Bot File Watcher needs enabled, path, channelID and messageTemplate.")
            }
            let channelID = UInt32(channelNumber.uint32Value)
            guard conferenceIDs.contains(channelID) else {
                throw ServerStateError.invalidValue("Bot File Watcher Conference \(channelID) does not exist.")
            }
            watchers.append(LegacyBotFileWatcher(id: id, enabled: enabled, path: path,
                                                 channelID: channelID, messageTemplate: messageTemplate))
        }
        try setLocalBotFileWatchers(watchers)
        log("Bot File Watcher configuration updated through HTTP administration API")
    }

    private func httpAdminSettingsJSON() -> [String: Any] {
        let state = backend.snapshot()
        return [
            "serverName": state.identity.name,
            "description": state.identity.description,
            "authenticationMode": state.authentication.mode.rawValue,
            "maxConnections": Int(state.advanced.maxConnections),
            "maxConnectionsPerIP": Int(state.advanced.maxConnectionsPerIP),
            "maxSimultaneousFileTransfers": Int(state.advanced.maxSimultaneousFileTransfers),
            "maxFileTransfersPerUser": Int(state.advanced.maxFileTransfersPerUser),
            "maxFolderDownloadDepth": Int(state.advanced.maxFolderDownloadDepth),
            "filesRoot": state.runtime.filesRoot.isEmpty ? storageRoot.standardizedFileURL.path : state.runtime.filesRoot,
            "legacyFilesRoot": state.runtime.legacyFilesRoot,
            "searchIndexRebuildIntervalHours": NSNumber(value: state.runtime.searchIndexRebuildIntervalHours),
            "searchIndexExclusions": state.runtime.searchIndexExclusions,
        ]
    }

    private func httpAdminSearchIndexRebuilding() -> Bool {
        fileSearchIndexStateLock.lock()
        let rebuilding = fileSearchIndexRebuildWorkerActive
        fileSearchIndexStateLock.unlock()
        return rebuilding
    }

    private func httpAdminSearchIndexJSON() -> [String: Any] {
        let index = currentFileSearchIndex()
        var result: [String: Any] = [
            "ready": index != nil,
            "rebuilding": httpAdminSearchIndexRebuilding(),
            "rebuildIntervalHours": NSNumber(value: backend.snapshot().runtime.searchIndexRebuildIntervalHours),
        ]
        if let index {
            if let count = try? index.entryCount() { result["entries"] = count }
            do {
                if let date = try index.lastFullRebuildDate() {
                    result["lastFullRebuildUnix"] = NSNumber(value: Int64(date.timeIntervalSince1970))
                }
            } catch {
                log("HTTP administration could not read search-index metadata: \(error.localizedDescription)")
            }
        } else {
            result["entries"] = 0
        }
        return result
    }

    private func httpAdminString(_ object: [String: Any], key: String,
                                 maximumUTF8Bytes: Int, required: Bool = false) throws -> String? {
        guard let raw = object[key] else {
            if required { throw ServerStateError.invalidValue("\(key) is required.") }
            return nil
        }
        guard let value = raw as? String,
              value.utf8.count <= maximumUTF8Bytes,
              (!required || !value.isEmpty) else {
            throw ServerStateError.invalidValue("\(key) is invalid.")
        }
        return value
    }

    private func httpAdminUInt64(_ object: [String: Any], key: String, maximum: UInt64) throws -> UInt64? {
        guard let raw = object[key] else { return nil }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else {
            throw ServerStateError.invalidValue("\(key) must be an integer.")
        }
        let signed = number.int64Value
        guard signed >= 0, UInt64(signed) <= maximum else {
            throw ServerStateError.invalidValue("\(key) is outside the supported integer range.")
        }
        return UInt64(signed)
    }

    private func httpAdminPermissions(bits: UInt64) -> Set<ServerPermission> {
        Set(ServerPermission.allCases.filter { permission in
            (bits & (UInt64(1) << UInt64(permission.rawValue))) != 0
        })
    }

    private func httpAdminPersonalDirectory(bits: UInt64) -> ServerPersonalDirectoryMode {
        if (bits & (UInt64(1) << UInt64(LegacyAccountPermissionBit.personalDirectoryIsRoot))) != 0 {
            return .rootDirectory
        }
        if (bits & (UInt64(1) << UInt64(LegacyAccountPermissionBit.personalDirectoryNestedInRoot))) != 0 {
            return .nestedInRoot
        }
        return .none
    }

    private func httpAdminPatchSettings(_ object: [String: Any]) throws {
        let serverName = try httpAdminString(object, key: "serverName", maximumUTF8Bytes: 255)
        let description = try httpAdminString(object, key: "description", maximumUTF8Bytes: 16_384)
        let maxConnections = try httpAdminUInt64(object, key: "maxConnections", maximum: UInt64(UInt16.max))
        let maxConnectionsPerIP = try httpAdminUInt64(object, key: "maxConnectionsPerIP", maximum: UInt64(UInt16.max))
        let maxTransfers = try httpAdminUInt64(object, key: "maxSimultaneousFileTransfers", maximum: UInt64(UInt16.max))
        let maxUserTransfers = try httpAdminUInt64(object, key: "maxFileTransfersPerUser", maximum: UInt64(UInt16.max))
        let maxFolderDepth = try httpAdminUInt64(object, key: "maxFolderDownloadDepth", maximum: UInt64(UInt16.max))
        let rebuildHours = try httpAdminUInt64(object, key: "searchIndexRebuildIntervalHours", maximum: UInt64(UInt32.max))
        let exclusions: [String]?
        if let raw = object["searchIndexExclusions"] {
            guard let values = raw as? [Any] else {
                throw ServerStateError.invalidValue("searchIndexExclusions must be an array.")
            }
            let strings = try values.map { value -> String in
                guard let text = value as? String else {
                    throw ServerStateError.invalidValue("searchIndexExclusions must contain strings.")
                }
                return text
            }
            _ = try LegacyServerSettingField.encodeSearchIndexExclusions(strings)
            exclusions = strings
        } else {
            exclusions = nil
        }

        let before = backend.snapshot()
        try backend.updateServerState { state in
            if let serverName { state.identity.name = serverName }
            if let description { state.identity.description = description }
            if let maxConnections {
                guard maxConnections > 0 else {
                    throw ServerStateError.invalidValue("maxConnections must be greater than zero.")
                }
                state.advanced.maxConnections = UInt16(maxConnections)
            }
            if let maxConnectionsPerIP {
                guard maxConnectionsPerIP > 0 else {
                    throw ServerStateError.invalidValue("maxConnectionsPerIP must be greater than zero.")
                }
                state.advanced.maxConnectionsPerIP = UInt16(maxConnectionsPerIP)
            }
            if let maxTransfers {
                guard maxTransfers > 0 else {
                    throw ServerStateError.invalidValue("maxSimultaneousFileTransfers must be greater than zero.")
                }
                state.advanced.maxSimultaneousFileTransfers = UInt16(maxTransfers)
            }
            if let maxUserTransfers {
                guard maxUserTransfers > 0 else {
                    throw ServerStateError.invalidValue("maxFileTransfersPerUser must be greater than zero.")
                }
                state.advanced.maxFileTransfersPerUser = UInt16(maxUserTransfers)
            }
            if let maxFolderDepth { state.advanced.maxFolderDownloadDepth = UInt16(maxFolderDepth) }
            if let rebuildHours { state.runtime.searchIndexRebuildIntervalHours = UInt32(rebuildHours) }
            if let exclusions { state.runtime.searchIndexExclusions = exclusions }
            try ServerStateValidator.validate(identity: state.identity)
            try ServerStateValidator.validate(advanced: state.advanced)
        }
        let after = backend.snapshot()
        try persistStartupConfigurationToJSON(after)
        if before.runtime.searchIndexRebuildIntervalHours != after.runtime.searchIndexRebuildIntervalHours {
            refreshSearchIndexRebuildSchedule()
        }
        if before.runtime.searchIndexExclusions != after.runtime.searchIndexExclusions {
            log("Search-index exclusions updated through HTTP administration; removals take full effect on the next manual or scheduled rebuild")
        }
        onStateChanged?()
        log("Server settings updated through HTTP administration API")
    }

    private func httpAdminCreateAccount(_ object: [String: Any]) throws -> ServerAccount {
        let login = try httpAdminString(object, key: "login", maximumUTF8Bytes: 255, required: true)!
        let suppliedName = try httpAdminString(object, key: "name", maximumUTF8Bytes: 511)
        let password = try httpAdminString(object, key: "password", maximumUTF8Bytes: 1024, required: true)!
        let snapshot = backend.snapshot()
        let groupID: UUID
        if let raw = try httpAdminString(object, key: "groupID", maximumUTF8Bytes: 63) {
            guard let parsed = UUID(uuidString: raw) else {
                throw ServerStateError.invalidValue("groupID is invalid.")
            }
            groupID = parsed
        } else {
            groupID = ServerState.builtInMemberGroupID
        }
        guard let group = snapshot.accountGroups.first(where: { $0.id == groupID }) else {
            throw ServerStateError.accountGroupNotFound(groupID)
        }
        let bits = try httpAdminUInt64(object, key: "permissionBits", maximum: UInt64(Int64.max))
        let color = try httpAdminUInt64(object, key: "colorRGB", maximum: 0x00ff_ffff)
        var account = ServerAccount(
            login: login,
            name: suppliedName ?? login,
            mode: group.legacyMode,
            groupID: groupID,
            personalDirectory: bits.map { httpAdminPersonalDirectory(bits: $0) } ?? .none,
            permissions: bits.map { httpAdminPermissions(bits: $0) } ?? group.permissions,
            colorRGB: color.map(UInt32.init)
        )
        account.permissionsOverrideGroupDefaults = bits == nil ? false : nil
        let saved = try backend.createAccount(account, password: password)
        try synchronizePersonalDirectory(oldAccount: nil, newAccount: saved)
        refreshConnectedAccountsFromBackendAndBroadcastColor()
        onStateChanged?()
        log("Account created through HTTP administration API: \(saved.login)")
        return saved
    }

    private func httpAdminPatchAccount(login: String, _ object: [String: Any]) throws -> ServerAccount? {
        let snapshot = backend.snapshot()
        guard let existing = snapshot.accounts.first(where: {
            $0.login.compare(login, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { return nil }

        var replacement = existing
        if let value = try httpAdminString(object, key: "login", maximumUTF8Bytes: 255) {
            guard !value.isEmpty else { throw ServerStateError.invalidValue("login must not be empty.") }
            replacement.login = value
        }
        if let value = try httpAdminString(object, key: "name", maximumUTF8Bytes: 511) {
            replacement.name = value
        }
        if let value = try httpAdminString(object, key: "groupID", maximumUTF8Bytes: 63) {
            guard let id = UUID(uuidString: value),
                  let group = snapshot.accountGroups.first(where: { $0.id == id }) else {
                throw ServerStateError.invalidValue("groupID is invalid.")
            }
            replacement.groupID = id
            replacement.mode = group.legacyMode
        }
        if let bits = try httpAdminUInt64(object, key: "permissionBits", maximum: UInt64(Int64.max)) {
            replacement.permissions = httpAdminPermissions(bits: bits)
            replacement.personalDirectory = httpAdminPersonalDirectory(bits: bits)
        }
        if let color = try httpAdminUInt64(object, key: "colorRGB", maximum: 0x00ff_ffff) {
            replacement.colorRGB = UInt32(color)
        }
        let password = try httpAdminString(object, key: "password", maximumUTF8Bytes: 1024)
        let saved = try backend.updateAccount(id: existing.id, with: replacement, newPassword: password)
        try synchronizePersonalDirectory(oldAccount: existing, newAccount: saved)
        refreshConnectedAccountsFromBackendAndBroadcastColor()
        onStateChanged?()
        log("Account modified through HTTP administration API: \(saved.login)")
        return saved
    }

    private func httpAdminDeleteAccount(login: String) throws -> Bool {
        let snapshot = backend.snapshot()
        guard let account = snapshot.accounts.first(where: {
            $0.login.compare(login, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { return false }
        try backend.deleteAccount(id: account.id)
        refreshConnectedAccountsFromBackendAndBroadcastColor()
        onStateChanged?()
        log("Account deleted through HTTP administration API: \(account.login)")
        return true
    }

    private enum HTTPAdminConferenceCreateResult {
        case success(UInt32)
        case duplicate
    }

    private func httpAdminCreateConference(_ object: [String: Any]) throws -> HTTPAdminConferenceCreateResult {
        let name = try httpAdminString(object, key: "name", maximumUTF8Bytes: 255, required: true)!
        let password = try httpAdminString(object, key: "password", maximumUTF8Bytes: 255) ?? ""
        guard let nameData = name.data(using: .macOSRoman), !nameData.isEmpty, nameData.count <= 64,
              let passwordData = password.data(using: .macOSRoman), passwordData.count <= 32 else {
            throw ServerStateError.invalidValue("Conference name/password exceeds Classic MacRoman limits.")
        }
        let permanent: Bool
        if let raw = object["permanent"] {
            guard let value = raw as? Bool else {
                throw ServerStateError.invalidValue("permanent must be a boolean.")
            }
            permanent = value
        } else {
            permanent = true
        }
        let restricted: Bool
        if let raw = object["restrictedChat"] {
            guard let value = raw as? Bool else {
                throw ServerStateError.invalidValue("restrictedChat must be a boolean.")
            }
            restricted = value
        } else {
            restricted = false
        }

        stateLock.lock()
        if channels.values.contains(where: { channelNameEquals($0.name, nameData) }) {
            stateLock.unlock()
            return .duplicate
        }
        let id = nextAvailableChannelIDLocked()
        var channel = RuntimeChannel(id: id, name: nameData, password: passwordData)
        if permanent { channel.flags |= Self.channelPermanentFlag }
        if restricted { channel.flags |= Self.channelRestrictedChatFlag }
        channels[id] = channel
        stateLock.unlock()
        log("Channel \(id) created through HTTP administration API")
        return .success(id)
    }

    private func httpAdminDeleteConference(id: UInt32) -> Bool {
        guard id != Self.publicChannelID else { return false }
        stateLock.lock()
        guard let channel = channels.removeValue(forKey: id) else {
            stateLock.unlock()
            return false
        }
        let memberIDs = channel.members.keys.sorted()
        let classicMembers = memberIDs.compactMap { authenticatedByUserID[$0] }.filter { $0.isLegacyTransport }
        let modernRecipients = authenticatedByUserID.values.filter { !$0.isLegacyTransport }
        stateLock.unlock()

        for classic in classicMembers {
            for userID in memberIDs {
                let left = LegacyPacket(command: LegacyCommand.channelUserLeft, transactionID: 0, fields: [
                    LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(id)),
                    LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
                ])
                try? classic.sendAuthenticated(left)
            }
        }
        let deleted = LegacyPacket(command: LegacyCommand.channelDeleted, transactionID: 0, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(id)),
            LegacyTLV(type: LegacyChannelField.name, value: channel.name),
        ])
        modernRecipients.forEach { try? $0.sendAuthenticated(deleted) }
        log("Channel \(id) deleted through HTTP administration API")
        return true
    }

    private func httpAdminBroadcast(_ message: String) throws {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, message.utf8.count <= 509 else {
            throw ServerStateError.invalidValue("Broadcast message must contain 1 to 509 UTF-8 bytes.")
        }
        let wire = try CarrachoTextWire.encode(message, maximumBytes: 0x200)
        stateLock.lock()
        let recipients = Array(authenticatedByUserID.values)
        let senderID = localBotSession?.userID ?? 0
        stateLock.unlock()

        for recipient in recipients {
            let outbound: Data
            if recipient.isLegacyTransport, CarrachoTextWire.isTaggedUTF8(wire) {
                guard let classic = CarrachoTextWire.macRomanDescribingEmoji(from: wire, maximumBytes: 0x200),
                      !classic.isEmpty else { continue }
                outbound = classic
            } else {
                outbound = wire
            }
            try? recipient.sendAuthenticated(LegacyPacket(
                command: LegacyCommand.broadcastMessage,
                transactionID: 0,
                fields: [
                    LegacyTLV(type: 1, value: outbound),
                    LegacyTLV(type: 2, value: LegacyWire.uint32BE(senderID)),
                ]))
        }
        recordMessage()
        log("Broadcast sent through HTTP administration API")
    }

    private func admit(peerIP: String) -> (allowed: Bool, reason: String) {
        let advanced = backend.snapshot().advanced
        if let address = ipv4Data(peerIP) {
            let rules = advanced.ipRestrictions.map(\.legacy)
            do {
                guard try LegacyServerSettingField.ipRestrictionsAllow(rules, address: address) else {
                    return (false, "blocked by Allow/Deny IP policy")
                }
            } catch {
                log("Allow/Deny IP policy could not be evaluated: \(error.localizedDescription)")
                return (false, "invalid Allow/Deny IP policy")
            }
        }
        stateLock.lock(); defer { stateLock.unlock() }
        guard sessions.count < Int(advanced.maxConnections) else { return (false, "maximum connections reached") }
        let sameIP = sessions.values.reduce(0) { $0 + ($1.peerIP == peerIP ? 1 : 0) }
        guard sameIP < Int(advanced.maxConnectionsPerIP) else { return (false, "maximum connections per IP reached") }
        return (true, "")
    }

    fileprivate func authenticateLegacy(loginData: Data,
                                        digest: Data,
                                        nickname: Data,
                                        picture: Data?,
                                        challenge: Data) throws -> LegacyAuthenticatedSession? {
        guard loginData.count <= 63, digest.count == 32, nickname.count <= 255,
              let login = String(data: loginData, encoding: .macOSRoman) else { return nil }
        let storedLegacyPassword = backend.legacyPasswordForLogin(login)
        let candidatePassword = storedLegacyPassword ?? "carracho-invalid-login-placeholder"
        guard let passwordData = candidatePassword.data(using: .macOSRoman) else { return nil }
        let expectedDigest = try LegacyAuthentication.loginDigestHexASCII(password: passwordData, challenge: challenge)
        let digestMatches = Self.constantTimeEqual(digest, expectedDigest)
        guard storedLegacyPassword != nil, digestMatches else { return nil }
        let snapshot = backend.snapshot()
        guard var account = snapshot.accounts.first(where: {
            $0.login.compare(login, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { return nil }

        if let picture, picture.count == Self.classicAvatarMaximumBytes, account.picture != picture {
            try backend.updateServerState { state in
                guard let index = state.accounts.firstIndex(where: { $0.id == account.id }) else {
                    throw ServerStateError.accountNotFound(account.id)
                }
                state.accounts[index].picture = picture
                state.accounts[index].modifiedAt = Date()
                try ServerStateValidator.validate(account: state.accounts[index])
            }
            account.picture = picture
            onStateChanged?()
        }

        let sessionKey = try LegacyAuthentication.deriveSessionKey(password: passwordData, challenge: challenge)
        let effectiveNickname = nickname.isEmpty ? loginData : nickname
        return LegacyAuthenticatedSession(account: account, nickname: effectiveNickname, sessionKey: sessionKey)
    }

    fileprivate func registerAuthenticated(_ session: LegacyServerSession,
                                           authenticated: LegacyAuthenticatedSession) -> LegacyLoginRegistration {
        stateLock.lock()
        let userID = nextUserID
        nextUserID &+= 1
        session.userID = userID
        session.account = authenticated.account
        session.nickname = authenticated.nickname
        session.picture = authenticated.account.picture ?? Data()
        session.sleeping = false
        session.loginAt = Date()
        session.lastActivityAt = session.loginAt
        authenticatedByUserID[userID] = session
        let users = authenticatedByUserID.values.compactMap { $0.userListEntry }
            .sorted { $0.userID < $1.userID }
        let legacyUserIDs = authenticatedByUserID.values.compactMap { current -> UInt32? in
            guard current.isLegacyTransport else { return nil }
            return current.userID
        }.sorted()
        let others = authenticatedByUserID.values.filter { $0 !== session }
        stateLock.unlock()
        recordLoginSuccess(mode: authenticated.account.mode)
        do { try backend.recordSuccessfulLogin(accountID: authenticated.account.id) }
        catch { log("Could not persist last-login timestamp: \(error.localizedDescription)") }
        appendUserEvent(session: session, category: "session", action: "login", detail: "connected")
        emitStatus()
        return LegacyLoginRegistration(userID: userID, users: users, legacyUserIDs: legacyUserIDs, existingSessions: others)
    }

    fileprivate func notifyInitialUserSnapshots(_ recipient: LegacyServerSession,
                                               sessions: [LegacyServerSession]) {
        guard !recipient.isLegacyTransport else { return }
        let state = backend.snapshot()
        for source in sessions.sorted(by: { ($0.userID ?? 0) < ($1.userID ?? 0) }) {
            guard let snapshot = source.userUpdateSnapshot else { continue }
            var fields = [
                LegacyTLV(type: 1, value: LegacyWire.uint32BE(snapshot.userID)),
                LegacyTLV(type: 2, value: snapshot.nickname),
                LegacyTLV(type: LegacyUserInfoField.picture, value: snapshot.picture),
                LegacyTLV(type: LegacyUserInfoField.statusMessage, value: snapshot.statusMessage),
            ]
            if let color = state.accountColorRGB(for: snapshot.account) {
                fields.append(LegacyTLV(type: LegacyUserInfoField.groupColorRGB,
                                        value: LegacyWire.uint32BE(color)))
            }
            try? recipient.sendAuthenticated(LegacyPacket(command: LegacyCommand.userUpdate,
                                                          transactionID: 0,
                                                          fields: fields))
        }
    }

    fileprivate func notifyUserArrived(_ session: LegacyServerSession, to recipients: [LegacyServerSession]) {
        guard let entry = session.userListEntry else { return }

        // Classic accepts the historical optional PNG avatar, but its live-update path caps
        // that field at 0x27c bytes. Feed it a tiny thumbnail instead of a modern 128x128 PNG.
        var classicFields = [
            LegacyTLV(type: 1, value: LegacyWire.uint32BE(entry.userID)),
            LegacyTLV(type: 2, value: entry.nickname),
            LegacyTLV(type: 3, value: LegacyWire.uint16BE(entry.flags)),
        ]
        let classicPicture = Self.classicAvatarPayload(from: entry.picture)
        if !classicPicture.isEmpty {
            classicFields.append(LegacyTLV(type: LegacyUserInfoField.picture, value: classicPicture))
        }
        var modernFields = [
            LegacyTLV(type: 1, value: LegacyWire.uint32BE(entry.userID)),
            LegacyTLV(type: 2, value: entry.nickname),
            LegacyTLV(type: 3, value: LegacyWire.uint16BE(entry.flags)),
        ]
        if !entry.picture.isEmpty {
            modernFields.append(LegacyTLV(type: LegacyUserInfoField.picture, value: entry.picture))
        }
        modernFields.append(LegacyTLV(type: LegacyUserInfoField.statusMessage, value: session.statusMessage))
        if let account = session.account, let color = backend.snapshot().accountColorRGB(for: account) {
            modernFields.append(LegacyTLV(type: LegacyUserInfoField.groupColorRGB,
                                          value: LegacyWire.uint32BE(color)))
        }
        modernFields.append(LegacyTLV(type: LegacyUserInfoField.legacyTransport,
                                      value: Data([session.isLegacyTransport ? 1 : 0])))

        for recipient in recipients {
            let fields = recipient.isLegacyTransport ? classicFields : modernFields
            try? recipient.sendAuthenticated(LegacyPacket(command: LegacyCommand.userArrived,
                                                           transactionID: 0, fields: fields))
        }
    }

    fileprivate func sessionEnded(_ session: LegacyServerSession) {
        var recipients: [LegacyServerSession] = []
        var channelLeaves: [(UInt32, [LegacyServerSession])] = []
        var removedUserID: UInt32?
        var removedMode: ServerAccountMode?

        stateLock.lock()
        sessions.removeValue(forKey: ObjectIdentifier(session))
        if let userID = session.userID {
            removedUserID = userID
            removedMode = session.account?.mode
            authenticatedByUserID.removeValue(forKey: userID)
            for channelID in Array(channels.keys) {
                guard var channel = channels[channelID], channel.members.removeValue(forKey: userID) != nil else { continue }
                let channelRecipients = channel.members.keys.compactMap { authenticatedByUserID[$0] }
                channelLeaves.append((channelID, channelRecipients))
                if channel.members.isEmpty && channelID != Self.publicChannelID &&
                    (channel.flags & Self.channelPermanentFlag) == 0 {
                    channels.removeValue(forKey: channelID)
                } else {
                    channels[channelID] = channel
                }
            }
            recipients = Array(authenticatedByUserID.values)
        }
        stateLock.unlock()

        if let userID = removedUserID {
            // Classic keeps conference rows tied to the global user object. Emit 0x88 while that
            // identity still exists in the peer's user list, then follow with global 0x08.
            // This is the ordering used by Server 1.0b13 and prevents ghost conference members.
            for (channelID, channelRecipients) in channelLeaves {
                let left = LegacyPacket(command: LegacyCommand.channelUserLeft, transactionID: 0, fields: [
                    LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
                    LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
                ])
                channelRecipients.forEach { try? $0.sendAuthenticated(left) }
            }
            let disconnected = LegacyPacket(command: LegacyCommand.userDisconnected, transactionID: 0,
                                            fields: [LegacyTLV(type: 1, value: LegacyWire.uint32BE(userID))])
            recipients.forEach { try? $0.sendAuthenticated(disconnected) }
            if let removedMode { recordDisconnect(mode: removedMode) }
        }
        if removedUserID != nil {
            appendUserEvent(session: session, category: "session", action: "logout", detail: "disconnected")
        }
        emitStatus()
        log("Connection from \(session.peerIP) closed")
    }

    fileprivate func loginSuccessPacket(registration: LegacyLoginRegistration,
                                        account: ServerAccount,
                                        modernSalt: Data? = nil,
                                        modernServerPublicKey: Data? = nil,
                                        modernAuthenticator: Data? = nil) throws -> LegacyPacket {
        let snapshot = backend.snapshot()
        let permissionBytes = [UInt8](account.permissionBytes(includeCarrachoExtensions: modernSalt != nil))
        let word0 = permissionBytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let word1 = permissionBytes.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let session = LegacyLoginSessionInfo(userID: registration.userID,
                                             permissionWord0: word0,
                                             permissionWord1: word1)
        let filesRootName = snapshot.accountGroup(for: account)?.effectiveFilesRootName
            ?? LegacyFilesRootCapability.defaultDisplayName
        var loginUsers = registration.users
        if modernSalt != nil {
            // A login TLV has a 16-bit payload length. Avatars are delivered immediately after
            // modern login as individual user-update events so the packed user list can never be
            // blown past 65535 bytes by one or more 128×128 PNGs.
            for index in loginUsers.indices { loginUsers[index].picture = Data() }
        } else {
            // Classic builds 8-bit 16x16 CIcons while constructing the initial user list. Large
            // modern 128x128 PNGs can render as palette garbage on the first connection, even
            // though the same image works after reconnect. Keep the initial snapshot in the
            // small PNG range used by the original client.
            for index in loginUsers.indices {
                loginUsers[index].picture = Self.classicAvatarPayload(from: loginUsers[index].picture)
            }
        }
        var encodedUsers = try LegacyPackedRecords.encodeUserList(loginUsers)
        if encodedUsers.count > Int(UInt16.max) {
            for index in loginUsers.indices { loginUsers[index].picture = Data() }
            encodedUsers = try LegacyPackedRecords.encodeUserList(loginUsers)
        }
        guard encodedUsers.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("login user list exceeds TLV limit")
        }

        var fields = [
            LegacyTLV(type: 1, value: session.encoded()),
            LegacyTLV(type: 2, value: Self.macRoman(snapshot.identity.name)),
            LegacyTLV(type: 3, value: encodedUsers),
            LegacyTLV(type: 0x21, value: LegacyWire.uint16BE(snapshot.advanced.maxFileTransfersPerUser)),
            LegacyTLV(type: 5, value: LegacyWire.uint16BE(modernSalt == nil ? 2 : CarrachoModernCrypto.transferProtocolVersion)),
            LegacyTLV(type: LegacyMediaCapability.loginFieldType,
                      value: LegacyWire.uint32BE(modernSalt == nil ? 0 : LegacyMediaCapability.current)),
            LegacyTLV(type: LegacyFilesRootCapability.loginFieldType, value: Data(filesRootName.utf8)),
        ]
        if modernSalt != nil {
            fields.append(LegacyTLV(type: LegacyMessageEdit.capability, value: Data([1])))
            fields.append(LegacyTLV(type: LegacyUserTransportCapability.loginFieldType,
                                    value: LegacyUserTransportCapability.encodeLegacyUserIDs(registration.legacyUserIDs)))
        }
        if let modernSalt { fields.append(LegacyTLV(type: 6, value: modernSalt)) }
        if let modernServerPublicKey { fields.append(LegacyTLV(type: 7, value: modernServerPublicKey)) }
        if let modernAuthenticator { fields.append(LegacyTLV(type: 8, value: modernAuthenticator)) }
        if snapshot.agreement.enabled {
            let isClassic = modernSalt == nil
            let agreementText = isClassic
                ? Self.classicAgreementText(snapshot.agreement.text)
                : Self.macRoman(snapshot.agreement.text)
            let agreement = LegacyAgreementContent(
                text: agreementText,
                styleData: isClassic ? Self.classicAgreementStyleData() : Data()
            )
            fields.append(LegacyTLV(type: 4, value: try agreement.encoded()))
        }
        return LegacyPacket(command: LegacyCommand.loginSuccess, transactionID: 0, fields: fields)
    }

    fileprivate func handleAuthenticated(_ packet: LegacyPacket, from session: LegacyServerSession) throws {
        // Classic Client 1.0b10r4 emits exactly this empty command from TClientThread::DoIdle.
        // Treat only the historical shape as a no-op so malformed 0xffffffff packets remain visible.
        if packet.command == LegacyCommand.idleKeepAlive,
           packet.transactionID == 0, packet.reserved == 0, packet.fields.isEmpty {
            return
        }

        noteUserActivity(command: packet.command, session: session)
        recordUserRequestEvent(packet, session: session)
        switch packet.command {
        case LegacyCommand.serverInfo:
            let state = backend.snapshot()
            stateLock.lock()
            let began = startedAt
            let activeTransfers = activeFileTransfers
            let ownActiveTransfers = session.userID.map { activeFileTransfersByUser[$0, default: 0] } ?? 0
            stateLock.unlock()
            let ticks = began.map { UInt64(max(0, Date().timeIntervalSince($0)) * 60) } ?? 0
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.8"
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.serverInfo,
                                                        transactionID: packet.transactionID,
                                                        fields: [
                LegacyTLV(type: LegacyServerInfoField.serverName, value: Self.macRoman(state.identity.name)),
                LegacyTLV(type: LegacyServerInfoField.serverLocation, value: Self.macRoman(state.identity.location)),
                LegacyTLV(type: LegacyServerInfoField.systemOperator, value: Self.macRoman(state.identity.operatorName)),
                LegacyTLV(type: LegacyServerInfoField.description, value: Self.macRoman(state.identity.description)),
                LegacyTLV(type: LegacyServerInfoField.softwareVersion, value: Self.macRoman("Carracho Server \(version)")),
                LegacyTLV(type: LegacyServerInfoField.uptimeTicks,
                          value: LegacyWire.uint32BE(UInt32(min(ticks, UInt64(UInt32.max))))),
                LegacyTLV(type: LegacyServerInfoField.maxSimultaneousFileTransfers,
                          value: LegacyWire.uint16BE(state.advanced.maxSimultaneousFileTransfers)),
                LegacyTLV(type: LegacyServerInfoField.activeFileTransfers,
                          value: LegacyWire.uint16BE(UInt16(clamping: activeTransfers))),
                LegacyTLV(type: LegacyServerInfoField.maxFileTransfersPerUser,
                          value: LegacyWire.uint16BE(state.advanced.maxFileTransfersPerUser)),
                LegacyTLV(type: LegacyServerInfoField.activeFileTransfersForUser,
                          value: LegacyWire.uint16BE(UInt16(clamping: ownActiveTransfers))),
            ]))

        case LegacyCommand.directory:
            let path = packet.firstField(type: 1)?.value ?? Data()
            let listing = try directoryListing(path: path, account: session.account,
                                               supportsTaggedUTF8Names: session.supportsTaggedUTF8FileNames,
                                               legacyTransport: session.isLegacyTransport)
            var fields = [LegacyTLV(type: 2, value: try listing.encoded())]
            // Never alter the Classic packed directory record. Modern peers receive one
            // out-of-band label byte per entry; legacy clients therefore remain byte-for-byte
            // compatible with the historical listing payload.
            if !session.isLegacyTransport {
                fields.append(LegacyTLV(type: LegacyFileLabelField.directoryLabels,
                                        value: Data(listing.entries.map { $0.label.rawValue })))
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.directory,
                                                        transactionID: packet.transactionID,
                                                        fields: fields))

        case LegacyCommand.disconnectUser:
            try handleDisconnectUser(packet: packet, session: session)
        case LegacyCommand.banUser:
            try handleBanUser(packet: packet, session: session)
        case LegacyCommand.privateMessage:
            try handlePrivateMessage(packet: packet, session: session)
        case LegacyCommand.messageEdit:
            try handleMessageEdit(packet: packet, session: session)
        case LegacyCommand.offlineMessageSend:
            try handleOfflineMessageSend(packet: packet, session: session)
        case LegacyCommand.offlineMessageFetch:
            try handleOfflineMessageFetch(packet: packet, session: session)
        case LegacyCommand.offlineMessageAcknowledge:
            try handleOfflineMessageAcknowledge(packet: packet, session: session)
        case LegacyCommand.offlineMessageRecipients:
            try handleOfflineMessageRecipients(packet: packet, session: session)
        case LegacyCommand.offlineMessagePreference:
            try handleOfflineMessagePreference(packet: packet, session: session)
        case LegacyCommand.extendedOwnUserInfo:
            try handleExtendedOwnUserInfo(packet: packet, session: session)
        case LegacyCommand.userInfo:
            try handleUserInfo(packet: packet, session: session)
        case LegacyCommand.userUpdate:
            try handleUserUpdate(packet: packet, session: session)
        case LegacyCommand.userPresenceState:
            try handlePresence(packet: packet, session: session)

        case LegacyCommand.createFolder:
            try handleCreateFolder(packet: packet, session: session)
        case LegacyCommand.deleteFile:
            try handleDeleteFile(packet: packet, session: session)
        case LegacyCommand.fileInfo:
            try handleFileInfo(packet: packet, session: session)
        case LegacyCommand.setFileInfo:
            try handleSetFileInfo(packet: packet, session: session)
        case LegacyCommand.fileLabelSet:
            try handleSetFileLabel(packet: packet, session: session)
        case LegacyCommand.moveFile:
            try handleMoveFile(packet: packet, session: session)
        case LegacyCommand.emptyTrash:
            try handleEmptyTrash(packet: packet, session: session)

        case LegacyCommand.channelList:
            stateLock.lock()
            let summaries = channels.values.sorted { $0.id < $1.id }.map {
                let listFlags = $0.flags | ($0.password.isEmpty ? 0 : LegacyChannelSummary.passwordProtectedFlag)
                return LegacyChannelSummary(channelID: $0.id, memberCount: UInt32($0.members.count), flags: listFlags, name: $0.name)
            }
            stateLock.unlock()
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.channelList,
                                                        transactionID: packet.transactionID,
                                                        fields: [LegacyTLV(type: 0x0a, value: try LegacyPackedRecords.encodeChannelList(summaries))]))

        case LegacyCommand.newsgroupList:
            let state = backend.snapshot()
            let names = state.newsgroups.filter { group in
                guard let account = session.account else { return false }
                switch account.mode {
                case .administrator: return group.access.administratorsRead
                case .accountHolder: return group.access.accountHoldersRead
                case .guest: return group.access.guestsRead
                }
            }.map { Self.macRoman($0.name) }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.newsgroupListReply,
                                                        transactionID: packet.transactionID,
                                                        fields: [LegacyTLV(type: 1, value: try LegacyPackedRecords.encodeNewsgroupList(names))]))

        case LegacyCommand.articleRead:
            try sendArticle(packet: packet, session: session)
        case LegacyCommand.forumThreadList:
            try sendForumThreadList(packet: packet, session: session)
        case LegacyCommand.forumThreadEntries:
            try sendForumThreadEntries(packet: packet, session: session)
        case LegacyCommand.forumArticleReactions:
            try sendForumArticleReactions(packet: packet, session: session)
        case LegacyCommand.forumArticleReactionSet:
            try setForumArticleReaction(packet: packet, session: session)
        case LegacyCommand.forumArticleDelete:
            try deleteForumPost(packet: packet, session: session)

        case LegacyCommand.articleDelete:
            try deleteArticle(packet: packet, session: session)

        case LegacyCommand.adminNewsgroupList:
            try handleAdminNewsgroupList(packet: packet, session: session)
        case LegacyCommand.newsgroupCreate:
            try handleNewsgroupCreate(packet: packet, session: session)
        case LegacyCommand.newsgroupModify:
            try handleNewsgroupModify(packet: packet, session: session)
        case LegacyCommand.newsgroupDelete:
            try handleNewsgroupDelete(packet: packet, session: session)

        case LegacyCommand.accountList:
            try handleAccountList(packet: packet, session: session)
        case LegacyCommand.getAccount:
            try handleGetAccount(packet: packet, session: session)
        case LegacyCommand.accountCreateOrModify:
            try handleAccountCreateOrModify(packet: packet, session: session)
        case LegacyCommand.accountDelete:
            try handleAccountDelete(packet: packet, session: session)
        case LegacyCommand.changeOwnPassword:
            try handleChangeOwnPassword(packet: packet, session: session)
        case LegacyCommand.botStatusRequest:
            try handleBotStatusRequest(packet: packet, session: session)
        case LegacyCommand.botSetEnabled:
            try handleBotSetEnabled(packet: packet, session: session)
        case LegacyCommand.botSetGreeting:
            try handleBotSetGreeting(packet: packet, session: session)
        case LegacyCommand.botSetCommandRules:
            try handleBotSetCommandRules(packet: packet, session: session)
        case LegacyCommand.botSetRSSFeeds:
            try handleBotSetRSSFeeds(packet: packet, session: session)
        case LegacyCommand.botTestRSSFeed:
            try handleBotTestRSSFeed(packet: packet, session: session)
        case LegacyCommand.botSetFileWatchers:
            try handleBotSetFileWatchers(packet: packet, session: session)

        case LegacyCommand.requestServerSettings:
            try handleServerSettingsRequest(packet: packet, session: session)
        case LegacyCommand.setServerSettings:
            try handleServerSettingsUpdate(packet: packet, session: session)
        case LegacyCommand.serverLogRequest:
            try handleServerLogRequest(packet: packet, session: session)
        case LegacyCommand.serverLogClear:
            try handleServerLogClear(packet: packet, session: session)
        case LegacyCommand.eventLogRequest:
            try handleEventLogRequest(packet: packet, session: session)
        case LegacyCommand.eventLogClear:
            try handleEventLogClear(packet: packet, session: session)
        case LegacyCommand.rebuildSearchIndex:
            try handleRemoteSearchIndexRebuild(packet: packet, session: session)
        case LegacyCommand.searchIndexStatusRequest:
            try handleSearchIndexStatusRequest(packet: packet, session: session)

        case LegacyCommand.transferInfo:
            try handleTransferInfo(packet: packet, session: session)

        case LegacyCommand.flatNewsPost:
            try handleFlatNewsPost(packet: packet, session: session)
        case LegacyCommand.flatNewsList:
            try handleFlatNewsList(packet: packet, session: session)
        case LegacyCommand.flatNewsDelete:
            try handleFlatNewsDelete(packet: packet, session: session)
        case LegacyCommand.flatNewsClear:
            try handleFlatNewsClear(packet: packet, session: session)

        case LegacyCommand.broadcastMessage:
            try handleBroadcastMessage(packet: packet, session: session)

        case LegacyCommand.channelJoin:
            try handleChannelJoin(packet: packet, session: session)
        case LegacyCommand.channelLeave:
            try handleChannelLeave(packet: packet, session: session)
        case LegacyCommand.channelChat:
            try handleChannelChat(packet: packet, session: session)
        case LegacyCommand.channelSettings:
            try handleChannelSettings(packet: packet, session: session)
        case LegacyCommand.channelUserMode:
            try handleChannelUserMode(packet: packet, session: session)
        case LegacyCommand.channelInvite:
            try handleChannelInvite(packet: packet, session: session)
        case LegacyCommand.channelDeclineInvitation:
            try handleChannelDeclineInvitation(packet: packet, session: session)
        case LegacyCommand.channelDelete:
            try handleChannelDelete(packet: packet, session: session)

        default:
            if packet.transactionID != 0 {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            }
            log(String(format: "Unhandled legacy command 0x%08x from user %@", packet.command,
                       session.userID.map(String.init) ?? "?"))
        }
    }

    private static func isUserActivityCommand(_ command: UInt32) -> Bool {
        switch command {
        case LegacyCommand.directory, LegacyCommand.createFolder, LegacyCommand.deleteFile,
             LegacyCommand.fileInfo, LegacyCommand.setFileInfo, LegacyCommand.fileLabelSet, LegacyCommand.moveFile,
             LegacyCommand.emptyTrash,
             LegacyCommand.privateMessage, LegacyCommand.offlineMessageSend,
             LegacyCommand.extendedOwnUserInfo, LegacyCommand.userUpdate,
             LegacyCommand.channelJoin, LegacyCommand.channelLeave, LegacyCommand.channelChat,
             LegacyCommand.messageEdit,
             LegacyCommand.channelSettings, LegacyCommand.channelUserMode, LegacyCommand.channelInvite,
             LegacyCommand.channelDeclineInvitation, LegacyCommand.channelDelete, LegacyCommand.forumArticleDelete,
             LegacyCommand.articleRead, LegacyCommand.forumThreadEntries,
             LegacyCommand.forumArticleReactionSet,
             LegacyCommand.articleDelete, LegacyCommand.flatNewsList, LegacyCommand.flatNewsPost,
             LegacyCommand.flatNewsDelete, LegacyCommand.flatNewsClear,
             LegacyCommand.newsgroupCreate, LegacyCommand.newsgroupModify, LegacyCommand.newsgroupDelete,
             LegacyCommand.rebuildSearchIndex,
             LegacyCommand.broadcastMessage, LegacyCommand.changeOwnPassword:
            return true
        default:
            return false
        }
    }

    private func noteUserActivity(command: UInt32, session: LegacyServerSession) {
        guard Self.isUserActivityCommand(command) else { return }
        markUserActive(session)
    }

    private func markUserActive(_ session: LegacyServerSession) {
        var recipients: [LegacyServerSession] = []
        var userID: UInt32?
        stateLock.lock()
        if let candidateID = session.userID,
           authenticatedByUserID[candidateID] === session {
            session.touchActivity()
            if session.sleeping {
                session.sleeping = false
                userID = candidateID
                recipients = authenticatedByUserID.values.filter { !$0.isLegacyTransport }
            }
        }
        stateLock.unlock()
        guard let userID else { return }
        let event = LegacyPacket(command: LegacyCommand.userPresenceState, transactionID: 0, fields: [
            LegacyTLV(type: LegacyPresenceStateField.userID, value: LegacyWire.uint32BE(userID)),
            LegacyTLV(type: LegacyPresenceStateField.state, value: Data([LegacyPresenceState.awake])),
        ])
        recipients.forEach { try? $0.sendAuthenticated(event) }
    }

    // MARK: - Users, presence and private messages

    private func authenticatedSession(userID: UInt32) -> LegacyServerSession? {
        stateLock.lock(); defer { stateLock.unlock() }
        return authenticatedByUserID[userID]
    }

    private func authenticatedSession(accountID: UUID) -> LegacyServerSession? {
        stateLock.lock(); defer { stateLock.unlock() }
        return authenticatedByUserID.values.first { $0.account?.id == accountID }
    }

    private func authenticatedSessions() -> [LegacyServerSession] {
        stateLock.lock(); defer { stateLock.unlock() }
        return Array(authenticatedByUserID.values)
    }

    private func targetUserID(from packet: LegacyPacket) throws -> UInt32 {
        guard let field = packet.firstField(type: 1) else {
            throw LegacyServerRuntimeError.protocolFailure("missing target user ID")
        }
        return try field.uint32BE()
    }

    private func sendTaskCompleteIfRequested(_ packet: LegacyPacket, to session: LegacyServerSession) throws {
        guard packet.transactionID != 0 else { return }
        try sendTaskComplete(packet, to: session)
    }

    private func handleDisconnectUser(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard session.account?.permissions.contains(.disconnectUsers) == true else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let userID = try targetUserID(from: packet)
            guard userID != session.userID else {
                throw LegacyServerRuntimeError.protocolFailure("a user cannot kick its own session")
            }
            guard let target = authenticatedSession(userID: userID) else {
                throw LegacyServerRuntimeError.protocolFailure("disconnect target is not connected")
            }
            if target.isLocalOnly {
                // The built-in Bot has no TCP connection to kick. Persistently disable it first,
                // otherwise the Bot controller would recreate the synthetic session immediately.
                try setLocalBotDesiredEnabled(false)
                disconnectLocalBot()
                try sendTaskCompleteIfRequested(packet, to: session)
                log("Local Bot disabled through user disconnect by user \(session.userID.map(String.init) ?? "?")")
                return
            }
            try sendTaskCompleteIfRequested(packet, to: session)
            try? target.sendAuthenticated(LegacyPacket(command: LegacyCommand.forceDisconnect, transactionID: 0, fields: []))
            target.close()
            log("User \(userID) disconnected by user \(session.userID.map(String.init) ?? "?")")
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleBanUser(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard session.account?.permissions.contains(.banUsers) == true else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let userID = try targetUserID(from: packet)
            guard userID != session.userID else {
                throw LegacyServerRuntimeError.protocolFailure("a user cannot ban its own session")
            }
            guard let target = authenticatedSession(userID: userID) else {
                throw LegacyServerRuntimeError.protocolFailure("ban target is not connected")
            }
            guard !target.isLocalOnly else {
                throw LegacyServerRuntimeError.protocolFailure("the local Bot cannot be IP-banned")
            }
            guard let address = ipv4Data(target.peerIP) else {
                throw LegacyServerRuntimeError.protocolFailure("Classic persistent bans require an IPv4 address")
            }
            let hostMask = Data(repeating: 0xff, count: 4)
            try backend.updateServerState { state in
                state.advanced.ipRestrictions.removeAll { $0.network == address && $0.mask == hostMask && $0.deny }
                state.advanced.ipRestrictions.insert(ServerIPRestriction(network: address, mask: hostMask, deny: true), at: 0)
                try ServerStateValidator.validate(advanced: state.advanced)
            }
            onStateChanged?()
            try sendTaskCompleteIfRequested(packet, to: session)
            try? target.sendAuthenticated(LegacyPacket(command: LegacyCommand.forceDisconnect, transactionID: 0, fields: []))
            target.close()
            log("User \(userID) / \(target.peerIP) banned by user \(session.userID.map(String.init) ?? "?")")
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handlePrivateMessage(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            guard let senderID = session.userID,
                  let senderAccount = session.account,
                  let message = packet.firstField(type: 2)?.value,
                  !message.isEmpty, message.count <= 0x8000 else {
                throw LegacyServerRuntimeError.protocolFailure("invalid private-message payload")
            }
            let extra = packet.firstField(type: 3)?.value ?? Data()
            guard extra.count <= 0x8000 else {
                throw LegacyServerRuntimeError.protocolFailure("private-message secondary payload exceeds limit")
            }
            let userID = try targetUserID(from: packet)
            guard let target = authenticatedSession(userID: userID),
                  let targetAccount = target.account else {
                throw LegacyServerRuntimeError.protocolFailure("private-message target is not connected")
            }
            let mediaReferences = session.isLegacyTransport
                ? []
                : LegacyMediaReference.references(inWire: message)
            guard mediaReferences.count <= LegacyMediaTransfer.maximumImagesPerPrivateMessage else {
                throw LegacyServerRuntimeError.protocolFailure("too many private-message media attachments")
            }
            if target.isLegacyTransport, !mediaReferences.isEmpty {
                throw LegacyServerRuntimeError.protocolFailure("Classic private messages do not support media attachments")
            }
            if !mediaReferences.isEmpty {
                try validateAndBindMediaReferences(
                    in: message,
                    ownerAccountID: senderAccount.id,
                    maximum: LegacyMediaTransfer.maximumImagesPerPrivateMessage,
                    kind: .privateMessage,
                    scope: targetAccount.id.uuidString.lowercased(),
                    messageID: UUID().uuidString.lowercased(),
                    expiresAt: Date().addingTimeInterval(LegacyMediaTransfer.privateMessageLifetime)
                )
            }
            let wireMessage: Data
            if target.isLegacyTransport, CarrachoTextWire.isTaggedUTF8(message) {
                guard let classic = CarrachoTextWire.macRomanDescribingEmoji(from: message, maximumBytes: 0x8000),
                      !classic.isEmpty else {
                    throw LegacyServerRuntimeError.protocolFailure("private-message text is not Classic-representable")
                }
                wireMessage = classic
            } else {
                wireMessage = message
            }
            let editableID = !session.isLegacyTransport && !target.isLegacyTransport &&
                mediaReferences.isEmpty && extra.isEmpty
                ? LegacyMessageEdit.parseIdentifier(packet.firstField(type: LegacyMessageEdit.messageID)?.value)
                : nil
            let sentAt = Date()
            if let editableID, !registerEditableMessage(id: editableID, senderID: senderID,
                                                        kind: LegacyMessageEdit.privateMessage,
                                                        scope: userID, createdAt: sentAt) {
                throw LegacyServerRuntimeError.protocolFailure("duplicate private-message identifier")
            }
            var fields = [
                LegacyTLV(type: 1, value: LegacyWire.uint32BE(senderID)),
                LegacyTLV(type: 2, value: wireMessage),
            ]
            if !extra.isEmpty { fields.append(LegacyTLV(type: 3, value: extra)) }
            if let editableID {
                fields.append(LegacyTLV(type: LegacyMessageEdit.messageID, value: LegacyMessageEdit.identifier(editableID)))
                fields.append(LegacyTLV(type: LegacyMessageEdit.sentAt,
                                        value: LegacyWire.uint64BE(UInt64(sentAt.timeIntervalSince1970))))
            }
            let targetsLocalBot = target.isLocalOnly
            try target.sendAuthenticated(LegacyPacket(command: LegacyCommand.privateMessage,
                                                       transactionID: 0, fields: fields))
            try sendTaskCompleteIfRequested(packet, to: session)
            recordMessage()
            if targetsLocalBot { respondToLocalBotPrivateCommandIfNeeded(message, from: session) }
        } catch {
            if packet.transactionID != 0 {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            }
        }
    }

    private func handleOfflineMessageSend(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            guard let senderID = session.userID,
                  let senderAccount = session.account,
                  let loginData = packet.firstField(type: 1)?.value,
                  !loginData.isEmpty, loginData.count <= 63,
                  let recipientLogin = String(data: loginData, encoding: .macOSRoman),
                  let message = packet.firstField(type: 2)?.value,
                  !message.isEmpty, message.count <= LegacyOfflineMessage.maximumMessageLength,
                  let recipient = backend.offlineMessageRecipient(login: recipientLogin),
                  recipient.id != senderAccount.id else {
                throw LegacyServerRuntimeError.protocolFailure("invalid offline-message target/payload")
            }

            if let target = authenticatedSession(accountID: recipient.id) {
                let wireMessage: Data
                if target.isLegacyTransport, CarrachoTextWire.isTaggedUTF8(message) {
                    guard let classic = CarrachoTextWire.macRomanDescribingEmoji(
                        from: message,
                        maximumBytes: LegacyOfflineMessage.maximumMessageLength
                    ), !classic.isEmpty else {
                        throw LegacyServerRuntimeError.protocolFailure("offline-message text is not Classic-representable")
                    }
                    wireMessage = classic
                } else {
                    wireMessage = message
                }
                try target.sendAuthenticated(LegacyPacket(command: LegacyCommand.privateMessage,
                                                           transactionID: 0,
                                                           fields: [
                    LegacyTLV(type: 1, value: LegacyWire.uint32BE(senderID)),
                    LegacyTLV(type: 2, value: wireMessage),
                ]))
            } else {
                guard try backend.offlineMessageCount(recipientAccountID: recipient.id) < LegacyOfflineMessage.maximumQueuedMessages else {
                    throw LegacyServerRuntimeError.protocolFailure("offline-message queue is full")
                }
                let payload = LegacyOfflineMessagePayload(senderLogin: Self.macRoman(senderAccount.login),
                                                          senderNickname: session.nickname,
                                                          message: message)
                _ = try backend.enqueueOfflineMessage(recipientAccountID: recipient.id,
                                                      plaintext: try payload.encoded())
            }
            try sendTaskCompleteIfRequested(packet, to: session)
            recordMessage()
        } catch {
            if packet.transactionID != 0 {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            }
        }
    }

    private func handleOfflineMessageRecipients(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            guard let ownAccount = session.account else { throw LegacyServerRuntimeError.protocolFailure("missing account") }
            let accounts = backend.offlineMessageRecipients().filter { $0.id != ownAccount.id }
            let fields = try accounts.map { account -> LegacyTLV in
                let nicknameData: Data
                if let live = authenticatedSession(accountID: account.id) { nicknameData = live.nickname }
                else if let last = account.lastNickname, let encoded = last.data(using: .macOSRoman), !encoded.isEmpty { nicknameData = encoded }
                else { nicknameData = Self.macRoman(account.name.isEmpty ? account.login : account.name) }
                let record = LegacyOfflineMessageRecipient(login: Self.macRoman(account.login), nickname: nicknameData)
                return LegacyTLV(type: 1, value: try record.encoded())
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.offlineMessageRecipients,
                                                        transactionID: packet.transactionID, fields: fields))
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleOfflineMessagePreference(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            guard let account = session.account,
                  let field = packet.firstField(type: 1), field.value.count == 1,
                  let raw = field.value.first, raw <= 1 else {
                throw LegacyServerRuntimeError.protocolFailure("invalid offline-message preference")
            }
            let nickname = String(data: session.nickname, encoding: .macOSRoman)
            let updated = try backend.updateOfflineMessagePreference(accountID: account.id, enabled: raw == 1, nickname: nickname)
            stateLock.lock(); session.account = updated; stateLock.unlock()
            try sendTaskCompleteIfRequested(packet, to: session)
            onStateChanged?()
        } catch {
            if packet.transactionID != 0 {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            }
        }
    }

    private func handleOfflineMessageFetch(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            guard let account = session.account else { throw LegacyServerRuntimeError.protocolFailure("missing account") }
            let stored = try backend.loadOfflineMessages(recipientAccountID: account.id)
            let fields = try stored.map { item -> LegacyTLV in
                let payload = try LegacyOfflineMessagePayload.decode(item.plaintext)
                let wireMessage: Data
                if session.isLegacyTransport, CarrachoTextWire.isTaggedUTF8(payload.message) {
                    guard let classic = CarrachoTextWire.macRomanDescribingEmoji(
                        from: payload.message,
                        maximumBytes: LegacyOfflineMessage.maximumMessageLength
                    ), !classic.isEmpty else {
                        throw LegacyServerRuntimeError.protocolFailure("stored offline-message text is not Classic-representable")
                    }
                    wireMessage = classic
                } else {
                    wireMessage = payload.message
                }
                let record = LegacyOfflineMessage(id: item.id,
                                                  sentAtUnix: item.createdAtUnix,
                                                  senderLogin: payload.senderLogin,
                                                  senderNickname: payload.senderNickname,
                                                  message: wireMessage)
                return LegacyTLV(type: 1, value: try record.encoded())
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.offlineMessageFetch,
                                                        transactionID: packet.transactionID,
                                                        fields: fields))
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleOfflineMessageAcknowledge(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            guard let account = session.account else { throw LegacyServerRuntimeError.protocolFailure("missing account") }
            let ids = packet.fields.filter { $0.type == 1 }.compactMap { String(data: $0.value, encoding: .utf8) }
            guard !ids.isEmpty, ids.count == packet.fields.filter({ $0.type == 1 }).count else {
                throw LegacyServerRuntimeError.protocolFailure("invalid offline-message acknowledgement")
            }
            try backend.acknowledgeOfflineMessages(recipientAccountID: account.id, ids: ids)
            try sendTaskCompleteIfRequested(packet, to: session)
        } catch {
            if packet.transactionID != 0 {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            }
        }
    }

    fileprivate func notifyOfflineMessagesIfNeeded(_ session: LegacyServerSession) {
        guard let account = session.account else { return }
        do {
            let count = try backend.offlineMessageCount(recipientAccountID: account.id)
            guard count > 0 else { return }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.offlineMessageNotice,
                                                        transactionID: 0,
                                                        fields: [LegacyTLV(type: 1, value: LegacyWire.uint32BE(UInt32(min(count, Int(UInt32.max)))))]))
        } catch {
            log("Could not announce stored offline messages for \(account.login): \(error.localizedDescription)")
        }
    }

    private func legacyProfileString(_ field: LegacyTLV?, maximum: Int, label: String) throws -> String? {
        guard let field else { return nil }
        guard field.value.count <= maximum,
              let value = String(data: field.value, encoding: .macOSRoman) else {
            throw LegacyServerRuntimeError.protocolFailure("invalid \(label) profile field")
        }
        return value
    }

    private func handleExtendedOwnUserInfo(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let account = session.account else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let name = try legacyProfileString(packet.firstField(type: LegacyUserInfoField.name), maximum: 64, label: "name")
            let email = try legacyProfileString(packet.firstField(type: LegacyUserInfoField.email), maximum: 64, label: "e-mail")
            let about = try legacyProfileString(packet.firstField(type: LegacyUserInfoField.aboutMe), maximum: 128, label: "about-me")
            guard name != nil || email != nil || about != nil else {
                throw LegacyServerRuntimeError.protocolFailure("empty extended-user update")
            }
            try backend.updateServerState { state in
                guard let index = state.accounts.firstIndex(where: { $0.id == account.id }) else {
                    throw ServerStateError.accountNotFound(account.id)
                }
                if let name { state.accounts[index].profileName = name.isEmpty ? nil : name }
                if let email { state.accounts[index].email = email.isEmpty ? nil : email }
                if let about { state.accounts[index].aboutMe = about.isEmpty ? nil : about }
                state.accounts[index].modifiedAt = Date()
                try ServerStateValidator.validate(account: state.accounts[index])
            }
            let updated = backend.snapshot().accounts.first(where: { $0.id == account.id })
            stateLock.lock(); if let updated { session.account = updated }; stateLock.unlock()
            onStateChanged?()
            try sendTaskCompleteIfRequested(packet, to: session)
        } catch {
            if packet.transactionID != 0 {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            }
        }
    }

    private func ipv4Data(_ address: String) -> Data? {
        let normalized: String
        if address == "::1" { normalized = "127.0.0.1" }
        else if let range = address.range(of: "::ffff:", options: [.caseInsensitive]) {
            normalized = String(address[range.upperBound...])
        } else { normalized = address }
        let parts = normalized.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            bytes.append(octet)
        }
        return Data(bytes)
    }

    private func ipv4Value(_ address: String) -> UInt32? {
        guard let data = ipv4Data(address) else { return nil }
        return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func handleUserInfo(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            let userID = try targetUserID(from: packet)
            guard let target = authenticatedSession(userID: userID), let account = target.account else {
                throw LegacyServerRuntimeError.protocolFailure("user-info target is not connected")
            }
            let profileName = account.profileName?.isEmpty == false ? account.profileName! : account.name
            var fields = [
                LegacyTLV(type: LegacyUserInfoField.nickname, value: target.nickname),
                LegacyTLV(type: LegacyUserInfoField.name, value: Self.macRoman(profileName)),
                LegacyTLV(type: LegacyUserInfoField.email, value: Self.macRoman(account.email ?? "")),
                LegacyTLV(type: LegacyUserInfoField.aboutMe, value: Self.macRoman(account.aboutMe ?? "")),
                LegacyTLV(type: LegacyUserInfoField.picture, value: target.picture),
                LegacyTLV(type: LegacyUserInfoField.statusMessage, value: target.statusMessage),
            ]
            if let color = backend.snapshot().accountColorRGB(for: account) {
                fields.append(LegacyTLV(type: LegacyUserInfoField.groupColorRGB, value: LegacyWire.uint32BE(color)))
            }
            fields.append(LegacyTLV(type: LegacyUserInfoField.legacyTransport,
                                    value: Data([target.isLegacyTransport ? 1 : 0])))
            let idleSeconds = max(0, Date().timeIntervalSince(target.lastActivityAt))
            let idleTicks = UInt32(min(idleSeconds * 60, TimeInterval(UInt32.max)))
            fields.append(LegacyTLV(type: LegacyUserInfoField.idleTime, value: LegacyWire.uint32BE(idleTicks)))
            if session.account?.permissions.contains(.extendedUserInfo) == true {
                fields.append(LegacyTLV(type: LegacyUserInfoField.ipAddress,
                                        value: LegacyWire.uint32BE(ipv4Value(target.peerIP) ?? 0)))
                fields.append(LegacyTLV(type: LegacyUserInfoField.loginTime,
                                        value: LegacyWire.uint32BE(target.loginAt.legacyMacTimestamp)))
                let tasks = activeTransferTasks(userID: userID)
                fields.append(LegacyTLV(type: LegacyUserInfoField.taskList,
                                        value: try LegacyPackedRecords.encodeCompactTaskList(tasks)))
                fields.append(LegacyTLV(type: LegacyUserInfoField.loginName, value: Self.macRoman(account.login)))
                if !target.clientOperatingSystem.isEmpty { fields.append(LegacyTLV(type: LegacyClientMetadataField.operatingSystem, value: target.clientOperatingSystem)) }
                if !target.clientCPUArchitecture.isEmpty { fields.append(LegacyTLV(type: LegacyClientMetadataField.cpuArchitecture, value: target.clientCPUArchitecture)) }
                if !target.clientVersion.isEmpty { fields.append(LegacyTLV(type: LegacyClientMetadataField.clientVersion, value: target.clientVersion)) }
                if !target.clientBuild.isEmpty { fields.append(LegacyTLV(type: LegacyClientMetadataField.clientBuild, value: target.clientBuild)) }
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.userInfo,
                                                        transactionID: packet.transactionID, fields: fields))
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleUserUpdate(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let userID = session.userID, let account = session.account else { return }
        do {
            let nickname = packet.firstField(type: 2)?.value ?? session.nickname
            let pictureField = packet.firstField(type: 5)
            let picture = pictureField?.value ?? session.picture
            let statusMessage = packet.firstField(type: LegacyUserInfoField.statusMessage)?.value ?? session.statusMessage
            guard !nickname.isEmpty, nickname.count <= 64, picture.count <= LegacyUserInfoField.maximumPictureLength,
                  statusMessage.count <= 255 else {
                throw LegacyServerRuntimeError.protocolFailure("invalid user-update payload")
            }
            var updated: ServerAccount?
            if let nicknameText = String(data: nickname, encoding: .macOSRoman), !nicknameText.isEmpty {
                try backend.updateLastNickname(accountID: account.id, nickname: nicknameText)
                updated = backend.snapshot().accounts.first(where: { $0.id == account.id })
            }
            if pictureField != nil {
                try backend.updateServerState { state in
                    guard let index = state.accounts.firstIndex(where: { $0.id == account.id }) else {
                        throw ServerStateError.accountNotFound(account.id)
                    }
                    state.accounts[index].picture = picture.isEmpty ? nil : picture
                    state.accounts[index].modifiedAt = Date()
                    try ServerStateValidator.validate(account: state.accounts[index])
                }
                updated = backend.snapshot().accounts.first(where: { $0.id == account.id })
            }
            stateLock.lock()
            session.nickname = nickname
            session.picture = picture
            session.statusMessage = statusMessage
            if let updated { session.account = updated }
            let recipients = Array(authenticatedByUserID.values)
            stateLock.unlock()
            var classicFields = [
                LegacyTLV(type: 1, value: LegacyWire.uint32BE(userID)),
                LegacyTLV(type: 2, value: nickname),
            ]
            if pictureField != nil {
                classicFields.append(LegacyTLV(type: LegacyUserInfoField.picture,
                                               value: Self.classicAvatarPayload(from: picture)))
            }
            var modernFields = [
                LegacyTLV(type: 1, value: LegacyWire.uint32BE(userID)),
                LegacyTLV(type: 2, value: nickname),
                LegacyTLV(type: LegacyUserInfoField.picture, value: picture),
                LegacyTLV(type: LegacyUserInfoField.statusMessage, value: statusMessage),
            ]
            if let current = session.account, let color = backend.snapshot().accountColorRGB(for: current) {
                modernFields.append(LegacyTLV(type: LegacyUserInfoField.groupColorRGB,
                                              value: LegacyWire.uint32BE(color)))
            }
            for recipient in recipients {
                let fields = recipient.isLegacyTransport ? classicFields : modernFields
                try? recipient.sendAuthenticated(LegacyPacket(command: LegacyCommand.userUpdate,
                                                               transactionID: 0, fields: fields))
            }
            if pictureField != nil { onStateChanged?() }
            try sendTaskCompleteIfRequested(packet, to: session)
        } catch {
            if packet.transactionID != 0 {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            }
        }
    }

    private func handlePresence(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            guard let userID = session.userID,
                  let idField = packet.firstField(type: LegacyPresenceStateField.userID),
                  try idField.uint32BE() == userID,
                  let stateField = packet.firstField(type: LegacyPresenceStateField.state),
                  stateField.value.count == 1, let state = stateField.value.first,
                  state == LegacyPresenceState.awake || state == LegacyPresenceState.sleeping else {
                throw LegacyServerRuntimeError.protocolFailure("invalid presence update")
            }
            stateLock.lock()
            session.touchActivity()
            session.sleeping = state == LegacyPresenceState.sleeping
            let recipients = authenticatedByUserID.values.filter { !$0.isLegacyTransport }
            stateLock.unlock()
            let event = LegacyPacket(command: LegacyCommand.userPresenceState, transactionID: 0, fields: [
                LegacyTLV(type: LegacyPresenceStateField.userID, value: LegacyWire.uint32BE(userID)),
                LegacyTLV(type: LegacyPresenceStateField.state, value: Data([state])),
            ])
            recipients.forEach { try? $0.sendAuthenticated(event) }
            try sendTaskCompleteIfRequested(packet, to: session)
        } catch {
            if packet.transactionID != 0 {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            }
        }
    }

    // MARK: - File control commands


    private func currentFileSearchIndex() -> ServerFileSearchIndex? {
        fileSearchIndexStateLock.lock()
        defer { fileSearchIndexStateLock.unlock() }
        return fileSearchIndex
    }

    private func setCurrentFileSearchIndex(_ index: ServerFileSearchIndex?) {
        fileSearchIndexStateLock.lock()
        fileSearchIndex = index
        fileSearchIndexStateLock.unlock()
    }

    private func prepareFileSearchIndex() {
        guard FileManager.default.fileExists(atPath: fileSearchIndexURL.path) else {
            setCurrentFileSearchIndex(nil)
            log("File-search index not present; filesystem fallback active until manual or scheduled rebuild")
            return
        }
        let index = ServerFileSearchIndex(url: fileSearchIndexURL,
                                          exclusionPatterns: backend.snapshot().runtime.searchIndexExclusions)
        do {
            let count = try index.entryCount()
            let hasCompletedRebuild = try index.lastFullRebuildDate() != nil
            guard count > 0 || hasCompletedRebuild else {
                setCurrentFileSearchIndex(nil)
                log("No completed file-search index yet; filesystem fallback active until manual or scheduled rebuild")
                return
            }
            setCurrentFileSearchIndex(index)
            log("Reusing file-search index: \(count) searchable item(s)")
        } catch {
            setCurrentFileSearchIndex(nil)
            log("Existing file-search index is unavailable; filesystem fallback active until manual or scheduled rebuild: \(error.localizedDescription)")
        }
    }

    private func cancelSearchIndexRebuildSchedule() {
        fileSearchIndexScheduleLock.lock()
        let timer = fileSearchIndexScheduleTimer
        fileSearchIndexScheduleTimer = nil
        fileSearchIndexScheduleLock.unlock()
        timer?.cancel()
    }

    func refreshSearchIndexRebuildSchedule() {
        cancelSearchIndexRebuildSchedule()
        stateLock.lock()
        let isRunning = running
        stateLock.unlock()
        guard isRunning else { return }

        let hours = backend.snapshot().runtime.searchIndexRebuildIntervalHours
        guard hours > 0 else {
            log("Automatic full search-index rebuilds disabled")
            return
        }

        let interval = TimeInterval(hours) * 3600
        let schedulingIndex = currentFileSearchIndex()
            ?? ServerFileSearchIndex(url: fileSearchIndexURL,
                                     exclusionPatterns: backend.snapshot().runtime.searchIndexExclusions)
        let referenceDate = (try? schedulingIndex.rebuildScheduleReferenceDate()) ?? Date()
        let delay = max(1, referenceDate.addingTimeInterval(interval).timeIntervalSinceNow)

        let timer = DispatchSource.makeTimerSource(queue: fileSearchIndexScheduleQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.cancelSearchIndexRebuildSchedule()
            self.rebuildSearchIndexInBackground(reason: "scheduled \(hours)-hour interval")
        }
        fileSearchIndexScheduleLock.lock()
        fileSearchIndexScheduleTimer = timer
        fileSearchIndexScheduleLock.unlock()
        timer.resume()
        log("Next automatic full search-index rebuild scheduled in \(Int(ceil(delay / 3600))) hour(s)")
    }

    private func invalidateFileSearchIndex(reason: String) {
        fileSearchIndexStateLock.lock()
        fileSearchIndex = nil
        fileSearchIndexRebuildGeneration &+= 1
        fileSearchIndexStateLock.unlock()
        log("File-search index disabled after \(reason); filesystem fallback active until manual or scheduled rebuild")
    }

    private func buildFreshSearchIndex() throws -> ServerFileSearchIndex {
        func makeIndex() -> ServerFileSearchIndex {
            ServerFileSearchIndex(url: fileSearchIndexURL,
                                  exclusionPatterns: backend.snapshot().runtime.searchIndexExclusions)
        }
        var index = makeIndex()
        do {
            try index.rebuild(storageRoot: storageRoot, metadata: fileMetadataStore)
            return index
        } catch {
            // Full rebuilds are the one place where replacing a broken disposable cache is
            // intentional. Startup itself never deletes/rebuilds the cache.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: fileSearchIndexURL.path + suffix)
            }
            index = makeIndex()
            try index.rebuild(storageRoot: storageRoot, metadata: fileMetadataStore)
            return index
        }
    }

    /// Invalidates the published cache immediately so searches use the filesystem fallback, then
    /// rebuilds on a utility queue. If files change during the rebuild, the generation changes and
    /// another pass is made before a cache is published. Remote settings requests therefore never
    /// wait for a potentially large Files tree to be indexed.
    private func scheduleFileSearchIndexRebuild(reason: String) {
        fileSearchIndexStateLock.lock()
        fileSearchIndexRebuildGeneration &+= 1
        fileSearchIndex = nil
        if fileSearchIndexRebuildWorkerActive {
            fileSearchIndexStateLock.unlock()
            return
        }
        fileSearchIndexRebuildWorkerActive = true
        fileSearchIndexStateLock.unlock()

        log("File-search index rebuild queued: \(reason)")
        fileSearchIndexRebuildQueue.async { [weak self] in
            self?.runScheduledFileSearchIndexRebuilds()
        }
    }

    private func markFileSearchIndexDirtyDuringRebuild() {
        fileSearchIndexStateLock.lock()
        if fileSearchIndexRebuildWorkerActive { fileSearchIndexRebuildGeneration &+= 1 }
        fileSearchIndexStateLock.unlock()
    }

    private func runScheduledFileSearchIndexRebuilds() {
        while true {
            fileSearchIndexStateLock.lock()
            let generation = fileSearchIndexRebuildGeneration
            fileSearchIndexStateLock.unlock()

            do {
                let index = try buildFreshSearchIndex()
                let count = try index.entryCount()
                fileSearchIndexStateLock.lock()
                if generation == fileSearchIndexRebuildGeneration {
                    fileSearchIndex = index
                    fileSearchIndexRebuildWorkerActive = false
                    fileSearchIndexStateLock.unlock()
                    log("Search inventory rebuilt in background: \(count) searchable item(s)")
                    refreshSearchIndexRebuildSchedule()
                    return
                }
                fileSearchIndexStateLock.unlock()
                log("Files changed during search-index rebuild; repeating background pass")
            } catch {
                fileSearchIndexStateLock.lock()
                let shouldRetry = generation != fileSearchIndexRebuildGeneration
                if !shouldRetry { fileSearchIndexRebuildWorkerActive = false }
                fileSearchIndexStateLock.unlock()
                if shouldRetry { continue }
                log("Background file-search index rebuild failed; filesystem fallback remains active: \(error.localizedDescription)")
                return
            }
        }
    }

    private func refreshSearchIndexSubtree(at url: URL, path: Data, legacyTransport: Bool = false) {
        guard !usesLegacyFilesRoot(legacyTransport: legacyTransport) else { return }
        guard let index = currentFileSearchIndex() else {
            markFileSearchIndexDirtyDuringRebuild()
            return
        }
        do { try index.upsertSubtree(at: url, path: path, metadata: fileMetadataStore) }
        catch {
            log("File-search index update failed for \(LegacyPath.displayString(path)): \(error.localizedDescription)")
            invalidateFileSearchIndex(reason: "incremental update failure")
        }
    }

    private func removeSearchIndexSubtree(path: Data, legacyTransport: Bool = false) {
        guard !usesLegacyFilesRoot(legacyTransport: legacyTransport) else { return }
        guard let index = currentFileSearchIndex() else {
            markFileSearchIndexDirtyDuringRebuild()
            return
        }
        do { try index.removeSubtree(path: path) }
        catch {
            log("File-search index delete failed for \(LegacyPath.displayString(path)): \(error.localizedDescription)")
            invalidateFileSearchIndex(reason: "incremental delete failure")
        }
    }

    private func moveSearchIndexSubtree(from source: Data, to destination: Data, destinationURL: URL, legacyTransport: Bool = false) {
        guard !usesLegacyFilesRoot(legacyTransport: legacyTransport) else { return }
        guard let index = currentFileSearchIndex() else {
            markFileSearchIndexDirtyDuringRebuild()
            return
        }
        do { try index.moveSubtree(from: source, to: destination, destinationURL: destinationURL, metadata: fileMetadataStore) }
        catch {
            log("File-search index move failed: \(error.localizedDescription)")
            invalidateFileSearchIndex(reason: "incremental move failure")
        }
    }

    private func requireFileMetadataStore(legacyTransport: Bool = false) throws -> ServerFileMetadataStore {
        guard let store = metadataStore(legacyTransport: legacyTransport) else {
            throw LegacyServerRuntimeError.protocolFailure("file metadata store is unavailable")
        }
        return store
    }

    private func sendTaskComplete(_ packet: LegacyPacket, to session: LegacyServerSession) throws {
        try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                   transactionID: packet.transactionID, fields: []))
    }

    private func fileControlError(_ error: Error, packet: LegacyPacket, session: LegacyServerSession, operation: String) throws {
        log("\(operation) failed: \(error.localizedDescription)")
        try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
    }

    /// Convert a stored metadata path back into the path an account sees in its Files root.
    /// Account groups can expose a subtree as `/`, so two users may address the exact same file
    /// with different virtual paths (for example `Shared/file` versus just `file`).
    private func virtualFilePath(forMetadataPath metadataPath: Data, account: ServerAccount?) throws -> Data? {
        guard let account else { return metadataPath }

        // A nested personal directory already uses its synthetic ~login path as its metadata key.
        // Leave it untouched; the physical-object check in the broadcaster still prevents another
        // account from receiving an event for a coincidentally equal metadata key.
        if account.personalDirectory == .nestedInRoot,
           let first = try pathComponents(metadataPath).first, first == (try personalVirtualName(for: account)) {
            return metadataPath
        }

        let prefix = try accountFilesRootLegacyPrefix(account)
        guard !prefix.isEmpty else { return metadataPath }
        if metadataPath == prefix { return Data() }
        guard metadataPath.count > prefix.count, metadataPath.starts(with: prefix) else { return nil }
        let separatorIndex = metadataPath.index(metadataPath.startIndex, offsetBy: prefix.count)
        guard metadataPath[separatorIndex] == LegacyPath.separator else { return nil }
        let childStart = metadataPath.index(after: separatorIndex)
        return Data(metadataPath[childStart...])
    }

    /// Push a modern file-label change only to sessions for which the same physical object is
    /// visible. The wire path is translated per recipient because account/group file roots can
    /// make one shared object appear at different virtual paths.
    private func broadcastFileLabelChanged(label: LegacyFileLabel,
                                           sourceURL: URL,
                                           metadataPath: Data,
                                           excluding origin: LegacyServerSession) {
        let sourceResolved = sourceURL.resolvingSymlinksInPath().standardizedFileURL

        for recipient in authenticatedSessions() where recipient !== origin && !recipient.isLegacyTransport {
            do {
                guard let recipientPath = try virtualFilePath(forMetadataPath: metadataPath,
                                                              account: recipient.account),
                      !recipientPath.isEmpty else { continue }
                let parentPath = LegacyPath.parent(of: recipientPath) ?? Data()

                // Use the same directory-listing path as the Files UI. Besides Dropbox policy,
                // this also excludes filesystem-hidden entries and names this client cannot encode.
                let listing = try directoryListing(path: parentPath,
                                                   account: recipient.account,
                                                   supportsTaggedUTF8Names: recipient.supportsTaggedUTF8FileNames,
                                                   legacyTransport: false)
                let visible = listing.entries.contains { entry in
                    (try? LegacyPath.child(parent: listing.currentPath, name: entry.name)) == recipientPath
                }
                guard visible else { continue }

                let candidate = try storageURL(for: recipientPath, account: recipient.account,
                                               legacyTransport: false, requireExisting: true)
                    .resolvingSymlinksInPath().standardizedFileURL
                guard candidate == sourceResolved else { continue }

                let event = LegacyPacket(command: LegacyCommand.fileLabelChanged,
                                         transactionID: 0,
                                         fields: [
                                            LegacyTLV(type: 1, value: recipientPath),
                                            LegacyTLV(type: LegacyFileLabelField.fileInfo, value: label.encoded),
                                         ])
                try? recipient.sendAuthenticated(event)
            } catch {
                // A path that is not readable/visible for this account is simply not a recipient.
                continue
            }
        }
    }

    private func legacyLeafName(_ path: Data) throws -> Data {
        guard !path.isEmpty else { throw LegacyServerRuntimeError.protocolFailure("root has no leaf name") }
        let leaf: Data
        if let separator = path.lastIndex(of: LegacyPath.separator) {
            let start = path.index(after: separator)
            leaf = Data(path[start...])
        } else {
            leaf = path
        }
        guard !leaf.isEmpty else { throw LegacyServerRuntimeError.protocolFailure("legacy path has an empty leaf") }
        return leaf
    }

    private func validateLegacyLeaf(_ name: Data, maximum: Int) throws {
        guard !name.isEmpty, name.count <= maximum, !name.contains(LegacyPath.separator),
              let string = String(data: name, encoding: .macOSRoman),
              string != ".", string != "..", !string.contains("/"), !string.contains("\0") else {
            throw LegacyServerRuntimeError.protocolFailure("unsafe legacy file name")
        }
    }

    private func resourceKind(at url: URL) throws -> (isFolder: Bool, isFile: Bool) {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        guard values.isDirectory == true || values.isRegularFile == true else {
            throw LegacyServerRuntimeError.protocolFailure("unsupported server-storage item")
        }
        return (values.isDirectory == true, values.isRegularFile == true)
    }

    private func canDelete(isFolder: Bool, account: ServerAccount?) -> Bool {
        guard let account else { return false }
        return account.permissions.contains(isFolder ? .deleteFolders : .deleteFiles)
    }

    private func canMove(isFolder: Bool, account: ServerAccount?) -> Bool {
        guard let account else { return false }
        return account.permissions.contains(isFolder ? .moveFolders : .moveFiles)
    }

    private func canRename(isFolder: Bool, account: ServerAccount?) -> Bool {
        guard let account, account.mode == .administrator else { return false }
        return account.permissions.contains(isFolder ? .renameFolders : .renameFiles)
    }

    private func canComment(isFolder: Bool, account: ServerAccount?) -> Bool {
        guard let account else { return false }
        return account.permissions.contains(isFolder ? .commentFolders : .commentFiles)
    }

    private func isLegacyDescendant(_ candidate: Data, of parent: Data) -> Bool {
        guard candidate.count > parent.count, candidate.starts(with: parent) else { return false }
        return parent.isEmpty || candidate[parent.count] == LegacyPath.separator
    }

    private func handleCreateFolder(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard session.account?.permissions.contains(.createFolders) == true,
              let flagsField = packet.firstField(type: 2),
              let name = packet.firstField(type: 3)?.value else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let parentPath = packet.firstField(type: 1)?.value ?? Data()
            try validateLegacyLeaf(name, maximum: 0xfa)
            let flags = try flagsField.uint16BE()
            let parentURL = try storageURL(for: parentPath, account: session.account, legacyTransport: session.isLegacyTransport, requireExisting: true)
            guard try resourceKind(at: parentURL).isFolder else {
                throw LegacyServerRuntimeError.protocolFailure("folder parent is not a directory")
            }
            let path = try LegacyPath.child(parent: parentPath, name: name)
            let target = try storageURL(for: path, account: session.account, legacyTransport: session.isLegacyTransport, requireExisting: false)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw LegacyServerRuntimeError.protocolFailure("folder already exists")
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            do {
                let metadata = ServerFileMetadata(flags: flags & ~LegacyDirectoryFlags.folder,
                                                  comment: Data(), finderInfo: Data(repeating: 0, count: 16),
                                                  createdAt: Date())
                try requireFileMetadataStore(legacyTransport: session.isLegacyTransport).set(metadata, for: storageMetadataPath(path, account: session.account))
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            refreshSearchIndexSubtree(at: target, path: try storageMetadataPath(path, account: session.account), legacyTransport: session.isLegacyTransport)
            try sendTaskComplete(packet, to: session)
            log("Folder created: \(LegacyPath.displayString(path))")
        } catch { try fileControlError(error, packet: packet, session: session, operation: "Create folder") }
    }

    private func moveItemAllowingCrossVolume(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        do {
            try manager.moveItem(at: source, to: destination)
            return
        } catch {
            // A server-side directory symlink may point to another volume. Preserve the central
            // server Trash semantics by copying first and deleting the source only after the copy
            // completed. If source removal fails, discard the copy and report the operation.
            do {
                try manager.copyItem(at: source, to: destination)
                do {
                    try manager.removeItem(at: source)
                } catch {
                    try? manager.removeItem(at: destination)
                    throw error
                }
            } catch {
                if manager.fileExists(atPath: destination.path),
                   manager.fileExists(atPath: source.path) {
                    try? manager.removeItem(at: destination)
                }
                throw error
            }
        }
    }

    private func handleDeleteFile(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let path = packet.firstField(type: 1)?.value, !path.isEmpty else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            try requireDropboxReadAccess(path: path, account: session.account, legacyTransport: session.isLegacyTransport)
            let source = try storageURL(for: path, account: session.account, legacyTransport: session.isLegacyTransport, requireExisting: true)
            let kind = try resourceKind(at: source)
            guard canDelete(isFolder: kind.isFolder, account: session.account) else {
                throw LegacyServerRuntimeError.protocolFailure("delete permission denied")
            }
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let leaf = source.lastPathComponent
            let trashURL = trashRoot.appendingPathComponent("\(UUID().uuidString)-\(leaf)")
            try moveItemAllowingCrossVolume(from: source, to: trashURL)
            let mappedPath = try storageMetadataPath(path, account: session.account)
            do { try requireFileMetadataStore(legacyTransport: session.isLegacyTransport).remove(path: mappedPath, includingDescendants: kind.isFolder) }
            catch {
                try? moveItemAllowingCrossVolume(from: trashURL, to: source)
                throw error
            }
            removeSearchIndexSubtree(path: mappedPath, legacyTransport: session.isLegacyTransport)
            try sendTaskComplete(packet, to: session)
            log("Moved to server Trash: \(LegacyPath.displayString(path))")
        } catch { try fileControlError(error, packet: packet, session: session, operation: "Delete file/folder") }
    }

    private func handleFileInfo(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let path = packet.firstField(type: 1)?.value, !path.isEmpty else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            try requireDropboxReadAccess(path: path, account: session.account, legacyTransport: session.isLegacyTransport)
            let url = try storageURL(for: path, account: session.account, legacyTransport: session.isLegacyTransport, requireExisting: true)
            let kind = try resourceKind(at: url)
            let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
            let values = try url.resourceValues(forKeys: keys)
            let stored = try requireFileMetadataStore(legacyTransport: session.isLegacyTransport).metadata(for: storageMetadataPath(path, account: session.account)) ?? ServerFileMetadata()
            guard stored.finderInfo.count == 16, stored.comment.count <= 0xff else {
                throw LegacyServerRuntimeError.protocolFailure("stored file metadata is invalid")
            }
            let flags = stored.flags | (kind.isFolder ? LegacyDirectoryFlags.folder : 0)
            let size = kind.isFolder ? UInt32(0) : UInt32(min(UInt64(max(values.fileSize ?? 0, 0)), UInt64(UInt32.max)))
            let createdDate = stored.createdAt ?? values.creationDate ?? values.contentModificationDate
            let metadata = LegacyFileInfoMetadata(flags: flags, size: size,
                                                  created: createdDate?.legacyMacTimestamp ?? 0,
                                                  modified: values.contentModificationDate?.legacyMacTimestamp ?? 0,
                                                  finderInfo: stored.finderInfo)
            var fields = [
                LegacyTLV(type: 1, value: path),
                LegacyTLV(type: 2, value: try legacyLeafName(path)),
                LegacyTLV(type: 3, value: try metadata.encoded()),
                LegacyTLV(type: 4, value: stored.comment),
            ]
            if !session.isLegacyTransport {
                let label = LegacyFileLabel(rawValue: stored.label) ?? .none
                fields.append(LegacyTLV(type: LegacyFileLabelField.fileInfo, value: label.encoded))
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.moveFile,
                                                        transactionID: packet.transactionID,
                                                        fields: fields))
        } catch { try fileControlError(error, packet: packet, session: session, operation: "File info") }
    }

    private func handleSetFileInfo(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let sourcePath = packet.firstField(type: 1)?.value, !sourcePath.isEmpty,
              let newName = packet.firstField(type: 2)?.value,
              let flagsField = packet.firstField(type: 3),
              let comment = packet.firstField(type: 4)?.value else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            try validateLegacyLeaf(newName, maximum: 0x200)
            guard comment.count <= 0xff else { throw LegacyServerRuntimeError.protocolFailure("Finder comment exceeds limit") }
            try requireDropboxReadAccess(path: sourcePath, account: session.account, legacyTransport: session.isLegacyTransport)
            let sourceURL = try storageURL(for: sourcePath, account: session.account, legacyTransport: session.isLegacyTransport, requireExisting: true)
            let kind = try resourceKind(at: sourceURL)
            let metadataStore = try requireFileMetadataStore(legacyTransport: session.isLegacyTransport)
            let mappedSourcePath = try storageMetadataPath(sourcePath, account: session.account)
            let oldMetadata = metadataStore.metadata(for: mappedSourcePath) ?? ServerFileMetadata()
            let oldLeaf = try legacyLeafName(sourcePath)
            let requestedFlags = try flagsField.uint16BE() & ~LegacyDirectoryFlags.folder
            let oldFlags = oldMetadata.flags & ~LegacyDirectoryFlags.folder
            let requestedLabel: LegacyFileLabel?
            if !session.isLegacyTransport, let labelData = packet.firstField(type: LegacyFileLabelField.fileInfo)?.value {
                requestedLabel = try LegacyFileLabel.decode(labelData)
            } else {
                requestedLabel = nil
            }
            let renameRequested = newName != oldLeaf
            let commentRequested = comment != oldMetadata.comment
            let flagsRequested = kind.isFolder && requestedFlags != oldFlags
            let labelRequested = requestedLabel.map { $0.rawValue != oldMetadata.label } ?? false
            guard !renameRequested || canRename(isFolder: kind.isFolder, account: session.account),
                  !commentRequested || canComment(isFolder: kind.isFolder, account: session.account),
                  !labelRequested || canComment(isFolder: kind.isFolder, account: session.account),
                  !flagsRequested || session.account?.permissions.contains(.changeFolderMode) == true else {
                throw LegacyServerRuntimeError.protocolFailure("set-file-info permission denied")
            }

            var finalPath = sourcePath
            var finalURL = sourceURL
            if renameRequested {
                let parent = LegacyPath.parent(of: sourcePath) ?? Data()
                finalPath = try LegacyPath.child(parent: parent, name: newName)
                finalURL = try storageURL(for: finalPath, account: session.account, legacyTransport: session.isLegacyTransport, requireExisting: false)
                guard !FileManager.default.fileExists(atPath: finalURL.path) else {
                    throw LegacyServerRuntimeError.protocolFailure("rename destination already exists")
                }
                try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                let mappedFinalPath = try storageMetadataPath(finalPath, account: session.account)
                do { try metadataStore.move(from: mappedSourcePath, to: mappedFinalPath, includingDescendants: kind.isFolder) }
                catch {
                    try? FileManager.default.moveItem(at: finalURL, to: sourceURL)
                    throw error
                }
            }

            let mappedFinalPath = try storageMetadataPath(finalPath, account: session.account)
            var updated = metadataStore.metadata(for: mappedFinalPath) ?? oldMetadata
            updated.comment = comment
            if kind.isFolder { updated.flags = requestedFlags }
            if let requestedLabel { updated.label = requestedLabel.rawValue }
            if updated.finderInfo.count != 16 { updated.finderInfo = Data(repeating: 0, count: 16) }
            if updated.createdAt == nil {
                let values = try finalURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                updated.createdAt = values.creationDate ?? values.contentModificationDate ?? Date()
            }
            do { try metadataStore.set(updated, for: mappedFinalPath) }
            catch {
                if renameRequested {
                    try? FileManager.default.moveItem(at: finalURL, to: sourceURL)
                    try? metadataStore.move(from: mappedFinalPath, to: mappedSourcePath, includingDescendants: kind.isFolder)
                }
                throw error
            }
            if renameRequested {
                moveSearchIndexSubtree(from: mappedSourcePath, to: mappedFinalPath, destinationURL: finalURL, legacyTransport: session.isLegacyTransport)
            } else {
                refreshSearchIndexSubtree(at: finalURL, path: mappedFinalPath, legacyTransport: session.isLegacyTransport)
            }
            try sendTaskComplete(packet, to: session)
            if labelRequested, let requestedLabel {
                broadcastFileLabelChanged(label: requestedLabel,
                                          sourceURL: finalURL, metadataPath: mappedFinalPath,
                                          excluding: session)
            }
            log("File info updated: \(LegacyPath.displayString(finalPath))")
        } catch { try fileControlError(error, packet: packet, session: session, operation: "Set file info") }
    }

    private func handleSetFileLabel(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard !session.isLegacyTransport else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        guard let path = packet.firstField(type: 1)?.value, !path.isEmpty,
              let labelData = packet.firstField(type: LegacyFileLabelField.fileInfo)?.value else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        do {
            let label = try LegacyFileLabel.decode(labelData)
            try requireDropboxReadAccess(path: path, account: session.account, legacyTransport: false)
            let url = try storageURL(for: path, account: session.account, legacyTransport: false, requireExisting: true)
            let kind = try resourceKind(at: url)
            guard canComment(isFolder: kind.isFolder, account: session.account) else {
                throw LegacyServerRuntimeError.protocolFailure("file-label permission denied")
            }
            let store = try requireFileMetadataStore(legacyTransport: false)
            let mappedPath = try storageMetadataPath(path, account: session.account)
            var metadata = store.metadata(for: mappedPath) ?? ServerFileMetadata()
            let changed = metadata.label != label.rawValue
            metadata.label = label.rawValue
            if metadata.finderInfo.count != 16 { metadata.finderInfo = Data(repeating: 0, count: 16) }
            try store.set(metadata, for: mappedPath)
            try sendTaskComplete(packet, to: session)
            if changed {
                broadcastFileLabelChanged(label: label, sourceURL: url,
                                          metadataPath: mappedPath, excluding: session)
            }
            log("File label updated: \(LegacyPath.displayString(path)) -> \(label.rawValue)")
        } catch {
            try fileControlError(error, packet: packet, session: session, operation: "Set file label")
        }
    }

    private func handleMoveFile(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let sourcePath = packet.firstField(type: 1)?.value, !sourcePath.isEmpty,
              let destinationPath = packet.firstField(type: 2)?.value, !destinationPath.isEmpty else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            guard sourcePath != destinationPath else { throw LegacyServerRuntimeError.protocolFailure("source and destination are identical") }
            try requireDropboxReadAccess(path: sourcePath, account: session.account, legacyTransport: session.isLegacyTransport)
            let sourceURL = try storageURL(for: sourcePath, account: session.account, legacyTransport: session.isLegacyTransport, requireExisting: true)
            let kind = try resourceKind(at: sourceURL)
            guard canMove(isFolder: kind.isFolder, account: session.account) else {
                throw LegacyServerRuntimeError.protocolFailure("move permission denied")
            }
            if kind.isFolder, isLegacyDescendant(destinationPath, of: sourcePath) {
                throw LegacyServerRuntimeError.protocolFailure("cannot move a folder inside itself")
            }
            _ = try legacyLeafName(destinationPath)
            let destinationURL = try storageURL(for: destinationPath, account: session.account, legacyTransport: session.isLegacyTransport, requireExisting: false)
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw LegacyServerRuntimeError.protocolFailure("move destination already exists")
            }
            let parentPath = LegacyPath.parent(of: destinationPath) ?? Data()
            let parentURL = try storageURL(for: parentPath, account: session.account, legacyTransport: session.isLegacyTransport, requireExisting: true)
            guard try resourceKind(at: parentURL).isFolder else {
                throw LegacyServerRuntimeError.protocolFailure("move destination parent is not a folder")
            }
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            let mappedSourcePath = try storageMetadataPath(sourcePath, account: session.account)
            let mappedDestinationPath = try storageMetadataPath(destinationPath, account: session.account)
            do { try requireFileMetadataStore(legacyTransport: session.isLegacyTransport).move(from: mappedSourcePath, to: mappedDestinationPath, includingDescendants: kind.isFolder) }
            catch {
                try? FileManager.default.moveItem(at: destinationURL, to: sourceURL)
                throw error
            }
            moveSearchIndexSubtree(from: mappedSourcePath, to: mappedDestinationPath, destinationURL: destinationURL, legacyTransport: session.isLegacyTransport)
            try sendTaskComplete(packet, to: session)
            log("Moved \(LegacyPath.displayString(sourcePath)) -> \(LegacyPath.displayString(destinationPath))")
        } catch { try fileControlError(error, packet: packet, session: session, operation: "Move file/folder") }
    }

    func emptyTrash() throws {
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        for child in try FileManager.default.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: child)
        }
        log("Server Trash emptied")
    }

    func searchIndexStatusSnapshot() -> LegacySearchIndexStatus {
        fileSearchIndexStateLock.lock()
        let rebuilding = fileSearchIndexRebuildWorkerActive
        let index = fileSearchIndex
        fileSearchIndexStateLock.unlock()

        let entries: UInt64?
        if let index, !rebuilding, let count = try? index.entryCount() {
            entries = UInt64(max(0, count))
        } else {
            entries = nil
        }
        return LegacySearchIndexStatus(ready: index != nil, rebuilding: rebuilding, entries: entries)
    }

    private func handleSearchIndexStatusRequest(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard session.account?.permissions.contains(.editAdvancedSettings) == true else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        let status = searchIndexStatusSnapshot()
        var fields = [
            LegacyTLV(type: LegacySearchIndexStatusField.ready, value: Data([status.ready ? 1 : 0])),
            LegacyTLV(type: LegacySearchIndexStatusField.rebuilding, value: Data([status.rebuilding ? 1 : 0])),
        ]
        if let entries = status.entries {
            fields.append(LegacyTLV(type: LegacySearchIndexStatusField.entries,
                                    value: LegacyWire.uint64BE(entries)))
        }
        try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.searchIndexStatusReply,
                                                    transactionID: packet.transactionID,
                                                    fields: fields))
    }

    private func handleRemoteSearchIndexRebuild(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard session.account?.permissions.contains(.editAdvancedSettings) == true else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        rebuildSearchIndexInBackground(reason: "remote administrator request")
        try sendTaskComplete(packet, to: session)
        log("File-search index rebuild requested remotely by user \(session.userID.map(String.init) ?? "?")")
    }

    /// Rebuilds the disposable SQLite File Search index using the currently configured
    /// filename/glob exclusions. Matching directory names suppress their complete subtree.
    func rebuildSearchIndexInBackground(reason: String = "configuration changed") {
        scheduleFileSearchIndexRebuild(reason: reason)
    }

    @discardableResult
    func rebuildSearchIndex() throws -> Int {
        let count = try fileSearchIndexRebuildQueue.sync {
            let index = try buildFreshSearchIndex()
            setCurrentFileSearchIndex(index)
            return try index.entryCount()
        }
        log("Search inventory rebuilt: \(count) searchable item(s)")
        refreshSearchIndexRebuildSchedule()
        return count
    }


    private func handleEmptyTrash(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard session.account?.permissions.contains(.emptyServerTrash) == true else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            try emptyTrash()
            try sendTaskComplete(packet, to: session)
        } catch { try fileControlError(error, packet: packet, session: session, operation: "Empty Trash") }
    }

    func updateLocalBotAvatar(_ picture: Data?) throws {
        if let picture, picture.count > LegacyUserInfoField.maximumPictureLength {
            throw ServerStateError.invalidValue("Bot avatar exceeds the protocol limit.")
        }
        let normalized = picture?.isEmpty == false ? picture : nil
        guard backend.localBotAccount()?.picture != normalized else { return }
        try backend.updateServerState { state in
            guard let index = state.accounts.firstIndex(where: {
                $0.id == ServerState.localBotAccountID && $0.isLocalLoginOnly
            }) else { throw ServerStateError.accountNotFound(ServerState.localBotAccountID) }
            state.accounts[index].picture = normalized
            state.accounts[index].modifiedAt = Date()
            try ServerStateValidator.validate(account: state.accounts[index])
        }
        refreshConnectedAccountsFromBackendAndBroadcastColor()
        onStateChanged?()
    }

    func refreshConnectedAccountsFromBackendAndBroadcastColor() {
        let snapshot = backend.snapshot()
        stateLock.lock()
        let sessions = Array(authenticatedByUserID.values)
        for session in sessions {
            guard let accountID = session.account?.id,
                  let updated = snapshot.accounts.first(where: { $0.id == accountID }) else { continue }
            session.account = updated
            if session.isLocalOnly {
                let displayName = updated.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? updated.login : updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
                session.nickname = Data(Self.macRoman(displayName).prefix(64))
                session.picture = updated.picture ?? Data()
            }
        }
        stateLock.unlock()
        for source in sessions {
            guard let userID = source.userID, let account = source.account else { continue }

            // Classic 1.0b13 understands the server-side User Update itself, but not the
            // modern status/color/permission extension fields. Keep its async update in the
            // historical two-field form; otherwise an account edit can make the old client
            // abort its control connection.
            let classicFields = [
                LegacyTLV(type: 1, value: LegacyWire.uint32BE(userID)),
                LegacyTLV(type: 2, value: source.nickname),
            ]
            var modernFields = classicFields + [
                LegacyTLV(type: LegacyUserInfoField.picture, value: source.picture),
                LegacyTLV(type: LegacyUserInfoField.statusMessage, value: source.statusMessage),
            ]
            if let color = snapshot.accountColorRGB(for: account) {
                modernFields.append(LegacyTLV(type: LegacyUserInfoField.groupColorRGB,
                                              value: LegacyWire.uint32BE(color)))
            }

            for recipient in sessions {
                var recipientFields = recipient.isLegacyTransport ? classicFields : modernFields
                if recipient === source, !recipient.isLegacyTransport {
                    recipientFields.append(LegacyTLV(type: LegacyUserInfoField.permissionWords,
                                                     value: account.permissionBytes(includeCarrachoExtensions: true)))
                }
                let event = LegacyPacket(command: LegacyCommand.userUpdate, transactionID: 0, fields: recipientFields)
                try? recipient.sendAuthenticated(event)
            }
        }
    }

    private var localBotConfigurationURL: URL {
        serverSupportRoot.appendingPathComponent("etc", isDirectory: true)
            .appendingPathComponent("carracho-bot.json", isDirectory: false)
    }

    private var localBotStatusURL: URL {
        serverSupportRoot.appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent("bot-status.json", isDirectory: false)
    }

    private func localBotDesiredEnabled() -> Bool {
        guard let data = try? Data(contentsOf: localBotConfigurationURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["enabled"] as? Bool ?? false
    }

    private func setLocalBotDesiredEnabled(_ enabled: Bool) throws {
        let url = localBotConfigurationURL
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["enabled"] = enabled
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func localBotGreetingConfiguration() -> (enabled: Bool, template: String) {
        guard let data = try? Data(contentsOf: localBotConfigurationURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, Self.defaultBotGreetingTemplate)
        }
        let enabled = object["greetNewUsers"] as? Bool ?? false
        let template = (object["greetingTemplate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let template, !template.isEmpty, template.utf8.count <= Self.maximumBotGreetingTemplateBytes,
           !template.contains("\n"), !template.contains("\r") {
            return (enabled, template)
        }
        return (enabled, Self.defaultBotGreetingTemplate)
    }

    private func setLocalBotGreeting(enabled: Bool, template: String) throws {
        let normalized = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= Self.maximumBotGreetingTemplateBytes,
              !normalized.contains("\n"), !normalized.contains("\r") else {
            throw ServerStateError.invalidValue("Bot greeting must be one non-empty UTF-8 line of at most 512 bytes.")
        }
        let url = localBotConfigurationURL
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["greetNewUsers"] = enabled
        object["greetingTemplate"] = normalized
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func localBotCommandRules() -> [LegacyBotCommandRule] {
        guard let data = try? Data(contentsOf: localBotConfigurationURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRules = object["commandRules"] as? [[String: Any]] else { return [] }
        var rules: [LegacyBotCommandRule] = []
        for raw in rawRules.prefix(LegacyBotCommandRule.maximumCount) {
            guard let enabled = raw["enabled"] as? Bool,
                  let command = raw["command"] as? String,
                  let response = raw["response"] as? String,
                  let rule = try? LegacyBotCommandRule(enabled: enabled, command: command, response: response).validated() else {
                continue
            }
            rules.append(rule)
        }
        return rules
    }

    private func setLocalBotCommandRules(_ rules: [LegacyBotCommandRule]) throws {
        guard rules.count <= LegacyBotCommandRule.maximumCount else {
            throw ServerStateError.invalidValue("Too many Bot command rules.")
        }
        let validated = try rules.map { try $0.validated() }
        let url = localBotConfigurationURL
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["commandRules"] = validated.map { [
            "enabled": $0.enabled,
            "command": $0.command,
            "response": $0.response,
        ] }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func localBotFileWatchers() -> [LegacyBotFileWatcher] {
        guard let data = try? Data(contentsOf: localBotConfigurationURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["fileWatchers"] as? [[String: Any]] else { return [] }
        var watchers: [LegacyBotFileWatcher] = []
        var ids = Set<UUID>()
        for row in rows.prefix(LegacyBotFileWatcher.maximumCount) {
            guard let idText = row["id"] as? String, let id = UUID(uuidString: idText),
                  let enabled = row["enabled"] as? Bool,
                  let path = row["path"] as? String,
                  let channel = row["channelID"] as? NSNumber,
                  let message = row["messageTemplate"] as? String,
                  channel.uint64Value > 0, channel.uint64Value <= UInt64(UInt32.max),
                  let watcher = try? LegacyBotFileWatcher(id: id, enabled: enabled, path: path,
                                                          channelID: channel.uint32Value,
                                                          messageTemplate: message)
                    .validated(filesRootURL: storageRoot, requireDirectory: false),
                  ids.insert(watcher.id).inserted else { continue }
            watchers.append(watcher)
        }
        return watchers
    }

    private func setLocalBotFileWatchers(_ watchers: [LegacyBotFileWatcher]) throws {
        guard watchers.count <= LegacyBotFileWatcher.maximumCount else {
            throw ServerStateError.invalidValue("Too many Bot File Watchers.")
        }
        stateLock.lock()
        let conferenceIDs = Set(channels.keys)
        stateLock.unlock()
        var ids = Set<UUID>()
        var paths = Set<String>()
        let validated = try watchers.map { watcher -> LegacyBotFileWatcher in
            guard ids.insert(watcher.id).inserted else {
                throw ServerStateError.invalidValue("Bot File Watcher IDs must be unique.")
            }
            let value = try watcher.validated(filesRootURL: storageRoot, requireDirectory: watcher.enabled)
            guard conferenceIDs.contains(value.channelID) else {
                throw ServerStateError.invalidValue("Bot File Watcher Conference \(value.channelID) does not exist.")
            }
            guard paths.insert(value.path.lowercased()).inserted else {
                throw ServerStateError.invalidValue("Bot File Watcher paths must be unique.")
            }
            return value
        }
        let url = localBotConfigurationURL
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["fileWatchers"] = validated.map { [
            "id": $0.id.uuidString.lowercased(),
            "enabled": $0.enabled,
            "path": $0.path,
            "channelID": $0.channelID,
            "messageTemplate": $0.messageTemplate,
        ] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        botFileWatcherService.configurationDidChange()
    }

    private func botCommandText(from wire: Data, addressed: Bool) -> String? {
        let raw = CarrachoTextWire.string(from: wire).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if addressed {
            guard raw.hasPrefix("#") else { return nil }
            let command = String(raw.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
        return raw
    }

    private func matchingLocalBotResponse(for wire: Data, from sender: LegacyServerSession, addressed: Bool) -> String? {
        guard !sender.isLocalOnly, isLocalBotConnected,
              let command = botCommandText(from: wire, addressed: addressed) else { return nil }
        let key = command.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard let rule = localBotCommandRules().first(where: { rule in
            guard rule.enabled else { return false }
            let candidate = rule.command.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return candidate == key
        }) else { return nil }
        return renderedLocalBotGreeting(for: sender, template: rule.response)
    }

    private func respondToLocalBotChannelCommandIfNeeded(_ wire: Data, from sender: LegacyServerSession, channelID: UInt32) {
        guard let response = matchingLocalBotResponse(for: wire, from: sender, addressed: true) else { return }
        do {
            try postLocalBotMessage(response, channelID: channelID, source: "command")
        } catch {
            log("Local Bot command reply failed in channel \(channelID): \(error.localizedDescription)")
        }
    }

    private func respondToLocalBotPrivateCommandIfNeeded(_ wire: Data, from sender: LegacyServerSession) {
        guard let response = matchingLocalBotResponse(for: wire, from: sender, addressed: false) else { return }
        do {
            try postLocalBotPrivateMessage(response, to: sender, source: "command")
        } catch {
            log("Local Bot private command reply failed: \(error.localizedDescription)")
        }
    }

    private func renderedLocalBotGreeting(for session: LegacyServerSession, template: String) -> String {
        let nickname = String(data: session.nickname, encoding: .macOSRoman)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = session.account?.login ?? ""
        let name = (nickname?.isEmpty == false ? nickname! : login)
        return template
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{login}", with: login)
    }

    private func greetNewPublicMemberIfNeeded(_ session: LegacyServerSession) {
        guard !session.isLocalOnly, !session.botGreetingSent else { return }
        session.botGreetingSent = true
        let configuration = localBotGreetingConfiguration()
        guard configuration.enabled, isLocalBotConnected else { return }
        let text = renderedLocalBotGreeting(for: session, template: configuration.template)
        do {
            try postLocalBotMessage(text, source: "greeting")
            if let userID = session.userID {
                log("Local Bot greeted user \(userID) in Public")
            }
        } catch {
            log("Local Bot greeting failed: \(error.localizedDescription)")
        }
    }

    private func publishLocalBotRSSArticle(feed: LegacyBotRSSFeed, article: LegacyBotRSSArticle) -> Bool {
        guard isLocalBotConnected else { return false }
        var mediaToken = ""
        if feed.includeImage, let imageData = article.imageData, !imageData.isEmpty {
            do {
                let filename = article.imageFilename ?? "rss-image.jpg"
                let object = try mediaStore.storePending(ownerAccountID: ServerState.localBotAccountID,
                                                         filename: filename, data: imageData)
                let messageID = UUID().uuidString.lowercased()
                try mediaStore.bind(ids: [object.id], ownerAccountID: ServerState.localBotAccountID,
                                    kind: .chat, scope: String(feed.channelID), messageID: messageID,
                                    expiresAt: Date().addingTimeInterval(LegacyMediaTransfer.chatLifetime))
                mediaToken = LegacyMediaReference.token(for: object.id) + "\n"
            } catch {
                log("Bot RSS image for \(feed.name) was skipped: \(error.localizedDescription)")
            }
        }

        let title = Self.escapeBotRSSHTML(article.title)
        let link = Self.escapeBotRSSHTMLAttribute(article.link)
        var summary = article.summary
        for _ in 0..<8 {
            let escapedSummary = Self.escapeBotRSSHTML(summary)
            let linkLine = link.isEmpty ? "" : "\n<a href=\"\(link)\">\(Self.escapeBotRSSHTML(article.link))</a>"
            let body = mediaToken + "<b>\(title)</b>" + (escapedSummary.isEmpty ? "" : "\n\(escapedSummary)") + linkLine
            if (try? CarrachoTextWire.encode(body, maximumBytes: 0x800)) != nil {
                do {
                    try postLocalBotMessage(body, channelID: feed.channelID, source: "rss:\(feed.name)")
                    log("Bot RSS \(feed.name) posted: \(article.title)")
                    return true
                } catch {
                    log("Bot RSS \(feed.name) could not post: \(error.localizedDescription)")
                    return false
                }
            }
            guard summary.count > 80 else { break }
            summary = String(summary.prefix(max(80, summary.count * 3 / 4))).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        log("Bot RSS \(feed.name) article was too large for a conference message")
        return false
    }

    private static let botFileLinkAllowedCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-._~"))

    private static func botFileLink(for relativePath: String) -> String? {
        if relativePath == "." { return "carracho-file:///" }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let encoded = components.compactMap {
            $0.addingPercentEncoding(withAllowedCharacters: botFileLinkAllowedCharacters)
        }
        guard encoded.count == components.count else { return nil }
        return "carracho-file:///" + encoded.joined(separator: "/")
    }

    private func publishLocalBotFileWatcherAnnouncement(_ announcement: LegacyBotFileWatcherAnnouncement) -> Bool {
        guard isLocalBotConnected,
              let href = Self.botFileLink(for: announcement.folderPath) else { return false }

        let template = announcement.watcher.messageTemplate
        guard template.contains("{folder}") || template.contains("{file}") else { return false }
        let folderLink = "<a href=\"\(Self.escapeBotRSSHTMLAttribute(href))\">" +
            Self.escapeBotRSSHTML(announcement.folderName) + "</a>"
        let body = Self.escapeBotRSSHTML(template)
            .replacingOccurrences(of: "{folder}", with: folderLink)
            .replacingOccurrences(of: "{file}", with: Self.escapeBotRSSHTML(announcement.fileName))
        guard (try? CarrachoTextWire.encode(body, maximumBytes: 0x800)) != nil else {
            log("Bot File Watcher message for \(announcement.folderPath) exceeds the conference message limit")
            return false
        }
        do {
            try postLocalBotMessage(body, channelID: announcement.watcher.channelID,
                                    source: "file-watcher:\(announcement.watcher.path)")
            return true
        } catch {
            log("Bot File Watcher could not post \(announcement.folderPath): \(error.localizedDescription)")
            return false
        }
    }

    private static func escapeBotRSSHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeBotRSSHTMLAttribute(_ value: String) -> String {
        escapeBotRSSHTML(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func localBotLastError() -> String? {
        guard let data = try? Data(contentsOf: localBotStatusURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["lastError"] as? String, !value.isEmpty else { return nil }
        return value
    }

    private func handleBotStatusRequest(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard !session.isLegacyTransport, has(.manageAccounts, session: session),
              let account = backend.localBotAccount(), account.isLocalLoginOnly else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        let greeting = localBotGreetingConfiguration()
        let commandRules = localBotCommandRules()
        let rssFeeds = botRSSService.loadFeeds()
        let fileWatchers = localBotFileWatchers()
        var fields = [
            LegacyTLV(type: LegacyBotAdminField.desiredEnabled, value: Data([localBotDesiredEnabled() ? 1 : 0])),
            LegacyTLV(type: LegacyBotAdminField.connected, value: Data([isLocalBotConnected ? 1 : 0])),
            LegacyTLV(type: LegacyBotAdminField.login, value: Data(account.login.utf8)),
            LegacyTLV(type: LegacyBotAdminField.name, value: Data(account.name.utf8)),
            LegacyTLV(type: LegacyBotAdminField.greetNewUsers, value: Data([greeting.enabled ? 1 : 0])),
            LegacyTLV(type: LegacyBotAdminField.greetingTemplate, value: Data(greeting.template.utf8)),
            LegacyTLV(type: LegacyBotAdminField.commandRules, value: try LegacyBotCommandRule.encodeList(commandRules)),
            LegacyTLV(type: LegacyBotAdminField.rssFeeds, value: try LegacyBotRSSFeed.encodeList(rssFeeds)),
            LegacyTLV(type: LegacyBotAdminField.fileWatchers, value: try LegacyBotFileWatcher.encodeList(fileWatchers)),
        ]
        if let error = localBotLastError() {
            fields.append(LegacyTLV(type: LegacyBotAdminField.lastError, value: Data(error.utf8)))
        }
        try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.botStatusReply,
                                                    transactionID: packet.transactionID,
                                                    fields: fields))
    }

    private func handleBotSetEnabled(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard !session.isLegacyTransport, has(.manageAccounts, session: session),
              let field = packet.firstField(type: LegacyBotAdminField.desiredEnabled),
              field.value.count == 1, let raw = field.value.first, raw <= 1 else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            try setLocalBotDesiredEnabled(raw == 1)
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID,
                                                        fields: []))
        } catch {
            log("Remote Bot control failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleBotSetGreeting(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard !session.isLegacyTransport, has(.manageAccounts, session: session),
              let enabledField = packet.firstField(type: LegacyBotAdminField.greetNewUsers),
              enabledField.value.count == 1, let raw = enabledField.value.first, raw <= 1,
              let templateField = packet.firstField(type: LegacyBotAdminField.greetingTemplate),
              let template = String(data: templateField.value, encoding: .utf8) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            try setLocalBotGreeting(enabled: raw == 1, template: template)
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
        } catch {
            log("Remote Bot greeting update failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleBotSetCommandRules(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard !session.isLegacyTransport, has(.manageAccounts, session: session),
              let field = packet.firstField(type: LegacyBotAdminField.commandRules) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let rules = try LegacyBotCommandRule.decodeList(field.value)
            try setLocalBotCommandRules(rules)
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
        } catch {
            log("Remote Bot command-rule update failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleBotSetRSSFeeds(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard !session.isLegacyTransport, has(.manageAccounts, session: session),
              let field = packet.firstField(type: LegacyBotAdminField.rssFeeds) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let feeds = try LegacyBotRSSFeed.decodeList(field.value)
            try botRSSService.saveFeeds(feeds)
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            log("Remote Bot RSS feed configuration updated: \(feeds.count) feed(s)")
        } catch {
            log("Remote Bot RSS feed update failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleBotSetFileWatchers(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard !session.isLegacyTransport, has(.manageAccounts, session: session),
              let field = packet.firstField(type: LegacyBotAdminField.fileWatchers) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let watchers = try LegacyBotFileWatcher.decodeList(field.value)
            try setLocalBotFileWatchers(watchers)
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            log("Remote Bot File Watcher configuration updated: \(watchers.count) watcher(s)")
        } catch {
            log("Remote Bot File Watcher update failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleBotTestRSSFeed(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard !session.isLegacyTransport, has(.manageAccounts, session: session),
              let field = packet.firstField(type: LegacyBotAdminField.rssFeeds) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let feeds = try LegacyBotRSSFeed.decodeList(field.value)
            guard feeds.count == 1 else { throw LegacyServerRuntimeError.protocolFailure("RSS test requires exactly one feed") }
            var testFeed = feeds[0]
            testFeed.channelID = Self.publicChannelID
            let article = try botRSSService.testArticle(testFeed)
            let preview = LegacyBotRSSPreview(title: article.title, summary: article.summary,
                                              link: article.link, imageURL: article.imageURL?.absoluteString)
            // Complete the administration request before emitting the asynchronous Public chat event.
            // This keeps the request/reply control stream deterministic even when the RSS post contains media.
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.botRSSFeedTestReply,
                                                        transactionID: packet.transactionID,
                                                        fields: [LegacyTLV(type: LegacyBotAdminField.rssPreview,
                                                                           value: try preview.encode())]))
            if !publishLocalBotRSSArticle(feed: testFeed, article: article) {
                log("Remote Bot RSS test fetched an article but could not post it to Public")
            }
        } catch {
            log("Remote Bot RSS test failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    // MARK: - Classic remote administration

    private func has(_ permission: ServerPermission, session: LegacyServerSession) -> Bool {
        session.account?.permissions.contains(permission) == true
    }

    private func administrativeRecipients(permission: ServerPermission) -> [LegacyServerSession] {
        stateLock.lock(); defer { stateLock.unlock() }
        return authenticatedByUserID.values.filter { $0.account?.permissions.contains(permission) == true }
    }

    private func broadcastAdministrative(_ packet: LegacyPacket, permission: ServerPermission,
                                         modernOnly: Bool = false) {
        administrativeRecipients(permission: permission)
            .filter { !modernOnly || !$0.isLegacyTransport }
            .forEach { try? $0.sendAuthenticated(packet) }
    }

    private func handleAccountList(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.manageAccounts, session: session) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let snapshot = backend.snapshot()
            let summaries = try snapshot.accounts.map { try $0.legacyCompactSummary() }
            var fields = [LegacyTLV(type: 0x10,
                                    value: try LegacyPackedRecords.encodeCompactAccountList(summaries))]
            if !session.isLegacyTransport {
                let stored = try backend.accountTransferStatistics()
                let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.accountID, $0) })
                let statistics = snapshot.accounts.map { account -> LegacyAccountTransferStatistics in
                    guard let value = byID[account.id] else {
                        return LegacyAccountTransferStatistics(downloadCount: 0, downloadBytes: 0,
                                                               uploadCount: 0, uploadBytes: 0)
                    }
                    return LegacyAccountTransferStatistics(downloadCount: value.downloadCount,
                                                           downloadBytes: value.downloadBytes,
                                                           uploadCount: value.uploadCount,
                                                           uploadBytes: value.uploadBytes)
                }
                fields.append(LegacyTLV(type: LegacyAccountField.transferStatistics,
                                        value: try LegacyPackedRecords.encodeAccountTransferStatistics(statistics)))
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.accountList,
                                                        transactionID: packet.transactionID,
                                                        fields: fields))
        } catch {
            log("Account-list request failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleGetAccount(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.manageAccounts, session: session),
              let loginData = packet.firstField(type: 2)?.value,
              !loginData.isEmpty, loginData.count <= 31,
              let login = String(data: loginData, encoding: .macOSRoman) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let snapshot = backend.snapshot()
            guard let account = snapshot.accounts.first(where: {
                $0.login.compare(login, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
            }
            let record = try account.legacyRecord(
                includePassword: snapshot.authentication.mode == .legacyCompatible,
                includeCarrachoExtensions: !session.isLegacyTransport
            )
            var fields = [LegacyTLV(type: 1, value: try record.encoded())]
            if !session.isLegacyTransport, let groupID = account.groupID {
                fields.append(LegacyTLV(type: LegacyAccountField.groupID, value: Data(groupID.uuidString.utf8)))
                if let color = snapshot.accountColorRGB(for: account) {
                    fields.append(LegacyTLV(type: LegacyAccountField.colorRGB, value: LegacyWire.uint32BE(color)))
                }
                fields.append(LegacyTLV(type: LegacyAccountField.picture, value: account.picture ?? Data()))
                fields.append(LegacyTLV(type: LegacyAccountField.localLoginOnly,
                                        value: Data([account.isLocalLoginOnly ? 1 : 0])))
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.accountReply,
                                                        transactionID: packet.transactionID, fields: fields))
        } catch {
            log("Get-account request failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleAccountCreateOrModify(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.manageAccounts, session: session), let raw = packet.firstField(type: 1)?.value else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let record = try LegacyAccountRecord.decode(raw)
            let oldLoginData = packet.firstField(type: 3)?.value ?? Data()
            guard oldLoginData.count <= 63,
                  let oldLogin = String(data: oldLoginData, encoding: .macOSRoman) else {
                throw ServerStateError.invalidValue("Classic old account name is invalid.")
            }
            let requestedGroupID: UUID?
            if !session.isLegacyTransport, let groupField = packet.firstField(type: LegacyAccountField.groupID) {
                guard let text = String(data: groupField.value, encoding: .utf8), let id = UUID(uuidString: text) else {
                    throw ServerStateError.invalidValue("Invalid account-group identifier.")
                }
                requestedGroupID = id
            } else { requestedGroupID = nil }
            let requestedColor: UInt32?
            if !session.isLegacyTransport, let colorField = packet.firstField(type: LegacyAccountField.colorRGB) {
                let color = try colorField.uint32BE()
                guard color <= 0x00ff_ffff else { throw ServerStateError.invalidValue("Invalid account color.") }
                requestedColor = color
            } else { requestedColor = nil }
            let requestedPicture: Data?
            if !session.isLegacyTransport, let pictureField = packet.firstField(type: LegacyAccountField.picture) {
                guard pictureField.value.count <= LegacyUserInfoField.maximumPictureLength else {
                    throw ServerStateError.invalidValue("Account picture exceeds the protocol limit.")
                }
                requestedPicture = pictureField.value
            } else { requestedPicture = nil }
            let snapshot = backend.snapshot()
            let saved: ServerAccount
            var previousAccount: ServerAccount?
            let action: UInt8
            if oldLoginData.isEmpty {
                let converted = try ServerAccount.fromLegacyRecord(record, allowCarrachoExtensions: !session.isLegacyTransport)
                var account = converted.account
                account.groupID = requestedGroupID ?? ServerState.builtInAccountGroupID(for: account.mode)
                if session.isLegacyTransport,
                   snapshot.accountGroups.first(where: { $0.id == account.groupID })?.permissions.contains(.postNews) == true {
                    account.permissions.insert(.postNews)
                }
                account.colorRGB = requestedColor
                if let requestedPicture { account.picture = requestedPicture.isEmpty ? nil : requestedPicture }
                saved = try backend.createAccount(account, password: converted.password)
                previousAccount = nil
                action = 0
            } else {
                guard let existing = snapshot.accounts.first(where: {
                    $0.login.compare(oldLogin, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) else { throw ServerStateError.invalidValue("Account to modify was not found.") }
                previousAccount = existing
                let converted = try ServerAccount.fromLegacyRecord(record, id: existing.id,
                                                                   allowCarrachoExtensions: !session.isLegacyTransport)
                var replacement = converted.account
                replacement.groupID = requestedGroupID ?? ServerState.builtInAccountGroupID(for: replacement.mode)
                if session.isLegacyTransport, existing.permissions.contains(.postNews) {
                    replacement.permissions.insert(.postNews)
                }
                // Nil means “use normal group-assignment semantics”: preserve a same-group
                // override, but copy the new group's default color when the class changes.
                replacement.colorRGB = requestedColor
                replacement.lastLoginAt = existing.lastLoginAt
                replacement.profileName = existing.profileName
                replacement.email = existing.email
                replacement.aboutMe = existing.aboutMe
                if let requestedPicture { replacement.picture = requestedPicture.isEmpty ? nil : requestedPicture }
                else { replacement.picture = existing.picture }
                replacement.localLoginOnly = existing.localLoginOnly
                let passwordUpdate: String? = existing.isLocalLoginOnly ? nil :
                    (snapshot.authentication.mode == .modernOnly && record.password.isEmpty ? nil : converted.password)
                saved = try backend.updateAccount(id: existing.id, with: replacement, newPassword: passwordUpdate)
                action = 1
            }
            try synchronizePersonalDirectory(oldAccount: previousAccount, newAccount: saved)
            refreshConnectedAccountsFromBackendAndBroadcastColor()

            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            let event = LegacyPacket(command: LegacyCommand.accountUpdate, transactionID: 0, fields: [
                LegacyTLV(type: 0x11, value: Data([action])),
                LegacyTLV(type: 3, value: oldLoginData),
                LegacyTLV(type: 1, value: try saved.legacyCompactSummary().encoded()),
            ])
            broadcastAdministrative(event, permission: .manageAccounts, modernOnly: true)
            onStateChanged?()
            log("Account \(action == 0 ? "created" : "modified"): \(saved.login)")
        } catch {
            log("Account create/modify failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleChangeOwnPassword(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let account = session.account,
              let passwordData = packet.firstField(type: 1)?.value,
              passwordData.count <= 64,
              let password = String(data: passwordData, encoding: .macOSRoman) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        do {
            let updated = try backend.changePassword(accountID: account.id, to: password)
            stateLock.lock()
            session.account = updated
            stateLock.unlock()
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            onStateChanged?()
            log("Account password changed by user: \(updated.login)")
        } catch {
            log("Self-service password change failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleAccountDelete(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.manageAccounts, session: session),
              let loginData = packet.firstField(type: 2)?.value,
              !loginData.isEmpty, loginData.count <= 31,
              let login = String(data: loginData, encoding: .macOSRoman) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let snapshot = backend.snapshot()
            guard let account = snapshot.accounts.first(where: {
                $0.login.compare(login, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else { throw ServerStateError.invalidValue("Account to delete was not found.") }
            try backend.deleteAccount(id: account.id)
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            let event = LegacyPacket(command: LegacyCommand.accountUpdate, transactionID: 0, fields: [
                LegacyTLV(type: 0x11, value: Data([2])),
                LegacyTLV(type: 3, value: loginData),
            ])
            broadcastAdministrative(event, permission: .manageAccounts, modernOnly: true)
            onStateChanged?()
            log("Account deleted: \(account.login)")
        } catch {
            log("Account delete failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleAdminNewsgroupList(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.manageNewsgroups, session: session) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let groups = backend.snapshot().newsgroups.map {
                LegacyAdminNewsgroup(name: Self.macRoman($0.name), articleCount: $0.articleCount,
                                     expireAfterSeconds: $0.expireAfterSeconds, flags: $0.access.legacyFlags)
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.adminNewsgroupListReply,
                                                        transactionID: packet.transactionID,
                                                        fields: [LegacyTLV(type: 2,
                                                                           value: try LegacyPackedRecords.encodeAdminNewsgroupList(groups))]))
        } catch {
            log("Admin newsgroup-list request failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func decodeNewsgroupFields(_ packet: LegacyPacket) throws -> (nameData: Data, name: String, expire: UInt32, flags: UInt16) {
        guard let nameData = packet.firstField(type: 1)?.value,
              !nameData.isEmpty, nameData.count <= LegacyNewsTransfer.maximumGroupNameLength,
              let name = String(data: nameData, encoding: .macOSRoman),
              let expireField = packet.firstField(type: 2),
              let flagsField = packet.firstField(type: 3) else {
            throw ServerStateError.invalidValue("Classic newsgroup request is incomplete.")
        }
        return (nameData, name, try expireField.uint32BE(), try flagsField.uint16BE())
    }

    private func handleNewsgroupCreate(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.manageNewsgroups, session: session) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let value = try decodeNewsgroupFields(packet)
            _ = try backend.createNewsgroup(ServerNewsgroup(name: value.name,
                                                            expireAfterSeconds: value.expire,
                                                            access: ServerNewsgroupAccess(legacyFlags: value.flags)))
            refreshNewsConfiguration()
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            broadcastAdministrative(LegacyPacket(command: LegacyCommand.newsgroupUpdate, transactionID: 0, fields: [
                LegacyTLV(type: 5, value: Data([0])), LegacyTLV(type: 1, value: value.nameData),
                LegacyTLV(type: 2, value: LegacyWire.uint32BE(value.expire)),
                LegacyTLV(type: 3, value: LegacyWire.uint16BE(value.flags)),
            ]), permission: .manageNewsgroups)
            log("Newsgroup created: \(value.name)")
        } catch {
            log("Newsgroup create failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleNewsgroupModify(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.manageNewsgroups, session: session) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            let value = try decodeNewsgroupFields(packet)
            guard let oldData = packet.firstField(type: 4)?.value,
                  !oldData.isEmpty, oldData.count <= LegacyNewsTransfer.maximumGroupNameLength,
                  let oldName = String(data: oldData, encoding: .macOSRoman),
                  let existing = backend.snapshot().newsgroups.first(where: {
                      $0.name.compare(oldName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                  }) else { throw ServerStateError.invalidValue("Newsgroup to modify was not found.") }
            _ = try backend.updateNewsgroup(id: existing.id,
                                            with: ServerNewsgroup(id: existing.id, name: value.name,
                                                                 articleCount: existing.articleCount,
                                                                 expireAfterSeconds: value.expire,
                                                                 access: ServerNewsgroupAccess(legacyFlags: value.flags)))
            refreshNewsConfiguration()
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            broadcastAdministrative(LegacyPacket(command: LegacyCommand.newsgroupUpdate, transactionID: 0, fields: [
                LegacyTLV(type: 5, value: Data([1])), LegacyTLV(type: 1, value: value.nameData),
                LegacyTLV(type: 2, value: LegacyWire.uint32BE(value.expire)),
                LegacyTLV(type: 3, value: LegacyWire.uint16BE(value.flags)),
                LegacyTLV(type: 4, value: oldData),
            ]), permission: .manageNewsgroups)
            log("Newsgroup modified: \(oldName) -> \(value.name)")
        } catch {
            log("Newsgroup modify failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleNewsgroupDelete(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.manageNewsgroups, session: session),
              let nameData = packet.firstField(type: 1)?.value,
              !nameData.isEmpty, nameData.count <= LegacyNewsTransfer.maximumGroupNameLength,
              let name = String(data: nameData, encoding: .macOSRoman) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1)); return
        }
        do {
            guard let existing = backend.snapshot().newsgroups.first(where: {
                $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else { throw ServerStateError.invalidValue("Newsgroup to delete was not found.") }
            try backend.deleteNewsgroup(id: existing.id)
            refreshNewsConfiguration()
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            broadcastAdministrative(LegacyPacket(command: LegacyCommand.newsgroupUpdate, transactionID: 0, fields: [
                LegacyTLV(type: 5, value: Data([2])), LegacyTLV(type: 1, value: nameData),
            ]), permission: .manageNewsgroups)
            log("Newsgroup deleted: \(name)")
        } catch {
            log("Newsgroup delete failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func settingsPermission(field: UInt32, write: Bool) -> ServerPermission? {
        switch field {
        case LegacyServerSettingField.agreement: return .editServerAgreement
        case LegacyServerSettingField.serverName, LegacyServerSettingField.location,
             LegacyServerSettingField.serverOperator, LegacyServerSettingField.description:
            return .editServerInformation
        case LegacyServerSettingField.newsExpireTime: return .manageNewsgroups
        case LegacyServerSettingField.accountGroups: return .manageAccounts
        case LegacyServerSettingField.controlPort,
             LegacyServerSettingField.maxSimultaneousFileTransfers,
             LegacyServerSettingField.maxFileTransfersPerUser,
             LegacyServerSettingField.maxConnections,
             LegacyServerSettingField.maxConnectionsPerIP,
             LegacyServerSettingField.maxFolderDownloadDepth,
             LegacyServerSettingField.allowDenyIPList,
             LegacyServerSettingField.searchIndexExclusions,
             LegacyServerSettingField.legacyFilesRoot,
             LegacyServerSettingField.authenticationMode,
             LegacyServerSettingField.searchIndexRebuildIntervalHours:
            return .editAdvancedSettings
        case LegacyServerSettingField.trackerList, LegacyServerSettingField.trackerRegistrationFlags,
             LegacyServerSettingField.trackerDescription:
            return .editTrackers
        case LegacyServerSettingField.statisticHits, LegacyServerSettingField.statisticConnectionPeak,
             LegacyServerSettingField.statisticIncorrectLogins, LegacyServerSettingField.statisticAdminsConnected,
             LegacyServerSettingField.statisticAccountHoldersConnected, LegacyServerSettingField.statisticGuestsConnected,
             LegacyServerSettingField.statisticDownloadsInProgress, LegacyServerSettingField.statisticTotalDownloads,
             LegacyServerSettingField.statisticUploadsInProgress, LegacyServerSettingField.statisticTotalUploads,
             LegacyServerSettingField.statisticCurrentlyConnected, LegacyServerSettingField.statisticTotalMessages:
            return write ? nil : .viewStatistics
        case LegacyServerSettingField.uptimeTicks:
            return write ? nil : .editAdvancedSettings
        default: return nil
        }
    }

    private func settingValue(field: UInt32, state: ServerState) throws -> Data? {
        func u32(_ value: UInt64) -> Data { LegacyWire.uint32BE(UInt32(min(value, UInt64(UInt32.max)))) }
        switch field {
        case LegacyServerSettingField.agreement:
            return try LegacyAgreementSetting(
                enabled: state.agreement.enabled,
                content: LegacyAgreementContent(text: Self.macRoman(state.agreement.text), styleData: Data())
            ).encoded()
        case LegacyServerSettingField.serverName: return Self.macRoman(state.identity.name)
        case LegacyServerSettingField.location: return Self.macRoman(state.identity.location)
        case LegacyServerSettingField.serverOperator: return Self.macRoman(state.identity.operatorName)
        case LegacyServerSettingField.description: return Self.macRoman(state.identity.description)
        case LegacyServerSettingField.controlPort: return LegacyWire.uint16BE(state.advanced.controlPort)
        case LegacyServerSettingField.newsExpireTime:
            return LegacyWire.uint16BE(try LegacyServerSettingField.packNewsExpireTime(hour: state.advanced.newsExpirationHour,
                                                                                      minute: state.advanced.newsExpirationMinute))
        case LegacyServerSettingField.maxSimultaneousFileTransfers: return LegacyWire.uint16BE(state.advanced.maxSimultaneousFileTransfers)
        case LegacyServerSettingField.maxFileTransfersPerUser: return LegacyWire.uint16BE(state.advanced.maxFileTransfersPerUser)
        case LegacyServerSettingField.maxConnections: return LegacyWire.uint16BE(state.advanced.maxConnections)
        case LegacyServerSettingField.maxConnectionsPerIP: return LegacyWire.uint16BE(state.advanced.maxConnectionsPerIP)
        case LegacyServerSettingField.maxFolderDownloadDepth: return LegacyWire.uint16BE(state.advanced.maxFolderDownloadDepth)
        case LegacyServerSettingField.statisticHits: return u32(state.statistics.hits)
        case LegacyServerSettingField.statisticConnectionPeak: return u32(state.statistics.connectionPeak)
        case LegacyServerSettingField.statisticIncorrectLogins: return u32(state.statistics.incorrectLogins)
        case LegacyServerSettingField.statisticAdminsConnected: return u32(state.statistics.adminsConnected)
        case LegacyServerSettingField.statisticAccountHoldersConnected: return u32(state.statistics.accountHoldersConnected)
        case LegacyServerSettingField.statisticGuestsConnected: return u32(state.statistics.guestsConnected)
        case LegacyServerSettingField.statisticDownloadsInProgress: return u32(state.statistics.downloadsInProgress)
        case LegacyServerSettingField.statisticTotalDownloads: return u32(state.statistics.totalDownloads)
        case LegacyServerSettingField.statisticUploadsInProgress: return u32(state.statistics.uploadsInProgress)
        case LegacyServerSettingField.statisticTotalUploads: return u32(state.statistics.totalUploads)
        case LegacyServerSettingField.statisticCurrentlyConnected:
            return u32(state.statistics.adminsConnected + state.statistics.accountHoldersConnected + state.statistics.guestsConnected)
        case LegacyServerSettingField.statisticTotalMessages: return u32(state.statistics.totalMessages)
        case LegacyServerSettingField.allowDenyIPList:
            return try LegacyServerSettingField.encodeIPRestrictions(state.advanced.ipRestrictions.map(\.legacy))
        case LegacyServerSettingField.searchIndexExclusions:
            return try LegacyServerSettingField.encodeSearchIndexExclusions(state.runtime.searchIndexExclusions)
        case LegacyServerSettingField.searchIndexRebuildIntervalHours:
            return LegacyWire.uint32BE(state.runtime.searchIndexRebuildIntervalHours)
        case LegacyServerSettingField.legacyFilesRoot:
            return Data(state.runtime.legacyFilesRoot.utf8)
        case LegacyServerSettingField.authenticationMode:
            return LegacyServerSettingField.encodeAuthenticationMode(modernOnly: state.authentication.mode == .modernOnly)
        case LegacyServerSettingField.accountGroups:
            let records = state.accountGroups.map { group -> LegacyAccountGroupRecord in
                var record = group.legacyGroupRecord()
                record.memberLogins = state.accounts.filter { $0.groupID == group.id }.map(\.login).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                return record
            }
            return try LegacyServerSettingField.encodeAccountGroups(records)
        case LegacyServerSettingField.trackerList:
            return try LegacyServerSettingField.encodeTrackerSettings(state.advanced.trackers.map { try $0.legacyRecord() })
        case LegacyServerSettingField.trackerRegistrationFlags:
            return LegacyWire.uint32BE(state.advanced.trackerAdvertisementFlags)
        case LegacyServerSettingField.trackerDescription:
            return Self.macRoman(state.advanced.trackerDescription)
        case LegacyServerSettingField.uptimeTicks:
            stateLock.lock(); let began = startedAt; stateLock.unlock()
            let ticks = began.map { UInt64(max(0, Date().timeIntervalSince($0)) * 60) } ?? 0
            return u32(ticks)
        default: return nil
        }
    }

    private func handleServerLogRequest(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.viewServerLog, session: session),
              let offsetField = packet.firstField(type: 1), offsetField.value.count == 8,
              let maximumField = packet.firstField(type: 2), maximumField.value.count == 4 else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        do {
            var offsetCursor = LegacyByteCursor(offsetField.value)
            let requestedOffset = try offsetCursor.readUInt64BE()
            try offsetCursor.requireEnd()
            var maximumCursor = LegacyByteCursor(maximumField.value)
            let requestedMaximum = try maximumCursor.readUInt32BE()
            try maximumCursor.requireEnd()
            guard requestedMaximum > 0, requestedMaximum <= 60 * 1024 else {
                throw ServerStateError.invalidValue("Invalid server-log chunk size.")
            }
            let chunk = try persistentLogChunk(offset: requestedOffset, maximumBytes: Int(requestedMaximum))
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.serverLogReply,
                                                        transactionID: packet.transactionID,
                                                        fields: [
                LegacyTLV(type: 1, value: LegacyWire.uint64BE(chunk.totalBytes)),
                LegacyTLV(type: 2, value: LegacyWire.uint64BE(chunk.offset)),
                LegacyTLV(type: 3, value: chunk.data),
            ]))
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleServerLogClear(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.viewServerLog, session: session), packet.fields.isEmpty else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        do {
            try clearPersistentLog()
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            let userID = session.userID.map(String.init) ?? "unknown"
            log("Server log cleared remotely by user \(userID)")
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleEventLogRequest(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.viewServerLog, session: session),
              let offsetField = packet.firstField(type: 1), offsetField.value.count == 8,
              let maximumField = packet.firstField(type: 2), maximumField.value.count == 4 else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        do {
            var offsetCursor = LegacyByteCursor(offsetField.value)
            let requestedOffset = try offsetCursor.readUInt64BE()
            try offsetCursor.requireEnd()
            var maximumCursor = LegacyByteCursor(maximumField.value)
            let requestedMaximum = try maximumCursor.readUInt32BE()
            try maximumCursor.requireEnd()
            guard requestedMaximum > 0, requestedMaximum <= 60 * 1024 else {
                throw ServerStateError.invalidValue("Invalid event-log chunk size.")
            }
            let chunk = try persistentEventChunk(offset: requestedOffset, maximumBytes: Int(requestedMaximum))
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.eventLogReply,
                                                        transactionID: packet.transactionID,
                                                        fields: [
                LegacyTLV(type: 1, value: LegacyWire.uint64BE(chunk.totalBytes)),
                LegacyTLV(type: 2, value: LegacyWire.uint64BE(chunk.offset)),
                LegacyTLV(type: 3, value: chunk.data),
            ]))
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleEventLogClear(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard has(.viewServerLog, session: session), packet.fields.isEmpty else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        do {
            try clearPersistentEventLog()
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            appendUserEvent(session: session, category: "administration", action: "clear-events", detail: "event log cleared")
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleServerSettingsRequest(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            let state = backend.snapshot()
            var result: [LegacyTLV] = []
            for requested in packet.fields {
                guard requested.value.isEmpty else { throw ServerStateError.invalidValue("Server-settings request fields must be empty.") }
                guard let permission = settingsPermission(field: requested.type, write: false),
                      has(permission, session: session) else { continue }
                if let value = try settingValue(field: requested.type, state: state) {
                    result.append(LegacyTLV(type: requested.type, value: value))
                }
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.serverSettingsReply,
                                                        transactionID: packet.transactionID, fields: result))
        } catch {
            log("Server-settings request failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleServerSettingsUpdate(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            for field in packet.fields {
                guard let permission = settingsPermission(field: field.type, write: true), has(permission, session: session) else {
                    throw ServerStateError.invalidValue(String(format: "Server setting 0x%02x is read-only, unsupported or not permitted.", field.type))
                }
            }
            let previousState = backend.snapshot()
            let oldPort = previousState.advanced.controlPort
            var newsScheduleChanged = false
            var trackerConfigurationChanged = false
            var accountGroupsChanged = false
            var searchIndexExclusionsChanged = false
            var searchIndexRebuildIntervalChanged = false
            var legacyFilesRootChanged = false
            try backend.updateServerState { state in
                for field in packet.fields {
                    switch field.type {
                    case LegacyServerSettingField.agreement:
                        let setting = try LegacyAgreementSetting.decode(field.value)
                        guard setting.content.text.count <= 64 * 1024,
                              let text = String(data: setting.content.text, encoding: .macOSRoman) else {
                            throw ServerStateError.invalidValue("Classic agreement is invalid.")
                        }
                        state.agreement.text = text
                        state.agreement.enabled = setting.enabled
                    case LegacyServerSettingField.serverName:
                        guard let text = String(data: field.value, encoding: .macOSRoman) else { throw ServerStateError.invalidValue("Invalid server name.") }
                        state.identity.name = text
                    case LegacyServerSettingField.location:
                        guard let text = String(data: field.value, encoding: .macOSRoman) else { throw ServerStateError.invalidValue("Invalid location.") }
                        state.identity.location = text
                    case LegacyServerSettingField.serverOperator:
                        guard let text = String(data: field.value, encoding: .macOSRoman) else { throw ServerStateError.invalidValue("Invalid server operator.") }
                        state.identity.operatorName = text
                    case LegacyServerSettingField.description:
                        guard let text = String(data: field.value, encoding: .macOSRoman) else { throw ServerStateError.invalidValue("Invalid server description.") }
                        state.identity.description = text
                    case LegacyServerSettingField.controlPort: state.advanced.controlPort = try field.uint16BE()
                    case LegacyServerSettingField.newsExpireTime:
                        let parts = LegacyServerSettingField.unpackNewsExpireTime(try field.uint16BE())
                        state.advanced.newsExpirationHour = parts.hour
                        state.advanced.newsExpirationMinute = parts.minute
                        newsScheduleChanged = true
                    case LegacyServerSettingField.maxSimultaneousFileTransfers: state.advanced.maxSimultaneousFileTransfers = try field.uint16BE()
                    case LegacyServerSettingField.maxFileTransfersPerUser: state.advanced.maxFileTransfersPerUser = try field.uint16BE()
                    case LegacyServerSettingField.maxConnections: state.advanced.maxConnections = try field.uint16BE()
                    case LegacyServerSettingField.maxConnectionsPerIP: state.advanced.maxConnectionsPerIP = try field.uint16BE()
                    case LegacyServerSettingField.maxFolderDownloadDepth: state.advanced.maxFolderDownloadDepth = try field.uint16BE()
                    case LegacyServerSettingField.allowDenyIPList:
                        let rules = try LegacyServerSettingField.decodeIPRestrictions(field.value)
                        guard rules.count <= 4096 else { throw ServerStateError.invalidValue("Allow/Deny IP list exceeds 4096 rules.") }
                        state.advanced.ipRestrictions = rules.map(ServerIPRestriction.init(legacy:))
                    case LegacyServerSettingField.searchIndexExclusions:
                        let patterns = try LegacyServerSettingField.decodeSearchIndexExclusions(field.value)
                        state.runtime.searchIndexExclusions = patterns
                        searchIndexExclusionsChanged = true
                    case LegacyServerSettingField.searchIndexRebuildIntervalHours:
                        state.runtime.searchIndexRebuildIntervalHours = try field.uint32BE()
                        searchIndexRebuildIntervalChanged = true
                    case LegacyServerSettingField.authenticationMode:
                        let modernOnly = try LegacyServerSettingField.decodeAuthenticationMode(field.value)
                        try backend.applyAuthenticationModeInTransaction(modernOnly ? .modernOnly : .legacyCompatible, to: &state)
                    case LegacyServerSettingField.legacyFilesRoot:
                        guard field.value.count < 4096, let path = String(data: field.value, encoding: .utf8),
                              !path.contains("\0"), path.isEmpty || NSString(string: path).isAbsolutePath else {
                            throw ServerStateError.invalidValue("Legacy Files root must be empty or an absolute UTF-8 server path.")
                        }
                        if !path.isEmpty {
                            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path, isDirectory: true), withIntermediateDirectories: true)
                        }
                        state.runtime.legacyFilesRoot = path
                        legacyFilesRootChanged = true
                    case LegacyServerSettingField.accountGroups:
                        let records = try LegacyServerSettingField.decodeAccountGroups(field.value)
                        let decoded = try records.map(ServerAccountGroup.init(legacy:))
                        guard decoded.count == 3 else {
                            throw ServerStateError.invalidValue("Exactly three fixed Classic account groups are required.")
                        }
                        var groups: [ServerAccountGroup] = []
                        for mode in [ServerAccountMode.administrator, .accountHolder, .guest] {
                            let id = ServerState.builtInAccountGroupID(for: mode)
                            guard var group = decoded.first(where: { $0.id == id && $0.legacyMode == mode }) else {
                                throw ServerStateError.invalidValue("Administrator, Account Holder and Guest are fixed account groups.")
                            }
                            group.name = ServerState.builtInAccountGroupName(for: mode)
                            try ServerStateValidator.validate(accountGroup: group)
                            groups.append(group)
                        }
                        state.accountGroups = groups
                        ModernServerBackend.propagateAccountGroupDefaults(to: groups,
                                                                         accounts: &state.accounts)
                        accountGroupsChanged = true
                    case LegacyServerSettingField.trackerList:
                        let trackers = try LegacyServerSettingField.decodeTrackerSettings(field.value)
                        state.advanced.trackers = try trackers.map(ServerTrackerSetting.init(legacy:))
                        trackerConfigurationChanged = true
                    case LegacyServerSettingField.trackerRegistrationFlags:
                        state.advanced.trackerAdvertisementFlags = try field.uint32BE()
                        trackerConfigurationChanged = true
                    case LegacyServerSettingField.trackerDescription:
                        guard field.value.count <= 255,
                              let text = String(data: field.value, encoding: .macOSRoman) else {
                            throw ServerStateError.invalidValue("Classic tracker description is invalid.")
                        }
                        state.advanced.trackerDescription = text
                        trackerConfigurationChanged = true
                    default:
                        throw ServerStateError.invalidValue(String(format: "Server setting 0x%02x is not backed by modern state yet.", field.type))
                    }
                }
                try ServerStateValidator.validate(identity: state.identity)
                try ServerStateValidator.validate(advanced: state.advanced)
                try ServerStateValidator.validateTrackerRegistrationEligibility(state)
            }
            let updatedState = backend.snapshot()
            try persistStartupConfigurationToJSON(updatedState)
            if accountGroupsChanged { refreshConnectedAccountsFromBackendAndBroadcastColor() }
            if newsScheduleChanged { refreshNewsConfiguration() }
            if searchIndexExclusionsChanged {
                log("Search-index exclusions updated; removals take full effect on the next manual or scheduled rebuild")
            }
            if searchIndexRebuildIntervalChanged { refreshSearchIndexRebuildSchedule() }
            if legacyFilesRootChanged {
                log(updatedState.runtime.legacyFilesRoot.isEmpty
                    ? "Legacy Files root disabled; Classic sessions use the normal Files root"
                    : "Legacy Files root changed to \(updatedState.runtime.legacyFilesRoot)")
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            if trackerConfigurationChanged { refreshTrackerConfiguration() }
            onStateChanged?()
            let newPort = backend.snapshot().advanced.controlPort
            if newPort != oldPort { log("Control port changed to \(newPort); the new port takes effect on the next listener restart") }
            log("Server settings updated remotely")
        } catch {
            log("Server-settings update failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    /// The standalone server treats `etc/carracho-server.json` as the startup source of truth
    /// for these fields. Remote administration writes the same values into server.db, so mirror
    /// the startup-controlled subset back into JSON or the next daemon restart would silently
    /// restore stale values from disk. Create the config when it does not exist yet so a runtime
    /// bandwidth change made by the integrated server is durable in both persistence layers.
    func persistStartupConfigurationToJSON(_ state: ServerState) throws {
        let directory = serverSupportRoot.appendingPathComponent("etc", isDirectory: true)
        let url = directory.appendingPathComponent("carracho-server.json", isDirectory: false)
        let objectOnDisk: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ServerStateError.invalidValue("carracho-server.json is not a JSON object.")
            }
            objectOnDisk = decoded
        } else {
            objectOnDisk = [:]
        }
        var object = objectOnDisk
        if object["filesRoot"] == nil {
            object["filesRoot"] = state.runtime.filesRoot.isEmpty
                ? storageRoot.standardizedFileURL.path
                : state.runtime.filesRoot
        }

        object["serverName"] = state.identity.name
        object["description"] = state.identity.description
        object["serverPort"] = Int(state.advanced.controlPort)
        object["authenticationMode"] = state.authentication.mode.rawValue
        object["maxConnections"] = Int(state.advanced.maxConnections)
        object["maxConnectionsPerIP"] = Int(state.advanced.maxConnectionsPerIP)
        object["maxSimultaneousFileTransfers"] = Int(state.advanced.maxSimultaneousFileTransfers)
        object["maxFileTransfersPerUser"] = Int(state.advanced.maxFileTransfersPerUser)
        object["maxFolderDownloadDepth"] = Int(state.advanced.maxFolderDownloadDepth)
        object["uploadBandwidthLimitBytesPerSecond"] = NSNumber(value: state.runtime.uploadBandwidthLimitBytesPerSecond)
        object["searchIndexExclusions"] = state.runtime.searchIndexExclusions
        object["searchIndexRebuildIntervalHours"] = Int(state.runtime.searchIndexRebuildIntervalHours)
        object["legacyFilesRoot"] = state.runtime.legacyFilesRoot
        object["newsExpirationHour"] = Int(state.advanced.newsExpirationHour)
        object["newsExpirationMinute"] = Int(state.advanced.newsExpirationMinute)

        let trackerFlags = state.advanced.trackerAdvertisementFlags
        let bandwidthCode = UInt8((trackerFlags >> 24) & 0xff)
        let bandwidthTitle = LegacyTrackerProtocol.bandwidthTitle(for: bandwidthCode)
            ?? (bandwidthCode == 0 ? "Not specified" : "Unknown (code \(bandwidthCode))")
        object["trackerRegistration"] = [
            "enabled": (trackerFlags & LegacyTrackerProtocol.registeredFlag) != 0,
            "private": (trackerFlags & LegacyTrackerProtocol.privateFlag) != 0,
            "bandwidthCode": Int(bandwidthCode),
            "bandwidth": bandwidthTitle,
            "flags": NSNumber(value: trackerFlags),
            "description": state.advanced.trackerDescription,
            "trackers": state.advanced.trackers.map { tracker in
                [
                    "name": tracker.name,
                    "address": tracker.address,
                    "enabled": tracker.isRegistrationEnabled,
                    "reservedString": tracker.reservedString,
                    "reservedValue": NSNumber(value: tracker.reservedValue),
                ] as [String: Any]
            },
        ] as [String: Any]

        // Keep an existing filesRoot exactly as configured. The runtime state contains the resolved
        // absolute path, while JSON may intentionally use a portable path such as "../Files".
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let updated = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try updated.write(to: url, options: .atomic)
        // Standalone server configuration can contain the HTTP administration bearer token.
        // Preserve private file permissions after any remote/settings mirror rewrite.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func flatNewsHeaderString(session: LegacyServerSession, now: Date = Date()) -> String {
        let nickname = String(data: session.nickname, encoding: .macOSRoman) ?? session.account?.login ?? "Unknown"
        let login = session.account?.login ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss"
        return "From: \(nickname) (\(login))\rDate: \(formatter.string(from: now))\r\r"
    }

    private func flatNewsLegacyWireEntry(_ stored: Data) throws -> Data {
        guard CarrachoTextWire.isTaggedUTF8(stored) else { return stored }
        let text = CarrachoTextWire.string(from: stored)
        guard let downgraded = text.data(using: .macOSRoman, allowLossyConversion: true),
              downgraded.count <= Int(UInt16.max) else {
            throw ServerFlatNewsStoreError.invalidEntry("Unicode Flat News could not be downgraded for a Classic client.")
        }
        return downgraded
    }

    private func flatNewsWireEntry(_ stored: Data, for session: LegacyServerSession) throws -> Data {
        session.isLegacyTransport ? try flatNewsLegacyWireEntry(stored) : stored
    }

    private func handleFlatNewsPost(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard session.account?.permissions.contains(.postFlatNews) == true,
              let content = packet.firstField(type: LegacyCommand.flatNewsPost)?.value,
              let text = CarrachoTextWire.validatedString(from: content),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !(session.isLegacyTransport && CarrachoTextWire.isTaggedUTF8(content)) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 2)); return
        }
        do {
            let header = flatNewsHeaderString(session: session)
            let entry: Data
            if CarrachoTextWire.isTaggedUTF8(content) {
                entry = try CarrachoTextWire.encode(header + text, maximumBytes: Int(UInt16.max))
            } else {
                guard var classic = header.data(using: .macOSRoman) else {
                    throw ServerFlatNewsStoreError.invalidEntry("Flat-news header is not representable in MacRoman.")
                }
                classic.append(content)
                guard classic.count <= Int(UInt16.max) else {
                    throw ServerFlatNewsStoreError.invalidEntry("Flat-news post exceeds the Classic TLV limit after adding its header.")
                }
                entry = classic
            }
            _ = try flatNewsStore.append(entry)
            for recipient in authenticatedSessions() {
                let wireEntry = try flatNewsWireEntry(entry, for: recipient)
                let event = LegacyPacket(command: LegacyCommand.flatNewsPost, transactionID: 0,
                                         fields: [LegacyTLV(type: LegacyCommand.flatNewsPost, value: wireEntry)])
                try? recipient.sendAuthenticated(event)
            }
            try sendTaskComplete(packet, to: session)
            log("Flat news article posted by user \(session.userID.map(String.init) ?? "?")")
        } catch {
            log("Flat-news post failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleFlatNewsList(packet: LegacyPacket, session: LegacyServerSession) throws {
        do {
            let entries = try flatNewsStore.all()
            let fields = try entries.map {
                LegacyTLV(type: LegacyCommand.flatNewsPost, value: try flatNewsWireEntry($0, for: session))
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.flatNewsList,
                                                        transactionID: packet.transactionID, fields: fields))
        } catch {
            log("Flat-news list failed: \(error.localizedDescription)")
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleFlatNewsDelete(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard session.account?.permissions.contains(.manageNewsgroups) == true,
              let indexField = packet.firstField(type: LegacyCommand.flatNewsDelete) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 2)); return
        }
        do {
            let index = try indexField.uint32BE()
            _ = try flatNewsStore.delete(wireIndex: index)
            let event = LegacyPacket(command: LegacyCommand.flatNewsDelete, transactionID: 0,
                                     fields: [LegacyTLV(type: LegacyCommand.flatNewsDelete, value: LegacyWire.uint32BE(index))])
            authenticatedSessions().forEach { try? $0.sendAuthenticated(event) }
            try sendTaskComplete(packet, to: session)
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleFlatNewsClear(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard session.account?.permissions.contains(.manageNewsgroups) == true else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 2)); return
        }
        do {
            try flatNewsStore.clear()
            let event = LegacyPacket(command: LegacyCommand.flatNewsClear, transactionID: 0, fields: [])
            authenticatedSessions().forEach { try? $0.sendAuthenticated(event) }
            try sendTaskComplete(packet, to: session)
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func handleBroadcastMessage(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard session.account?.permissions.contains(.broadcastMessages) == true,
              let senderID = session.userID,
              let message = packet.firstField(type: 1)?.value,
              let decoded = CarrachoTextWire.validatedString(from: message),
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.count <= 0x200,
              !(session.isLegacyTransport && CarrachoTextWire.isTaggedUTF8(message)) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 2))
            return
        }
        for recipient in authenticatedSessions() {
            let wireMessage: Data
            if recipient.isLegacyTransport, CarrachoTextWire.isTaggedUTF8(message) {
                guard let classic = CarrachoTextWire.macRomanDescribingEmoji(from: message, maximumBytes: 0x200),
                      !classic.isEmpty else { continue }
                wireMessage = classic
            } else {
                wireMessage = message
            }
            let event = LegacyPacket(command: LegacyCommand.broadcastMessage, transactionID: 0, fields: [
                LegacyTLV(type: 1, value: wireMessage),
                LegacyTLV(type: 2, value: LegacyWire.uint32BE(senderID)),
            ])
            try? recipient.sendAuthenticated(event)
        }
        try sendTaskComplete(packet, to: session)
        recordMessage()
        log("Message broadcasted by user \(senderID)")
    }

    private func channelNameEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let a = String(data: lhs, encoding: .macOSRoman),
              let b = String(data: rhs, encoding: .macOSRoman) else { return lhs == rhs }
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func nextAvailableChannelIDLocked() -> UInt32 {
        while nextChannelID == 0 || channels[nextChannelID] != nil { nextChannelID &+= 1 }
        let result = nextChannelID
        nextChannelID &+= 1
        if nextChannelID == 0 { nextChannelID = 2 }
        return result
    }

    private func handleChannelJoin(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let userID = session.userID,
              session.account?.permissions.contains(.joinChatRooms) == true else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 2)); return
        }
        do {
            let requestedID = try packet.firstField(type: LegacyChannelField.channelID)?.uint32BE() ?? 0
            let name = packet.firstField(type: LegacyChannelField.name)?.value ?? Data()
            let password = packet.firstField(type: LegacyChannelField.password)?.value ?? Data()
            guard name.count <= 64, password.count <= 32, requestedID != 0 || !name.isEmpty else {
                throw LegacyServerRuntimeError.protocolFailure("invalid channel join/create request")
            }

            stateLock.lock()
            let joinedCount = channels.values.reduce(0) { $0 + ($1.members[userID] == nil ? 0 : 1) }
            guard joinedCount < 6 else {
                stateLock.unlock()
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 0xd1)); return
            }

            var channelID: UInt32?
            if requestedID != 0, channels[requestedID] != nil { channelID = requestedID }
            if channelID == nil, requestedID == 0 {
                channelID = channels.values.first(where: { channelNameEquals($0.name, name) })?.id
            }
            if channelID == nil {
                guard !name.isEmpty else { stateLock.unlock(); throw LegacyServerRuntimeError.protocolFailure("channel not found") }
                let id = nextAvailableChannelIDLocked()
                channels[id] = RuntimeChannel(id: id, name: name, password: password)
                channelID = id
            }
            guard let id = channelID, var channel = channels[id] else {
                stateLock.unlock(); throw LegacyServerRuntimeError.protocolFailure("channel not found")
            }
            guard channel.password.isEmpty || channel.password == password else {
                stateLock.unlock()
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 0xca)); return
            }
            guard channel.members[userID] == nil else {
                stateLock.unlock()
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 0xce)); return
            }
            var mode: UInt8 = 0
            if (channel.members.isEmpty && id != Self.publicChannelID) ||
                (id == Self.publicChannelID && session.account?.mode == .administrator) {
                mode |= Self.channelOperatorMode
            }
            let priorRecipients = channel.members.keys.compactMap { authenticatedByUserID[$0] }
            channel.members[userID] = mode
            channels[id] = channel
            let members = channel.members.keys.sorted().map { LegacyChannelMember(userID: $0, mode: channel.members[$0] ?? 0) }
            stateLock.unlock()

            let reply = LegacyPacket(command: LegacyCommand.channelJoin, transactionID: packet.transactionID, fields: [
                LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(id)),
                LegacyTLV(type: LegacyChannelField.name, value: channel.name),
                LegacyTLV(type: LegacyChannelField.topic, value: channel.topic),
                LegacyTLV(type: LegacyChannelField.members, value: LegacyPackedRecords.encodeChannelMembers(members)),
                LegacyTLV(type: LegacyChannelField.settings, value: LegacyWire.uint16BE(channel.flags)),
            ])
            let joined = LegacyPacket(command: LegacyCommand.channelUserJoined, transactionID: 0, fields: [
                LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(id)),
                LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
                LegacyTLV(type: LegacyChannelField.userMode, value: Data([mode])),
            ])
            // Server 1.0b13 queues the asynchronous 0x87 for existing members before replying
            // to the joining user with 0x80. Preserve that ordering for Classic compatibility.
            priorRecipients.forEach { try? $0.sendAuthenticated(joined) }
            try session.sendAuthenticated(reply)
            if id == Self.publicChannelID { greetNewPublicMemberIfNeeded(session) }
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 200))
        }
    }

    private func handleChannelLeave(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let userID = session.userID,
              let field = packet.firstField(type: LegacyChannelField.channelID) else { return }
        let id = try field.uint32BE()
        stateLock.lock()
        guard var channel = channels[id] else { stateLock.unlock(); return }
        let wasMember = channel.members.removeValue(forKey: userID) != nil
        let recipients = channel.members.keys.compactMap { authenticatedByUserID[$0] }
        if channel.members.isEmpty && id != Self.publicChannelID && (channel.flags & Self.channelPermanentFlag) == 0 {
            channels.removeValue(forKey: id)
        } else { channels[id] = channel }
        stateLock.unlock()
        if wasMember {
            let left = LegacyPacket(command: LegacyCommand.channelUserLeft, transactionID: 0, fields: [
                LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(id)),
                LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
            ])
            // Historical ordering: remaining members see 0x88 before the leaver gets 0x81.
            recipients.forEach { try? $0.sendAuthenticated(left) }
        }
        try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.channelLeave,
                                                    transactionID: packet.transactionID, fields: []))
    }

    private func handleChannelDelete(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard !session.isLegacyTransport,
              session.account?.mode == .administrator,
              let idField = packet.firstField(type: LegacyChannelField.channelID),
              idField.value.count == 4 else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 2))
            return
        }
        let channelID = try idField.uint32BE()
        guard channelID != Self.publicChannelID else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 200))
            return
        }

        stateLock.lock()
        guard let channel = channels.removeValue(forKey: channelID) else {
            stateLock.unlock()
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 200))
            return
        }
        let memberIDs = channel.members.keys.sorted()
        let classicMembers = memberIDs.compactMap { authenticatedByUserID[$0] }.filter { $0.isLegacyTransport }
        let modernRecipients = authenticatedByUserID.values.filter { !$0.isLegacyTransport }
        stateLock.unlock()

        try sendTaskComplete(packet, to: session)

        // Classic has no room-deleted command. Empty its visible member list using the historical
        // leave event, but never send the modern extension to a Classic control connection.
        for classic in classicMembers {
            for userID in memberIDs {
                let left = LegacyPacket(command: LegacyCommand.channelUserLeft, transactionID: 0, fields: [
                    LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
                    LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
                ])
                try? classic.sendAuthenticated(left)
            }
        }

        let deleted = LegacyPacket(command: LegacyCommand.channelDeleted, transactionID: 0, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(channelID)),
            LegacyTLV(type: LegacyChannelField.name, value: channel.name),
        ])
        modernRecipients.forEach { try? $0.sendAuthenticated(deleted) }
        log("Channel \(channelID) deleted by administrator user \(session.userID.map(String.init) ?? "?")")
    }

    private func handleChannelChat(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let userID = session.userID,
              let channelField = packet.firstField(type: LegacyChannelField.channelID),
              let message = packet.firstField(type: LegacyChannelField.message)?.value,
              !message.isEmpty, message.count <= 0x800 else { return }
        let id = try channelField.uint32BE()
        let attribute = packet.firstField(type: LegacyChannelField.chatAttribute)?.value.first ?? 0
        stateLock.lock()
        guard let channel = channels[id], let mode = channel.members[userID] else { stateLock.unlock(); return }
        let canSpeak = (channel.flags & Self.channelRestrictedChatFlag) == 0 ||
            (mode & (Self.channelOperatorMode | Self.channelSpeechMode)) != 0
        let recipients = channel.members.keys.compactMap { authenticatedByUserID[$0] }
        stateLock.unlock()
        guard canSpeak else {
            if packet.transactionID != 0 { try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 0xcb)) }
            return
        }
        guard LegacyYouTubeReference.hasOnlyValidTokens(inWire: message,
                                                        maximum: LegacyMediaTransfer.maximumYouTubeLinksPerChatMessage) else {
            log("Channel YouTube reference rejected for user \(userID)")
            return
        }
        guard let accountID = session.account?.id else { return }
        do {
            try validateAndBindMediaReferences(in: message, ownerAccountID: accountID,
                                               maximum: LegacyMediaTransfer.maximumImagesPerChatMessage,
                                               kind: .chat, scope: String(id), messageID: UUID().uuidString.lowercased(),
                                               expiresAt: Date().addingTimeInterval(LegacyMediaTransfer.chatLifetime))
        } catch {
            log("Channel media reference rejected for user \(userID): \(error.localizedDescription)")
            return
        }
        let editableID = !session.isLegacyTransport &&
            LegacyMediaReference.references(inWire: message).isEmpty
            ? LegacyMessageEdit.parseIdentifier(packet.firstField(type: LegacyMessageEdit.messageID)?.value)
            : nil
        let sentAt = Date()
        if let editableID, !registerEditableMessage(id: editableID, senderID: userID,
                                                    kind: LegacyMessageEdit.channel,
                                                    scope: id, createdAt: sentAt) {
            if packet.transactionID != 0 {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            }
            return
        }
        for recipient in recipients {
            let wireMessage: Data
            if recipient.isLegacyTransport, CarrachoTextWire.isTaggedUTF8(message) {
                guard let classic = CarrachoTextWire.macRomanDescribingEmoji(from: message, maximumBytes: 0x800),
                      !classic.isEmpty else { continue }
                wireMessage = classic
            } else {
                wireMessage = message
            }
            var fields = [
                LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(id)),
                LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(userID)),
                LegacyTLV(type: LegacyChannelField.message, value: wireMessage),
                LegacyTLV(type: LegacyChannelField.chatAttribute, value: Data([attribute])),
            ]
            if !recipient.isLegacyTransport, let editableID {
                fields.append(LegacyTLV(type: LegacyMessageEdit.messageID, value: LegacyMessageEdit.identifier(editableID)))
                fields.append(LegacyTLV(type: LegacyMessageEdit.sentAt,
                                        value: LegacyWire.uint64BE(UInt64(sentAt.timeIntervalSince1970))))
            }
            try? recipient.sendAuthenticated(LegacyPacket(command: LegacyCommand.channelChat,
                                                         transactionID: 0, fields: fields))
        }
        try sendTaskCompleteIfRequested(packet, to: session)
        recordMessage()
        respondToLocalBotChannelCommandIfNeeded(message, from: session, channelID: id)
    }

    private func handleMessageEdit(packet: LegacyPacket, session: LegacyServerSession) throws {
        func reject() throws {
            if packet.transactionID != 0 {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            }
        }
        guard !session.isLegacyTransport, let senderID = session.userID,
              let id = LegacyMessageEdit.parseIdentifier(packet.firstField(type: 1)?.value),
              let body = packet.firstField(type: 2)?.value,
              !body.isEmpty, body.count <= 0x8000,
              CarrachoTextWire.validatedString(from: body) != nil,
              LegacyMediaReference.references(inWire: body).isEmpty,
              LegacyYouTubeReference.hasOnlyValidTokens(inWire: body,
                  maximum: LegacyMediaTransfer.maximumYouTubeLinksPerChatMessage) else {
            try reject(); return
        }

        stateLock.lock()
        let record = editableMessages[id]
        let uptime = ProcessInfo.processInfo.systemUptime
        let valid = record != nil && record!.senderID == senderID &&
            uptime >= record!.sentUptime &&
            uptime - record!.sentUptime <= LegacyMessageEdit.maximumAge &&
            (record!.kind != LegacyMessageEdit.channel || body.count <= 0x800)
        var recipients: [(LegacyServerSession, UInt32)] = []
        if valid, let record {
            if record.kind == LegacyMessageEdit.channel,
               let room = channels[record.scope], room.members[senderID] != nil {
                recipients = room.members.keys.compactMap { userID in
                    guard let peer = authenticatedByUserID[userID], !peer.isLegacyTransport else { return nil }
                    return (peer, record.scope)
                }
            } else if record.kind == LegacyMessageEdit.privateMessage,
                      let target = authenticatedByUserID[record.scope],
                      !target.isLegacyTransport {
                recipients = [(target, senderID), (session, record.scope)]
            }
        }
        stateLock.unlock()
        guard valid, !recipients.isEmpty else { try reject(); return }

        // The server, not the client's clock, decides when the edit window closes.
        // The original packet is never resent to Classic peers, which cannot process edits.
        for (recipient, scope) in recipients {
            let event = LegacyPacket(command: LegacyCommand.messageEdited, transactionID: 0, fields: [
                LegacyTLV(type: 1, value: LegacyMessageEdit.identifier(id)),
                LegacyTLV(type: 2, value: Data([record!.kind])),
                LegacyTLV(type: 3, value: LegacyWire.uint32BE(scope)),
                LegacyTLV(type: 4, value: body),
            ])
            try? recipient.sendAuthenticated(event)
        }
        try sendTaskCompleteIfRequested(packet, to: session)
    }

    private func handleChannelSettings(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let userID = session.userID,
              let idField = packet.firstField(type: LegacyChannelField.channelID) else { return }
        let id = try idField.uint32BE()
        let requestedTopic = packet.firstField(type: LegacyChannelField.topic)?.value ?? Data()
        guard requestedTopic.count <= 0x100 else { return }
        let requestedFlags = try packet.firstField(type: LegacyChannelField.settings)?.uint16BE() ?? 0

        stateLock.lock()
        guard var channel = channels[id], let mode = channel.members[userID] else { stateLock.unlock(); return }
        let isOperator = (mode & Self.channelOperatorMode) != 0
        if requestedTopic != channel.topic {
            if (channel.flags & Self.channelRestrictedTopicFlag) != 0 && !isOperator {
                stateLock.unlock()
                if packet.transactionID != 0 { try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 0xcd)) }
                return
            }
            channel.topic = requestedTopic
        }
        if isOperator && id != Self.publicChannelID {
            let preserved = channel.flags & (Self.channelPermanentFlag | Self.channelPreservedFlag1)
            channel.flags = (requestedFlags & ~(Self.channelPermanentFlag | Self.channelPreservedFlag1)) | preserved
            channel.flags &= ~Self.channelPermanentFlag
        }
        channels[id] = channel
        let recipients = channel.members.keys.compactMap { authenticatedByUserID[$0] }
        stateLock.unlock()
        let event = LegacyPacket(command: LegacyCommand.channelSettings, transactionID: 0, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(id)),
            LegacyTLV(type: LegacyChannelField.topic, value: channel.topic),
            LegacyTLV(type: LegacyChannelField.settings, value: LegacyWire.uint16BE(channel.flags)),
        ])
        recipients.forEach { try? $0.sendAuthenticated(event) }
    }

    private func handleChannelUserMode(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let requesterID = session.userID,
              let idField = packet.firstField(type: LegacyChannelField.channelID),
              let targetField = packet.firstField(type: LegacyChannelField.userID),
              let mode = packet.firstField(type: LegacyChannelField.userMode)?.value.first else { return }
        let id = try idField.uint32BE()
        let targetID = try targetField.uint32BE()
        stateLock.lock()
        guard var channel = channels[id], let requesterMode = channel.members[requesterID] else { stateLock.unlock(); return }
        guard (requesterMode & Self.channelOperatorMode) != 0, channel.members[targetID] != nil else {
            stateLock.unlock()
            if packet.transactionID != 0 { try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 0xcc)) }
            return
        }
        channel.members[targetID] = mode
        channels[id] = channel
        let recipients = channel.members.keys.compactMap { authenticatedByUserID[$0] }
        stateLock.unlock()
        let event = LegacyPacket(command: LegacyCommand.channelUserMode, transactionID: 0, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(id)),
            LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(targetID)),
            LegacyTLV(type: LegacyChannelField.userMode, value: Data([mode])),
        ])
        recipients.forEach { try? $0.sendAuthenticated(event) }
    }

    private func handleChannelInvite(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let inviterID = session.userID,
              let idField = packet.firstField(type: LegacyChannelField.channelID),
              let targetField = packet.firstField(type: LegacyChannelField.userID) else { return }
        let id = try idField.uint32BE()
        let targetID = try targetField.uint32BE()
        stateLock.lock()
        guard let channel = channels[id], channel.members[targetID] == nil,
              let target = authenticatedByUserID[targetID] else { stateLock.unlock(); return }
        let name = channel.name
        stateLock.unlock()
        try target.sendAuthenticated(LegacyPacket(command: LegacyCommand.channelInvite, transactionID: 0, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(id)),
            LegacyTLV(type: 0x0b, value: LegacyWire.uint32BE(inviterID)),
            LegacyTLV(type: LegacyChannelField.name, value: name),
        ]))
        try sendTaskCompleteIfRequested(packet, to: session)
    }

    private func handleChannelDeclineInvitation(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let decliningID = session.userID,
              let idField = packet.firstField(type: LegacyChannelField.channelID),
              let inviterField = packet.firstField(type: 0x0b) else { return }
        let id = try idField.uint32BE()
        let inviterID = try inviterField.uint32BE()
        stateLock.lock()
        guard let channel = channels[id], channel.members[inviterID] != nil,
              let inviter = authenticatedByUserID[inviterID] else { stateLock.unlock(); return }
        stateLock.unlock()
        try inviter.sendAuthenticated(LegacyPacket(command: LegacyCommand.channelDeclineInvitation, transactionID: 0, fields: [
            LegacyTLV(type: LegacyChannelField.channelID, value: LegacyWire.uint32BE(id)),
            LegacyTLV(type: LegacyChannelField.userID, value: LegacyWire.uint32BE(decliningID)),
        ]))
    }

    fileprivate static func errorPacket(transactionID: UInt32, code: UInt16) -> LegacyPacket {
        LegacyPacket(command: LegacyCommand.error, transactionID: transactionID,
                     fields: [LegacyTLV(type: 1, value: LegacyWire.uint16BE(code))])
    }

    fileprivate func recordLoginFailure() {
        do { try backend.mutateStatistics { $0.incorrectLogins &+= 1 } }
        catch { log("Could not persist failed-login statistic: \(error.localizedDescription)") }
    }

    private func recordLoginSuccess(mode: ServerAccountMode) {
        do {
            try backend.mutateStatistics { stats in
                stats.hits &+= 1
                switch mode {
                case .administrator: stats.adminsConnected &+= 1
                case .accountHolder: stats.accountHoldersConnected &+= 1
                case .guest: stats.guestsConnected &+= 1
                }
                let current = stats.adminsConnected + stats.accountHoldersConnected + stats.guestsConnected
                stats.connectionPeak = max(stats.connectionPeak, current)
            }
        } catch { log("Could not persist login statistics: \(error.localizedDescription)") }
    }

    private func recordDisconnect(mode: ServerAccountMode) {
        do {
            try backend.mutateStatistics { stats in
                switch mode {
                case .administrator: if stats.adminsConnected > 0 { stats.adminsConnected -= 1 }
                case .accountHolder: if stats.accountHoldersConnected > 0 { stats.accountHoldersConnected -= 1 }
                case .guest: if stats.guestsConnected > 0 { stats.guestsConnected -= 1 }
                }
            }
        } catch { log("Could not persist disconnect statistics: \(error.localizedDescription)") }
    }

    private func recordMessage() {
        do { try backend.mutateStatistics { $0.totalMessages &+= 1 } }
        catch { log("Could not persist message statistic: \(error.localizedDescription)") }
    }

    private func emitStatus() {
        let value = status
        onStatus?(value)
    }

    fileprivate func log(_ message: String) {
        appendPersistentLog(message)
        onLog?(message)
    }

    private func appendPersistentLog(_ message: String) {
        let safeMessage = message
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let line = "\(formatter.string(from: Date())) \(safeMessage)\n"
        guard let data = line.data(using: .utf8) else { return }

        logFileLock.lock()
        defer { logFileLock.unlock() }
        do {
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                _ = FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } catch {
            // Logging must never take the server down. The console/UI callback still receives the message.
        }
    }

    private func persistentLogChunk(offset: UInt64, maximumBytes: Int) throws
        -> (totalBytes: UInt64, offset: UInt64, data: Data) {
        logFileLock.lock()
        defer { logFileLock.unlock() }
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return (0, 0, Data()) }
        let handle = try FileHandle(forReadingFrom: logFileURL)
        defer { try? handle.close() }
        let total = handle.seekToEndOfFile()
        let start = min(offset, total)
        handle.seek(toFileOffset: start)
        let available = total - start
        let count = min(maximumBytes, Int(min(available, UInt64(Int.max))))
        let data = count > 0 ? handle.readData(ofLength: count) : Data()
        return (total, start, data)
    }

    private func clearPersistentLog() throws {
        logFileLock.lock()
        defer { logFileLock.unlock() }
        try FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            guard FileManager.default.createFile(atPath: logFileURL.path, contents: nil) else {
                throw ServerStateError.invalidValue("Could not create the server log.")
            }
            return
        }
        let handle = try FileHandle(forWritingTo: logFileURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
    }

    private func appendUserEvent(session: LegacyServerSession, category: String, action: String, detail: String) {
        let nickname = String(data: session.nickname, encoding: .macOSRoman) ?? ""
        appendUserEvent(userID: session.userID ?? 0,
                        login: session.account?.login ?? "",
                        nickname: nickname,
                        peerIP: session.peerIP,
                        category: category, action: action, detail: detail)
    }

    private func appendUserEvent(access: LegacyTransferAccess, category: String, action: String, detail: String) {
        appendUserEvent(userID: access.userID,
                        login: access.account.login,
                        nickname: String(data: access.nickname, encoding: .macOSRoman) ?? "",
                        peerIP: access.peerIP,
                        category: category, action: action, detail: detail)
    }

    private func appendUserEvent(userID: UInt32, login: String, nickname: String, peerIP: String,
                                 category: String, action: String, detail: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let safeDetail = detail.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        let line = "\(formatter.string(from: Date())) category=\(Self.quotedLogValue(category)) action=\(Self.quotedLogValue(action)) " +
            "user_id=\(userID) login=\(Self.quotedLogValue(login)) nickname=\(Self.quotedLogValue(nickname)) " +
            "peer_ip=\(Self.quotedLogValue(peerIP)) detail=\(Self.quotedLogValue(safeDetail))\n"
        guard let data = line.data(using: .utf8) else { return }
        eventFileLock.lock()
        defer { eventFileLock.unlock() }
        do {
            if !FileManager.default.fileExists(atPath: eventFileURL.path) {
                _ = FileManager.default.createFile(atPath: eventFileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: eventFileURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } catch {
            // The audit trail must never take down the service.
        }
    }

    private func persistentEventChunk(offset: UInt64, maximumBytes: Int) throws
        -> (totalBytes: UInt64, offset: UInt64, data: Data) {
        eventFileLock.lock()
        defer { eventFileLock.unlock() }
        guard FileManager.default.fileExists(atPath: eventFileURL.path) else { return (0, 0, Data()) }
        let handle = try FileHandle(forReadingFrom: eventFileURL)
        defer { try? handle.close() }
        let total = handle.seekToEndOfFile()
        let start = min(offset, total)
        handle.seek(toFileOffset: start)
        let available = total - start
        let count = min(maximumBytes, Int(min(available, UInt64(Int.max))))
        let data = count > 0 ? handle.readData(ofLength: count) : Data()
        return (total, start, data)
    }

    func eventLogTextSnapshot(maximumBytes: UInt64 = 8 * 1024 * 1024) throws -> String {
        eventFileLock.lock()
        defer { eventFileLock.unlock() }
        guard FileManager.default.fileExists(atPath: eventFileURL.path) else { return "" }
        let handle = try FileHandle(forReadingFrom: eventFileURL)
        defer { try? handle.close() }
        let total = handle.seekToEndOfFile()
        let start = total > maximumBytes ? total - maximumBytes : 0
        handle.seek(toFileOffset: start)
        var text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        if start > 0 { text = "[Showing the last 8 MiB of the event log; earlier bytes were omitted.]\n" + text }
        return text
    }

    func clearEventLogLocally() throws { try clearPersistentEventLog() }

    private func clearPersistentEventLog() throws {
        eventFileLock.lock()
        defer { eventFileLock.unlock() }
        try FileManager.default.createDirectory(at: eventFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: eventFileURL.path) {
            guard FileManager.default.createFile(atPath: eventFileURL.path, contents: nil) else {
                throw ServerStateError.invalidValue("Could not create the event log.")
            }
            return
        }
        let handle = try FileHandle(forWritingTo: eventFileURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
    }

    private func recordUserRequestEvent(_ packet: LegacyPacket, session: LegacyServerSession) {
        let fieldText: (UInt32) -> String = { type in
            guard let data = packet.firstField(type: type)?.value else { return "" }
            return String(data: data, encoding: .macOSRoman) ?? ""
        }
        let pathText: (UInt32) -> String = { type in
            let data = packet.firstField(type: type)?.value ?? Data()
            return data.isEmpty ? "/" : LegacyPath.displayString(data)
        }
        var event: (String, String, String)?
        switch packet.command {
        case LegacyCommand.directory: event = ("files", "list", "path=\(pathText(1))")
        case LegacyCommand.fileInfo: event = ("files", "info", "path=\(pathText(1))")
        case LegacyCommand.createFolder: event = ("files", "create-folder", "parent=\(pathText(1)) name=\(fieldText(3))")
        case LegacyCommand.deleteFile: event = ("files", "delete", "path=\(pathText(1))")
        case LegacyCommand.moveFile: event = ("files", "move", "from=\(pathText(1)) to=\(pathText(2))")
        case LegacyCommand.setFileInfo: event = ("files", "set-info", "path=\(pathText(1))")
        case LegacyCommand.fileLabelSet: event = ("files", "set-label", "path=\(pathText(1))")
        case LegacyCommand.articleRead:
            let article = (try? packet.firstField(type: 2)?.uint32BE()).flatMap { $0 }.map(String.init) ?? "?"
            event = ("news", "read-article", "category=\(fieldText(1)) article=\(article)")
        case LegacyCommand.forumThreadEntries:
            let thread = (try? packet.firstField(type: 2)?.uint32BE()).flatMap { $0 }.map(String.init) ?? "?"
            event = ("news", "read-thread", "category=\(fieldText(1)) thread=\(thread)")
        case LegacyCommand.flatNewsList: event = ("news", "read-flat-news", "")
        case LegacyCommand.flatNewsPost: event = ("news", "post-flat-news", "")
        case LegacyCommand.channelJoin: event = ("chat", "join", fieldText(LegacyChannelField.name).isEmpty ? "channel_id=requested" : "channel=\(fieldText(LegacyChannelField.name))")
        case LegacyCommand.channelLeave: event = ("chat", "leave", "")
        case LegacyCommand.channelChat: event = ("chat", "message", "")
        case LegacyCommand.channelDelete: event = ("chat", "delete", "")
        case LegacyCommand.privateMessage: event = ("messages", "private-message", "")
        case LegacyCommand.offlineMessageSend: event = ("messages", "offline-message", "recipient=\(fieldText(1))")
        case LegacyCommand.broadcastMessage: event = ("messages", "broadcast", "")
        case LegacyCommand.accountCreateOrModify: event = ("administration", "save-account", "")
        case LegacyCommand.accountDelete: event = ("administration", "delete-account", "")
        case LegacyCommand.newsgroupCreate: event = ("administration", "create-news-category", "name=\(fieldText(1))")
        case LegacyCommand.newsgroupModify: event = ("administration", "modify-news-category", "name=\(fieldText(1))")
        case LegacyCommand.newsgroupDelete: event = ("administration", "delete-news-category", "name=\(fieldText(1))")
        case LegacyCommand.setServerSettings: event = ("administration", "change-server-settings", "")
        case LegacyCommand.botSetEnabled: event = ("administration", "control-bot", "")
        case LegacyCommand.botSetGreeting: event = ("administration", "configure-bot-greeting", "")
        case LegacyCommand.botSetCommandRules: event = ("administration", "configure-bot-commands", "")
        case LegacyCommand.botSetRSSFeeds: event = ("administration", "configure-bot-rss", "")
        case LegacyCommand.botTestRSSFeed: event = ("administration", "test-bot-rss", "")
        case LegacyCommand.botSetFileWatchers: event = ("administration", "configure-bot-file-watchers", "")
        case LegacyCommand.rebuildSearchIndex: event = ("administration", "rebuild-search-index", "")
        case LegacyCommand.changeOwnPassword: event = ("account", "change-password", "")
        default: break
        }
        if let event { appendUserEvent(session: session, category: event.0, action: event.1, detail: event.2) }
    }

    private static func quotedLogValue(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private func logFileTransfer(_ descriptor: ActiveTransferDescriptor, access: LegacyTransferAccess,
                                 direction: LegacyFileTransferDirection, succeeded: Bool) {
        let status = succeeded ? "completed" : (descriptor.aborting ? "aborted" : "failed")
        let directionText = direction == .download ? "download" : "upload"
        let path = descriptor.path.isEmpty ? "" : LegacyPath.displayString(descriptor.path)
        let nickname = String(data: access.nickname, encoding: .macOSRoman) ?? ""
        let resumedBytes = descriptor.bytesTransferred >= descriptor.wireBytesTransferred
            ? descriptor.bytesTransferred - descriptor.wireBytesTransferred : 0
        log("event=file_transfer direction=\(directionText) status=\(status) transfer_id=\(descriptor.transferID) " +
            "user_id=\(access.userID) login=\(Self.quotedLogValue(access.account.login)) " +
            "nickname=\(Self.quotedLogValue(nickname)) peer_ip=\(Self.quotedLogValue(access.peerIP)) " +
            "path=\(Self.quotedLogValue(path)) size_bytes=\(descriptor.totalBytes) " +
            "transferred_bytes=\(descriptor.bytesTransferred) wire_bytes=\(descriptor.wireBytesTransferred) " +
            "resumed_bytes=\(resumedBytes)")
    }

    private static func classicAgreementText(_ value: String) -> Data {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: String(UnicodeScalar(0x2028)!), with: "\n")
            .replacingOccurrences(of: String(UnicodeScalar(0x2029)!), with: "\n")

        let maximumTextBytes = LegacyAgreementSetting.maximumClassicWireLength - 8
        var result = Data()
        result.reserveCapacity(min(normalized.utf8.count, maximumTextBytes))

        for character in normalized {
            if character == "\n" {
                if result.count < maximumTextBytes { result.append(0x0d) }
                continue
            }
            if character == "\t" {
                if result.count < maximumTextBytes { result.append(0x09) }
                continue
            }
            if character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
                continue
            }
            guard let encoded = String(character).data(using: .macOSRoman),
                  result.count + encoded.count <= maximumTextBytes else {
                continue
            }
            result.append(encoded)
        }
        return result
    }

    private static func classicAgreementStyleData() -> Data {
        // TextEdit 'styl' scrap: one StScrpRec style run beginning at character 0.
        // Layout is big-endian: style count, ScrpSTElement(start, height, ascent,
        // font, face+pad, size, RGBColor). A real style scrap makes the old
        // Carracho client feed the TEXT payload through its styled TextEdit path.
        var data = Data()
        data.append(contentsOf: [0x00, 0x01])                         // scrpNStyles
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])             // scrpStartChar
        data.append(contentsOf: [0x00, 0x0e])                         // scrpHeight
        data.append(contentsOf: [0x00, 0x0b])                         // scrpAscent
        data.append(contentsOf: [0x00, 0x00])                         // system font
        data.append(contentsOf: [0x00, 0x00])                         // normal face + alignment pad
        data.append(contentsOf: [0x00, 0x0c])                         // 12 pt
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // black RGB
        return data
    }

    private static func macRoman(_ value: String) -> Data {
        value.data(using: .macOSRoman, allowLossyConversion: true) ?? Data("?".utf8)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let a = [UInt8](lhs), b = [UInt8](rhs)
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}

private struct LegacyAuthenticatedSession {
    var account: ServerAccount
    var nickname: Data
    var sessionKey: Data
}

private struct LegacyLoginRegistration {
    var userID: UInt32
    var users: [LegacyUserListEntry]
    var legacyUserIDs: [UInt32]
    var existingSessions: [LegacyServerSession]
}

private final class LegacyServerSession {
    let fd: Int32
    let peerIP: String
    weak var runtime: LegacyServerRuntime?
    private let sendLock = NSLock()
    private let closeLock = NSLock()
    private let localOnly: Bool
    private var closed = false
    fileprivate var userID: UInt32?
    fileprivate var account: ServerAccount?
    fileprivate var nickname = Data()
    fileprivate var picture = Data()
    fileprivate var statusMessage = Data()
    fileprivate var sleeping = false
    fileprivate var loginAt = Date()
    fileprivate var lastActivityAt = Date()
    fileprivate var botGreetingSent = false
    fileprivate var clientOperatingSystem = Data()
    fileprivate var clientCPUArchitecture = Data()
    fileprivate var clientVersion = Data()
    fileprivate var clientBuild = Data()
    private var sessionKey: Data?
    private var modernSalt: Data?
    private var modernControlChannel: CarrachoAEADChannel?
    private var modernTransport = false

    init(fd: Int32, peerIP: String, runtime: LegacyServerRuntime) {
        self.fd = fd
        self.peerIP = peerIP
        self.runtime = runtime
        self.localOnly = false
    }

    init(localBotRuntime runtime: LegacyServerRuntime) {
        self.fd = -1
        self.peerIP = "127.0.0.1"
        self.runtime = runtime
        self.localOnly = true
        self.modernTransport = true
    }

    private func captureClientMetadata(from packet: LegacyPacket) {
        guard modernTransport else { return }
        func validated(_ type: UInt32) -> Data {
            guard let data = packet.firstField(type: type)?.value,
                  !data.isEmpty, data.count <= LegacyClientMetadataField.maximumLength,
                  !data.contains(0), !data.contains(10), !data.contains(13),
                  String(data: data, encoding: .utf8) != nil else { return Data() }
            return data
        }
        clientOperatingSystem = validated(LegacyClientMetadataField.operatingSystem)
        clientCPUArchitecture = validated(LegacyClientMetadataField.cpuArchitecture)
        clientVersion = validated(LegacyClientMetadataField.clientVersion)
        clientBuild = validated(LegacyClientMetadataField.clientBuild)
    }

    var userListEntry: LegacyUserListEntry? {
        guard let userID else { return nil }
        let flags: UInt16 = sleeping ? 0x0100 : 0
        return LegacyUserListEntry(nickname: nickname, flags: flags, userID: userID, picture: picture)
    }

    fileprivate var userUpdateSnapshot: (userID: UInt32, nickname: Data, picture: Data,
                                         statusMessage: Data, account: ServerAccount)? {
        guard let userID, let account else { return nil }
        return (userID, nickname, picture, statusMessage, account)
    }

    func touchActivity() { lastActivityAt = Date() }
    var supportsTaggedUTF8FileNames: Bool { modernTransport }
    var isLegacyTransport: Bool { !modernTransport }
    var isLocalOnly: Bool { localOnly }

    var transferAccess: LegacyTransferAccess? {
        // Synthetic local sessions must never be usable as a network transfer identity.
        guard !localOnly, let userID, let account, let sessionKey else { return nil }
        return LegacyTransferAccess(userID: userID, account: account, nickname: nickname,
                                    key: sessionKey, modernSalt: modernSalt, peerIP: peerIP,
                                    legacyTransport: !modernTransport)
    }

    func run() {
        defer {
            close()
            runtime?.sessionEnded(self)
        }
        do {
            let hello = try LegacySocket.readExactly(fd: fd, count: LegacyWire.clientHello().count)
            var helloCursor = LegacyByteCursor(hello)
            guard try helloCursor.readBytes(count: LegacyWire.magic.count) == LegacyWire.magic else {
                throw LegacyServerRuntimeError.protocolFailure("invalid client hello")
            }
            let clientVersion = try helloCursor.readUInt16BE()
            guard clientVersion == 1 || clientVersion == CarrachoModernCrypto.clientHelloVersion else {
                throw LegacyServerRuntimeError.protocolFailure("unsupported client hello version \(clientVersion)")
            }
            modernTransport = clientVersion == CarrachoModernCrypto.clientHelloVersion
            if !modernTransport, runtime?.allowsLegacyTransport() == false {
                throw LegacyServerRuntimeError.protocolFailure("legacy connections are disabled")
            }
            try LegacySocket.writeAll(fd: fd, data: LegacyWire.serverHello(version: modernTransport ? CarrachoModernCrypto.serverHelloVersion : 2))

            var generator = SystemRandomNumberGenerator()
            let challenge = Data((0..<12).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            let challengePacket = LegacyPacket(command: LegacyCommand.challenge, transactionID: 0,
                                               fields: [LegacyTLV(type: 1, value: challenge)])
            try send(packet: challengePacket, key: LegacyAuthentication.initialControlKey)

            let loginFrame = try LegacySocket.readControlFrame(fd: fd)
            let loginPacket = try LegacyControlCodec.decode(loginFrame, key: LegacyAuthentication.initialControlKey)
            guard loginPacket.command == LegacyCommand.login,
                  let loginField = loginPacket.firstField(type: 1),
                  let digestField = loginPacket.firstField(type: 2),
                  let nicknameField = loginPacket.firstField(type: 4) else {
                throw LegacyServerRuntimeError.protocolFailure("invalid login packet")
            }
            guard let runtime,
                  let authenticated = try runtime.authenticateLegacy(loginData: loginField.value,
                                                                     digest: digestField.value,
                                                                     nickname: nicknameField.value,
                                                                     picture: modernTransport ? nil : loginPacket.firstField(type: 5)?.value,
                                                                     challenge: challenge) else {
                runtime?.recordLoginFailure()
                try send(packet: LegacyServerRuntime.errorPacket(transactionID: loginPacket.transactionID, code: 100),
                         key: LegacyAuthentication.initialControlKey)
                return
            }

            captureClientMetadata(from: loginPacket)
            let registration = runtime.registerAuthenticated(self, authenticated: authenticated)
            var negotiatedSalt: Data?
            var serverPublicKey: Data?
            var handshakeAuthenticator: Data?
            var transportKey = authenticated.sessionKey
            if modernTransport {
                guard let clientPublicKey = loginPacket.firstField(type: 5)?.value,
                      clientPublicKey.count == CarrachoModernCrypto.ephemeralPublicKeyLength else {
                    throw LegacyServerRuntimeError.protocolFailure("modern login is missing the X25519 client public key")
                }
                let salt = CarrachoModernCrypto.randomBytes(count: CarrachoModernCrypto.sessionSaltLength)
                let serverEphemeral = CarrachoModernCrypto.makeEphemeralKeyPair()
                let authenticator = try CarrachoModernCrypto.handshakeAuthenticator(
                    sessionKey: authenticated.sessionKey, challenge: challenge, clientPublicKey: clientPublicKey,
                    serverPublicKey: serverEphemeral.publicKey, sessionSalt: salt)
                transportKey = try CarrachoModernCrypto.transportMaster(keyPair: serverEphemeral,
                    peerPublicKey: clientPublicKey, sessionKey: authenticated.sessionKey, sessionSalt: salt)
                negotiatedSalt = salt
                serverPublicKey = serverEphemeral.publicKey
                handshakeAuthenticator = authenticator
            }
            let success = try runtime.loginSuccessPacket(registration: registration, account: authenticated.account,
                modernSalt: negotiatedSalt, modernServerPublicKey: serverPublicKey,
                modernAuthenticator: handshakeAuthenticator)
            try send(packet: success, key: LegacyAuthentication.initialControlKey)
            sessionKey = transportKey
            modernSalt = negotiatedSalt
            if let negotiatedSalt {
                let keys = try CarrachoModernCrypto.controlKeys(sessionKey: transportKey, salt: negotiatedSalt, role: .server)
                modernControlChannel = try CarrachoAEADChannel(keys: keys, domain: "carracho/control/v1")
                runtime.notifyInitialUserSnapshots(self, sessions: registration.existingSessions + [self])
            }
            runtime.notifyOfflineMessagesIfNeeded(self)
            runtime.notifyUserArrived(self, to: registration.existingSessions)
            runtime.log("User \(String(data: nickname, encoding: .macOSRoman) ?? "?") logged in from \(peerIP)")

            while true {
                guard let key = sessionKey else { throw LegacyServerRuntimeError.protocolFailure("missing session key") }
                let packet: LegacyPacket
                if let modernControlChannel {
                    let frame = try LegacySocket.readAEADFrame(fd: fd, maximumCiphertextLength: LegacyPacket.headerSize + LegacyPacket.maximumClassicBodyLength)
                    let plaintext = try modernControlChannel.open(frame, maximumCiphertextLength: LegacyPacket.headerSize + LegacyPacket.maximumClassicBodyLength)
                    let decoded = try LegacyPacket.parsePlaintext(plaintext)
                    guard decoded.trailing.isEmpty else { throw LegacyServerRuntimeError.protocolFailure("authenticated control frame has trailing bytes") }
                    packet = decoded.packet
                } else {
                    let frame = try LegacySocket.readControlFrame(fd: fd)
                    packet = try LegacyControlCodec.decode(frame, key: key)
                }
                // The runtime distinguishes genuine user actions from passive/background polls.
                try runtime.handleAuthenticated(packet, from: self)
            }
        } catch {
            if !isClosed { runtime?.log("Session \(peerIP) ended: \(error.localizedDescription)") }
        }
    }

    func sendAuthenticated(_ packet: LegacyPacket) throws {
        if localOnly { return }
        guard let sessionKey else { throw LegacyServerRuntimeError.protocolFailure("session is not authenticated") }
        sendLock.lock(); defer { sendLock.unlock() }
        if isClosed { throw LegacyServerRuntimeError.stopped }
        let frame: Data
        if let modernControlChannel {
            frame = try modernControlChannel.seal(packet.plaintext())
        } else {
            frame = try LegacyControlCodec.encode(
                packet, key: sessionKey,
                classicServerSettingsLayout: packet.command == LegacyCommand.serverSettingsReply
            )
        }
        try LegacySocket.writeAll(fd: fd, data: frame)
    }

    private func send(packet: LegacyPacket, key: Data) throws {
        let frame = try LegacyControlCodec.encode(packet, key: key)
        sendLock.lock(); defer { sendLock.unlock() }
        if isClosed { throw LegacyServerRuntimeError.stopped }
        try LegacySocket.writeAll(fd: fd, data: frame)
    }

    var isClosed: Bool {
        closeLock.lock(); defer { closeLock.unlock() }
        return closed
    }

    func close() {
        closeLock.lock()
        if closed { closeLock.unlock(); return }
        closed = true
        closeLock.unlock()
        if !localOnly { LegacySocket.shutdownAndClose(fd) }
    }
}


private struct LegacyTransferAccess {
    let userID: UInt32
    let account: ServerAccount
    let nickname: Data
    let key: Data
    let modernSalt: Data?
    let peerIP: String
    let legacyTransport: Bool
}

private enum LegacyFileTransferDirection { case download, upload }

private struct LegacyServerTransferEntry {
    let relativePath: Data
    let url: URL
    let isFolder: Bool
    let size: UInt64
}

private final class LegacySocketTransferStream {
    private static let maximumFramePayload = 4 * 1024 * 1024

    enum Mode {
        case plain
        case blowfish(Data)
        case modern(CarrachoAEADChannel)
    }

    let fd: Int32
    private let mode: Mode
    private var plaintextBuffer = Data()

    init(fd: Int32, mode: Mode) {
        self.fd = fd
        self.mode = mode
    }

    func sendPayload(_ payload: Data) throws {
        switch mode {
        case .plain:
            try LegacySocket.writeAll(fd: fd, data: payload)
        case let .blowfish(key):
            try LegacySocket.writeAll(fd: fd, data: LegacyCryptoFraming.encodeTransferBlock(payload: payload, key: key))
        case let .modern(channel):
            if payload.isEmpty { return }
            var offset = 0
            while offset < payload.count {
                let count = min(Self.maximumFramePayload, payload.count - offset)
                let chunk = Data(payload[offset ..< offset + count])
                try LegacySocket.writeAll(fd: fd, data: channel.seal(chunk))
                offset += count
            }
        }
    }

    func readPayload(_ count: Int) throws -> Data {
        guard count >= 0 else { throw LegacyProtocolError.invalidLength("negative transfer payload length") }
        if count == 0 { return Data() }
        if case .plain = mode { return try LegacySocket.readExactly(fd: fd, count: count) }
        while plaintextBuffer.count < count { plaintextBuffer.append(try readFrame()) }
        let value = Data(plaintextBuffer.prefix(count))
        plaintextBuffer.removeFirst(count)
        return value
    }

    func readUInt8() throws -> UInt8 { try readPayload(1).first! }
    func readUInt16() throws -> UInt16 { var c = LegacyByteCursor(try readPayload(2)); return try c.readUInt16BE() }
    func readUInt32() throws -> UInt32 { var c = LegacyByteCursor(try readPayload(4)); return try c.readUInt32BE() }
    func readUInt64() throws -> UInt64 { var c = LegacyByteCursor(try readPayload(8)); return try c.readUInt64BE() }
    func readString16(maximum: Int = LegacyPath.maximumWireLength) throws -> Data {
        let length = Int(try readUInt16())
        guard length <= maximum else { throw LegacyProtocolError.invalidLength("transfer String16 exceeds limit") }
        return try readPayload(length)
    }

    private func readFrame() throws -> Data {
        switch mode {
        case .plain:
            throw LegacyServerRuntimeError.protocolFailure("plain transfer stream has no framed read")
        case let .blowfish(key):
            let header = try LegacySocket.readExactly(fd: fd, count: 9)
            var cursor = LegacyByteCursor(header)
            let encryptedLength = Int(try cursor.readUInt32BE())
            let reserved = try cursor.readUInt32BE()
            let padding = Int(try cursor.readUInt8())
            guard reserved == 0, padding <= 7, encryptedLength >= 0,
                  encryptedLength.isMultiple(of: 8), encryptedLength <= Self.maximumFramePayload else {
                throw LegacyServerRuntimeError.protocolFailure("invalid encrypted transfer-frame header")
            }
            var frame = header
            frame.append(try LegacySocket.readExactly(fd: fd, count: encryptedLength))
            return try LegacyCryptoFraming.decodeTransferBlock(frame, key: key)
        case let .modern(channel):
            let frame = try LegacySocket.readAEADFrame(fd: fd, maximumCiphertextLength: Self.maximumFramePayload)
            return try channel.open(frame, maximumCiphertextLength: Self.maximumFramePayload)
        }
    }
}

extension LegacyServerRuntime {
    private static let folderType: UInt32 = 0x464c4452 // FLDR
    private static let symbolicLinkType: UInt32 = 0x53594D4C // SYML
    private static let folderCreator: UInt32 = 0x43617253 // CarS
    private static let ioChunk = 256 * 1024
    private static let macEpochOffset: TimeInterval = 2_082_844_800

    fileprivate func transferAcceptLoop(fd: Int32) {
        while true {
            stateLock.lock(); let shouldRun = running && transferListenerFD == fd; stateLock.unlock()
            guard shouldRun else { return }
            do {
                let accepted = try LegacySocket.accept(fd: fd)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { LegacySocket.shutdownAndClose(accepted.fd); return }
                    defer { LegacySocket.shutdownAndClose(accepted.fd) }
                    do { try self.handleTransferConnection(fd: accepted.fd, peerIP: accepted.peerIP) }
                    catch {
                        if let runtimeError = error as? LegacyServerRuntimeError, case .stopped = runtimeError {
                            // Normal peer close (for example after a reported upload conflict).
                        } else if !(error is CancellationError) {
                            self.log("Transfer from \(accepted.peerIP) ended: \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                stateLock.lock(); let stillRunning = running; stateLock.unlock()
                if stillRunning { log("Transfer accept failed: \(error.localizedDescription)") }
                return
            }
        }
    }

    private func handleTransferConnection(fd: Int32, peerIP: String) throws {
        let hello = try LegacySocket.readExactly(fd: fd, count: 10)
        var cursor = LegacyByteCursor(hello)
        let version = try cursor.readUInt32BE()
        let operation = try cursor.readUInt16BE()
        let userID = try cursor.readUInt32BE()
        guard let access = transferAccess(userID: userID, peerIP: peerIP) else {
            throw LegacyServerRuntimeError.protocolFailure("transfer user/IP does not match an authenticated control session")
        }

        let stream: LegacySocketTransferStream
        if let sessionSalt = access.modernSalt {
            guard version == CarrachoModernCrypto.transferHelloVersion else {
                throw LegacyServerRuntimeError.protocolFailure("modern session attempted a legacy transfer downgrade")
            }
            let transferNonce = try LegacySocket.readExactly(fd: fd, count: CarrachoModernCrypto.transferNonceLength)
            let keys = try CarrachoModernCrypto.transferKeys(sessionKey: access.key, sessionSalt: sessionSalt,
                                                              transferNonce: transferNonce, operation: operation,
                                                              role: .server)
            let channel = try CarrachoAEADChannel(keys: keys, domain: "carracho/transfer/v1")
            stream = LegacySocketTransferStream(fd: fd, mode: .modern(channel))
        } else {
            guard version == 0x01000000 else {
                throw LegacyServerRuntimeError.protocolFailure("legacy session used an unsupported transfer hello version")
            }
            let encrypted = operation == LegacyTransferOperation.encryptedDownload ||
                operation == LegacyTransferOperation.encryptedUpload
            stream = LegacySocketTransferStream(fd: fd, mode: encrypted ? .blowfish(access.key) : .plain)
        }

        switch operation {
        case LegacyTransferOperation.articleReceiver:
            try serveArticlePost(stream: stream, access: access)
        case LegacyTransferOperation.bannerUpload:
            try serveBannerUpload(stream: stream, access: access)
        case LegacyTransferOperation.fileSearch:
            try serveFileSearch(stream: stream, access: access)
        case LegacyTransferOperation.encryptedDownload:
            guard let transferID = beginFileTransfer(access: access, direction: .download, socketFD: fd) else {
                throw LegacyServerRuntimeError.protocolFailure("download permission/transfer limit denied")
            }
            var succeeded = false
            defer { endFileTransfer(transferID: transferID, access: access, direction: .download, succeeded: succeeded) }
            try serveDownload(stream: stream, access: access, transferID: transferID)
            succeeded = true
        case LegacyTransferOperation.encryptedUpload:
            guard let transferID = beginFileTransfer(access: access, direction: .upload, socketFD: fd) else {
                throw LegacyServerRuntimeError.protocolFailure("upload permission/transfer limit denied")
            }
            var succeeded = false
            defer { endFileTransfer(transferID: transferID, access: access, direction: .upload, succeeded: succeeded) }
            try serveUpload(stream: stream, access: access, transferID: transferID)
            succeeded = true
        case LegacyTransferOperation.newsIndex:
            try serveNewsIndex(stream: stream, access: access)
        case LegacyTransferOperation.bannerDownload:
            try serveBannerDownload(stream: stream, access: access)
        case LegacyTransferOperation.mediaUpload:
            guard access.modernSalt != nil else { throw LegacyServerRuntimeError.protocolFailure("media attachments require modern transport") }
            try serveMediaUpload(stream: stream, access: access)
        case LegacyTransferOperation.mediaDownload:
            guard access.modernSalt != nil else { throw LegacyServerRuntimeError.protocolFailure("media attachments require modern transport") }
            try serveMediaDownload(stream: stream, access: access)
        case LegacyTransferOperation.mediaDelete:
            guard access.modernSalt != nil else { throw LegacyServerRuntimeError.protocolFailure("media deletion requires modern transport") }
            try serveMediaDelete(stream: stream, access: access)
        default:
            throw LegacyServerRuntimeError.protocolFailure("unsupported transfer operation \(operation)")
        }
    }

    private static let maximumBannerBytes = 8 * 1024 * 1024
    private static let oversizedBuiltInBannerSHA256 = Data([
        0x79, 0x69, 0xda, 0x2a, 0x54, 0x41, 0xf3, 0x79,
        0x02, 0xa4, 0xe1, 0x5c, 0xe3, 0xff, 0x86, 0x59,
        0x05, 0x31, 0x45, 0x81, 0x7a, 0x40, 0x19, 0x30,
        0xe1, 0xdb, 0x32, 0x6e, 0xe6, 0x28, 0x63, 0x0d,
    ])

    private static func classicCompatibleBanner(_ banner: Data) -> Data {
        guard banner.count == 794_991,
              Data(SHA256.hash(data: banner)) == oversizedBuiltInBannerSHA256,
              let classic = CarrachoDefaultServerBanner.pngData(),
              !classic.isEmpty else {
            return banner
        }
        return classic
    }

    private func broadcastAuthenticated(_ packet: LegacyPacket) {
        stateLock.lock(); let recipients = Array(authenticatedByUserID.values); stateLock.unlock()
        recipients.forEach { try? $0.sendAuthenticated(packet) }
    }

    func notifyBannerChanged() {
        broadcastAuthenticated(LegacyPacket(command: LegacyCommand.bannerChanged, transactionID: 0, fields: []))
    }

    private func serveBannerUpload(stream: LegacySocketTransferStream, access: LegacyTransferAccess) throws {
        guard access.account.permissions.contains(.editServerInformation) else {
            if let session = authenticatedSession(userID: access.userID) {
                try? session.sendAuthenticated(Self.errorPacket(transactionID: 0, code: 2))
            }
            throw LegacyServerRuntimeError.protocolFailure("banner-upload permission denied")
        }
        var lengthCursor = LegacyByteCursor(try stream.readPayload(4))
        let bannerLength = Int(try lengthCursor.readUInt32BE())
        guard bannerLength <= Self.maximumBannerBytes else {
            throw LegacyServerRuntimeError.protocolFailure("banner image exceeds 8 MiB")
        }
        let banner = try stream.readPayload(bannerLength)
        let urlLength = Int(try stream.readPayload(1).first!)
        let urlData = try stream.readPayload(urlLength)
        guard let url = String(data: urlData, encoding: .macOSRoman) else {
            throw LegacyServerRuntimeError.protocolFailure("banner URL is not valid MacRoman")
        }
        try backend.updateServerState { state in
            state.identity.bannerData = banner.isEmpty ? nil : banner
            state.identity.bannerURL = url
        }
        notifyBannerChanged()
        log("Banner updated by user \(access.userID): \(banner.count) byte(s), URL \(url.isEmpty ? "empty" : "set")")
    }

    private func serveBannerDownload(stream: LegacySocketTransferStream, access: LegacyTransferAccess) throws {
        let identity = backend.snapshot().identity
        let storedBanner = identity.bannerData ?? Data()
        let banner = access.modernSalt == nil ? Self.classicCompatibleBanner(storedBanner) : storedBanner
        guard banner.count <= Self.maximumBannerBytes, banner.count <= Int(UInt32.max) else {
            throw LegacyServerRuntimeError.protocolFailure("stored banner image exceeds transfer limit")
        }
        guard let urlData = identity.bannerURL.data(using: .macOSRoman), urlData.count <= 255 else {
            throw LegacyServerRuntimeError.protocolFailure("stored banner URL exceeds Classic transfer limit")
        }
        var payload = LegacyWire.uint32BE(UInt32(banner.count))
        payload.append(banner)
        payload.append(UInt8(urlData.count))
        payload.append(urlData)
        try stream.sendPayload(payload)
        log("Banner served to user \(access.userID): \(banner.count) byte(s)")
    }

    private func serveMediaUpload(stream: LegacySocketTransferStream, access: LegacyTransferAccess) throws {
        let version = try stream.readPayload(1).first ?? 0
        guard version == 1 else { throw LegacyServerRuntimeError.protocolFailure("unsupported media-upload version") }
        var nameCursor = LegacyByteCursor(try stream.readPayload(2))
        let nameLength = Int(try nameCursor.readUInt16BE())
        guard nameLength > 0, nameLength <= 1024 else { throw LegacyServerRuntimeError.protocolFailure("invalid media filename length") }
        let nameData = try stream.readPayload(nameLength)
        guard let filename = String(data: nameData, encoding: .utf8) else { throw LegacyServerRuntimeError.protocolFailure("media filename is not UTF-8") }
        var lengthCursor = LegacyByteCursor(try stream.readPayload(4))
        let length = Int(try lengthCursor.readUInt32BE())
        guard length > 0, length <= LegacyMediaTransfer.maximumImageBytes else { throw LegacyServerRuntimeError.protocolFailure("media image exceeds 4 MiB") }
        let data = try stream.readPayload(length)
        let object = try mediaStore.storePending(ownerAccountID: access.account.id, filename: filename, data: data)
        let id = Data(object.id.uuidString.lowercased().utf8)
        try stream.sendPayload(try LegacyWire.string16(id))
        try? mediaStore.cleanup()
        log("Media image uploaded by user \(access.userID): \(object.id.uuidString), \(length) byte(s)")
    }

    private func broadcastMediaDeleted(_ id: UUID) {
        let packet = LegacyPacket(command: LegacyCommand.mediaDeleted, transactionID: 0, fields: [
            LegacyTLV(type: 1, value: Data(id.uuidString.lowercased().utf8)),
        ])
        stateLock.lock()
        let recipients = authenticatedByUserID.values.filter { !$0.isLegacyTransport }
        stateLock.unlock()
        recipients.forEach { try? $0.sendAuthenticated(packet) }
    }

    private func serveMediaDelete(stream: LegacySocketTransferStream, access: LegacyTransferAccess) throws {
        let version = try stream.readPayload(1).first ?? 0
        guard version == 1 else { throw LegacyServerRuntimeError.protocolFailure("unsupported media-delete version") }
        var idCursor = LegacyByteCursor(try stream.readPayload(2))
        let idLength = Int(try idCursor.readUInt16BE())
        guard idLength == 36,
              let idText = String(data: try stream.readPayload(idLength), encoding: .ascii),
              let id = UUID(uuidString: idText) else {
            try stream.sendPayload(Data([0])); return
        }
        do {
            try mediaStore.deleteOwned(id: id, by: access.account.id)
        } catch ServerMediaStoreError.notFound {
            try stream.sendPayload(Data([0])); return
        } catch ServerMediaStoreError.ownership {
            try stream.sendPayload(Data([0])); return
        }
        try stream.sendPayload(Data([1]))
        broadcastMediaDeleted(id)
        log("Media image deleted by user \(access.userID): \(id.uuidString.lowercased())")
    }

    private func serveMediaDownload(stream: LegacySocketTransferStream, access: LegacyTransferAccess) throws {
        let header = try stream.readPayload(2)
        guard header.count == 2, header[0] == 1 else { throw LegacyServerRuntimeError.protocolFailure("unsupported media-download version") }
        let kind = header[1]
        var scopeCursor = LegacyByteCursor(try stream.readPayload(2))
        let scopeLength = Int(try scopeCursor.readUInt16BE())
        guard scopeLength <= LegacyPath.maximumWireLength else { throw LegacyServerRuntimeError.protocolFailure("media scope too large") }
        let scopeWire = try stream.readPayload(scopeLength)
        var idCursor = LegacyByteCursor(try stream.readPayload(2))
        let idLength = Int(try idCursor.readUInt16BE())
        guard idLength == 36,
              let idString = String(data: try stream.readPayload(idLength), encoding: .ascii),
              let id = UUID(uuidString: idString) else {
            try stream.sendPayload(Data([0])); return
        }
        var allowed = try mediaStore.isOwned(id: id, by: access.account.id)
        if !allowed, kind == ServerMediaReferenceKind.chat.rawValue, scopeWire.count == 4 {
            var c = LegacyByteCursor(scopeWire); let channelID = try c.readUInt32BE()
            stateLock.lock()
            let member = channels[channelID]?.members[access.userID] != nil
            stateLock.unlock()
            if member {
                allowed = try mediaStore.hasReference(id: id, kind: .chat, scope: String(channelID))
            }
        } else if !allowed, kind == ServerMediaReferenceKind.news.rawValue,
                  let group = configuredNewsgroup(named: scopeWire), canRead(group: group, account: access.account) {
            allowed = try mediaStore.hasReference(id: id, kind: .news, scope: group.id.uuidString.lowercased())
        } else if !allowed, kind == ServerMediaReferenceKind.privateMessage.rawValue, scopeWire.isEmpty {
            allowed = try mediaStore.hasReference(
                id: id,
                kind: .privateMessage,
                scope: access.account.id.uuidString.lowercased()
            )
        }
        guard allowed else { try stream.sendPayload(Data([0])); return }
        let object = try mediaStore.load(id: id)
        let mime = Data(object.mimeType.utf8), filename = Data(object.filename.utf8)
        guard mime.count <= Int(UInt16.max), filename.count <= Int(UInt16.max), object.data.count <= Int(UInt32.max) else {
            throw LegacyServerRuntimeError.protocolFailure("stored media metadata exceeds transfer limits")
        }
        var payload = Data([1])
        payload.append(try LegacyWire.string16(mime))
        payload.append(try LegacyWire.string16(filename))
        payload.append(LegacyWire.uint16BE(UInt16(object.width)))
        payload.append(LegacyWire.uint16BE(UInt16(object.height)))
        payload.append(LegacyWire.uint32BE(UInt32(object.data.count)))
        payload.append(object.data)
        try stream.sendPayload(payload)
    }

    private func validateAndBindMediaReferences(in wire: Data, ownerAccountID: UUID,
                                                maximum: Int, kind: ServerMediaReferenceKind,
                                                scope: String, messageID: String,
                                                expiresAt: Date?) throws {
        let ids = LegacyMediaReference.references(inWire: wire).map(\.id)
        guard ids.count <= maximum else { throw LegacyServerRuntimeError.protocolFailure("too many media attachments") }
        for id in ids where try !mediaStore.isOwned(id: id, by: ownerAccountID) {
            throw LegacyServerRuntimeError.protocolFailure("media attachment is not owned by sender")
        }
        try mediaStore.bind(ids: ids, ownerAccountID: ownerAccountID, kind: kind, scope: scope,
                            messageID: messageID, expiresAt: expiresAt)
    }

    private func serveFileSearch(stream: LegacySocketTransferStream, access: LegacyTransferAccess) throws {
        guard access.account.permissions.contains(.searchFiles),
              access.account.personalDirectory != .rootDirectory else {
            throw LegacyServerRuntimeError.protocolFailure("file-search permission denied")
        }

        var queryWire = try stream.readPayload(2)
        var countCursor = LegacyByteCursor(queryWire)
        let clauseCount = Int(try countCursor.readUInt16BE())
        guard clauseCount > 0, clauseCount <= 64 else {
            throw LegacyServerRuntimeError.protocolFailure("invalid file-search clause count")
        }
        for _ in 0..<clauseCount {
            let header = try stream.readPayload(7)
            var cursor = LegacyByteCursor(header)
            _ = try cursor.readUInt8()
            _ = try cursor.readUInt8()
            _ = try cursor.readUInt8()
            let length = Int(try cursor.readUInt32BE())
            guard length <= LegacyFileSearchQuery.maximumTextLength else {
                throw LegacyServerRuntimeError.protocolFailure("file-search clause exceeds classic limit")
            }
            queryWire.append(header)
            queryWire.append(try stream.readPayload(length))
        }
        let query = try LegacyFileSearchQuery.decode(queryWire)

        // ReceiveQuery() in Server 1.0b13 writes a UInt32 zero before search results begin.
        try stream.sendPayload(LegacyWire.uint32BE(0))
        let results = try fileSearchResults(containing: query.text, account: access.account, legacyTransport: access.legacyTransport)
        if access.legacyTransport {
            // Preserve the historical one-result-per-frame shape for Classic clients.
            for result in results {
                try stream.sendPayload(try LegacyFileSearchTransfer.resultFrame(result))
            }
        } else {
            // Modern AEAD transfer framing is comparatively expensive per payload. The classic
            // search record format already carries a count, so batch records without changing
            // the logical protocol seen by the client.
            let batchSize = 256
            var start = results.startIndex
            while start < results.endIndex {
                let end = min(start + batchSize, results.endIndex)
                try stream.sendPayload(try LegacyFileSearchTransfer.resultFrame(results[start..<end]))
                start = end
            }
        }
        try stream.sendPayload(LegacyFileSearchTransfer.doneFrame)
        log("File search for user \(access.userID): \(LegacyPath.displayString(query.text)) — \(results.count) result(s)")
    }

    private func fileSearchResults(containing queryData: Data, account: ServerAccount, legacyTransport: Bool = false) throws -> [LegacyFileSearchResult] {
        let searchRoot = try accountFilesRootURL(account, legacyTransport: legacyTransport)
        let hasCustomGroupRoot = accountFilesRootGroup(account)?.filesRootPath.isEmpty == false
        let scopedRoot = hasCustomGroupRoot || usesLegacyFilesRoot(legacyTransport: legacyTransport)
        // The disposable index is keyed in the normal global server-root coordinates. Any
        // group-specific or Legacy root therefore walks only its own filesystem scope.
        if !scopedRoot, let fileSearchIndex = currentFileSearchIndex() {
            do {
                return try fileSearchIndex.search(queryData).map { entry in
                    LegacyFileSearchResult(name: entry.name,
                                           creator: entry.isFolder ? Self.folderCreator : 0,
                                           fileType: entry.isFolder ? Self.folderType : 0,
                                           size: entry.size,
                                           timestamp: entry.timestamp,
                                           path: entry.path)
                }
            } catch {
                log("Indexed file search failed; using filesystem fallback: \(error.localizedDescription)")
            }
        }
        guard let query = String(data: queryData, encoding: .macOSRoman), !query.isEmpty else {
            throw LegacyServerRuntimeError.protocolFailure("file-search query is not valid MacRoman")
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey]
        var results: [LegacyFileSearchResult] = []
        results.reserveCapacity(64)
        let exclusionFilter = ServerFileSearchIndex(url: fileSearchIndexURL,
                                                     exclusionPatterns: backend.snapshot().runtime.searchIndexExclusions)
        var visitedDirectories = Set<String>()
        if let identity = ServerFileSearchIndex.directoryIdentityKey(searchRoot) { visitedDirectories.insert(identity) }

        func walk(_ directory: URL, legacyParent: Data) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: Array(keys),
                                                                       options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            for child in children {
                guard !Self.isTransferStagingName(child.lastPathComponent),
                      !exclusionFilter.excludesName(child.lastPathComponent) else { continue }
                let originalValues = try child.resourceValues(forKeys: keys)
                let effectiveChild = originalValues.isSymbolicLink == true
                    ? child.resolvingSymlinksInPath().standardizedFileURL
                    : child
                let values = try effectiveChild.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                                          .fileSizeKey, .contentModificationDateKey])
                guard values.isDirectory == true || values.isRegularFile == true,
                      let name = child.lastPathComponent.data(using: .macOSRoman),
                      !name.isEmpty, name.count <= LegacyFileSearchResult.maximumNameLength else { continue }
                let path: Data
                do { path = try LegacyPath.child(parent: legacyParent, name: name) }
                catch { continue }
                guard path.count <= LegacyPath.maximumWireLength else { continue }

                if child.lastPathComponent.localizedCaseInsensitiveContains(query) {
                    let isFolder = values.isDirectory == true
                    let rawSize = UInt64(max(values.fileSize ?? 0, 0))
                    let timestamp: UInt32
                    if let date = values.contentModificationDate {
                        let classic = max(0, date.timeIntervalSince1970 + Self.macEpochOffset)
                        timestamp = UInt32(min(classic, TimeInterval(UInt32.max)))
                    } else { timestamp = 0 }
                    results.append(LegacyFileSearchResult(
                        name: name,
                        creator: isFolder ? Self.folderCreator : 0,
                        fileType: isFolder ? Self.folderType : 0,
                        size: isFolder ? 0 : UInt32(min(rawSize, UInt64(UInt32.max))),
                        timestamp: timestamp,
                        path: path
                    ))
                    guard results.count <= 100_000 else {
                        throw LegacyServerRuntimeError.protocolFailure("file-search result limit exceeded")
                    }
                }
                if values.isDirectory == true {
                    let flags = metadataStore(legacyTransport: legacyTransport)?.metadata(for: try storageMetadataPath(path, account: account))?.flags ?? 0
                    if (flags & LegacyDirectoryFlags.dropBox) == 0 {
                        if let identity = ServerFileSearchIndex.directoryIdentityKey(effectiveChild),
                           !visitedDirectories.insert(identity).inserted {
                            continue
                        }
                        try walk(effectiveChild, legacyParent: path)
                    }
                }
            }
        }

        try walk(searchRoot, legacyParent: Data())
        return results
    }

    private func transferAccess(userID: UInt32, peerIP: String) -> LegacyTransferAccess? {
        stateLock.lock()
        guard let session = authenticatedByUserID[userID],
              let access = session.transferAccess,
              access.peerIP == peerIP else { stateLock.unlock(); return nil }
        stateLock.unlock()
        markUserActive(session)
        return access
    }

    private func beginFileTransfer(access: LegacyTransferAccess, direction: LegacyFileTransferDirection, socketFD: Int32) -> UInt32? {
        let allowed: Bool
        switch direction {
        case .download: allowed = access.account.permissions.contains(.download)
        // Classic semantics: "upload anywhere" widens where an uploader may write, but
        // never replaces the base "upload" permission itself.
        case .upload: allowed = access.account.permissions.contains(.upload)
        }
        guard allowed else { return nil }
        let limits = backend.snapshot().advanced
        stateLock.lock()
        let userCount = activeFileTransfersByUser[access.userID, default: 0]
        guard activeFileTransfers < Int(limits.maxSimultaneousFileTransfers),
              userCount < Int(limits.maxFileTransfersPerUser) else {
            stateLock.unlock(); return nil
        }
        while nextTransferID == 0 || activeTransferDescriptors[nextTransferID] != nil { nextTransferID &+= 1 }
        let transferID = nextTransferID
        nextTransferID &+= 1
        if nextTransferID == 0 { nextTransferID = 1 }
        let kind: UInt8 = direction == .download ? LegacyTransferKind.download : LegacyTransferKind.upload
        if direction == .download,
           !activeTransferDescriptors.values.contains(where: { $0.kind == LegacyTransferKind.download }) {
            downloadTrafficWindowStartUptime = 0
            downloadTrafficWindowBytes = 0
            downloadTrafficBytesPerSecond = 0
            downloadTrafficLastActivityUptime = 0
        }
        var descriptor = ActiveTransferDescriptor(transferID: transferID, kind: kind, userID: access.userID, socketFD: socketFD)
        let now = ProcessInfo.processInfo.systemUptime
        descriptor.rateWindowStartUptime = now
        activeTransferDescriptors[transferID] = descriptor
        activeFileTransfers += 1
        activeFileTransfersByUser[access.userID] = userCount + 1
        if direction == .download {
            downloadBandwidthGeneration &+= 1
            if downloadBandwidthGeneration == 0 { downloadBandwidthGeneration = 1 }
        }
        stateLock.unlock()
        do {
            try backend.mutateStatistics { stats in
                switch direction {
                case .download: stats.downloadsInProgress &+= 1
                case .upload: stats.uploadsInProgress &+= 1
                }
            }
        } catch { log("Could not persist transfer-start statistics: \(error.localizedDescription)") }
        emitStatus()
        return transferID
    }

    private func configureTransfer(_ transferID: UInt32, path: Data? = nil, totalBytes: UInt64? = nil,
                                   isDirectory: Bool? = nil) {
        stateLock.lock()
        if var descriptor = activeTransferDescriptors[transferID] {
            if let path { descriptor.path = path }
            if let totalBytes { descriptor.totalBytes = totalBytes }
            if let isDirectory { descriptor.isDirectory = isDirectory }
            activeTransferDescriptors[transferID] = descriptor
        }
        stateLock.unlock()
    }

    private func addTransferProgress(_ transferID: UInt32, bytes: UInt64) {
        guard bytes > 0 else { return }
        stateLock.lock()
        if var descriptor = activeTransferDescriptors[transferID] {
            let (logical, logicalOverflow) = descriptor.bytesTransferred.addingReportingOverflow(bytes)
            let (wire, wireOverflow) = descriptor.wireBytesTransferred.addingReportingOverflow(bytes)
            descriptor.bytesTransferred = logicalOverflow ? UInt64.max : logical
            descriptor.wireBytesTransferred = wireOverflow ? UInt64.max : wire
            let now = ProcessInfo.processInfo.systemUptime
            if descriptor.rateWindowStartUptime == 0 { descriptor.rateWindowStartUptime = now }
            let (windowBytes, windowOverflow) = descriptor.rateWindowBytes.addingReportingOverflow(bytes)
            descriptor.rateWindowBytes = windowOverflow ? UInt64.max : windowBytes
            descriptor.lastProgressUptime = now
            let elapsed = now - descriptor.rateWindowStartUptime
            if elapsed >= 0.5 {
                descriptor.bytesPerSecond = UInt64(min(Double(UInt64.max), Double(descriptor.rateWindowBytes) / elapsed))
                descriptor.rateWindowBytes = 0
                descriptor.rateWindowStartUptime = now
            }
            activeTransferDescriptors[transferID] = descriptor
            if descriptor.kind == LegacyTransferKind.download {
                recordDownloadTrafficLocked(bytes: bytes, now: now)
            }
        }
        stateLock.unlock()
    }

    private func setDownloadBandwidthLimit(_ bytesPerSecond: UInt64) {
        stateLock.lock()
        downloadBandwidthLimitBytesPerSecond = bytesPerSecond
        downloadBandwidthGeneration &+= 1
        if downloadBandwidthGeneration == 0 { downloadBandwidthGeneration = 1 }
        stateLock.unlock()
    }

    /// Returns a small chunk size when shaping is enabled so the limiter produces a
    /// steady stream instead of multi-hundred-kilobyte bursts. Roughly eight sends
    /// per second are targeted for each downloader, bounded for syscall efficiency.
    private func pacedDownloadChunkSize(maximum: Int) -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        guard downloadBandwidthLimitBytesPerSecond > 0 else { return maximum }
        let downloadCount = max(1, activeTransferDescriptors.values.filter { $0.kind == LegacyTransferKind.download && !$0.paused && !$0.aborting }.count)
        let perTransferRate = downloadBandwidthLimitBytesPerSecond / UInt64(downloadCount)
        let target = Int(clamping: max(UInt64(4 * 1024), min(UInt64(64 * 1024), perTransferRate / 8)))
        return min(maximum, target)
    }

    /// Paces every active server download at an equal share of one global aggregate cap.
    /// The cap belongs to the server runtime and is intentionally independent of the
    /// administrator session that changed it. A generation counter makes slider changes and downloader joins/leaves take
    /// effect within 100 ms instead of leaving a transfer asleep on an old limit.
    private func throttleDownload(_ transferID: UInt32, bytes: Int) {
        guard bytes > 0 else { return }
        while true {
            let targetUptime: TimeInterval
            let generation: UInt64
            stateLock.lock()
            guard downloadBandwidthLimitBytesPerSecond > 0,
                  var descriptor = activeTransferDescriptors[transferID],
                  descriptor.kind == LegacyTransferKind.download,
                  !descriptor.paused, !descriptor.aborting else {
                stateLock.unlock()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            generation = downloadBandwidthGeneration
            if descriptor.downloadPacingGeneration != generation {
                descriptor.downloadPacingGeneration = generation
                descriptor.nextDownloadSendUptime = now
            }
            let downloadCount = max(1, activeTransferDescriptors.values.filter { $0.kind == LegacyTransferKind.download && !$0.paused && !$0.aborting }.count)
            let perTransferRate = max(1.0, Double(downloadBandwidthLimitBytesPerSecond) / Double(downloadCount))
            let base = max(now, descriptor.nextDownloadSendUptime)
            targetUptime = base + Double(bytes) / perTransferRate
            descriptor.nextDownloadSendUptime = targetUptime
            activeTransferDescriptors[transferID] = descriptor
            stateLock.unlock()

            while true {
                let remaining = targetUptime - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { return }
                Thread.sleep(forTimeInterval: min(0.1, remaining))
                stateLock.lock()
                let changed = downloadBandwidthLimitBytesPerSecond == 0 || downloadBandwidthGeneration != generation
                stateLock.unlock()
                if changed { break }
            }
        }
    }

    private func recordDownloadTrafficLocked(bytes: UInt64, now: TimeInterval) {
        if downloadTrafficWindowStartUptime == 0 { downloadTrafficWindowStartUptime = now }
        let (sum, overflow) = downloadTrafficWindowBytes.addingReportingOverflow(bytes)
        downloadTrafficWindowBytes = overflow ? UInt64.max : sum
        downloadTrafficLastActivityUptime = now
        let elapsed = now - downloadTrafficWindowStartUptime
        if elapsed >= 0.5 {
            downloadTrafficBytesPerSecond = UInt64(min(Double(UInt64.max), Double(downloadTrafficWindowBytes) / elapsed))
            downloadTrafficWindowBytes = 0
            downloadTrafficWindowStartUptime = now
        }
    }

    private func currentDownloadTrafficRateLocked(now: TimeInterval) -> UInt64 {
        let hasDownloads = activeTransferDescriptors.values.contains { $0.kind == LegacyTransferKind.download }
        guard hasDownloads, downloadTrafficLastActivityUptime > 0,
              now - downloadTrafficLastActivityUptime <= 1.5 else { return 0 }
        let elapsed = now - downloadTrafficWindowStartUptime
        if elapsed >= 0.15, downloadTrafficWindowBytes > 0 {
            let partial = UInt64(min(Double(UInt64.max), Double(downloadTrafficWindowBytes) / elapsed))
            if downloadTrafficBytesPerSecond == 0 { return partial }
            return (downloadTrafficBytesPerSecond / 2) + (partial / 2)
        }
        return downloadTrafficBytesPerSecond
    }

    private func currentTransferRate(_ descriptor: ActiveTransferDescriptor, now: TimeInterval) -> UInt64 {
        guard !descriptor.paused, !descriptor.aborting,
              descriptor.lastProgressUptime > 0,
              now - descriptor.lastProgressUptime <= 1.5 else { return 0 }
        let elapsed = now - descriptor.rateWindowStartUptime
        if elapsed >= 0.15, descriptor.rateWindowBytes > 0 {
            let partial = UInt64(min(Double(UInt64.max), Double(descriptor.rateWindowBytes) / elapsed))
            if descriptor.bytesPerSecond == 0 { return partial }
            return (descriptor.bytesPerSecond / 2) + (partial / 2)
        }
        return descriptor.bytesPerSecond
    }

    private func addTransferResumeProgress(_ transferID: UInt32, bytes: UInt64) {
        guard bytes > 0 else { return }
        stateLock.lock()
        if var descriptor = activeTransferDescriptors[transferID] {
            let (sum, overflow) = descriptor.bytesTransferred.addingReportingOverflow(bytes)
            descriptor.bytesTransferred = overflow ? UInt64.max : sum
            activeTransferDescriptors[transferID] = descriptor
        }
        stateLock.unlock()
    }

    private func awaitTransferReady(_ transferID: UInt32) throws {
        while true {
            stateLock.lock()
            guard let descriptor = activeTransferDescriptors[transferID] else {
                stateLock.unlock()
                throw CancellationError()
            }
            let paused = descriptor.paused
            let aborting = descriptor.aborting
            stateLock.unlock()
            if aborting { throw CancellationError() }
            if !paused { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func applyTransferControl(_ request: LegacyTransferControlRequest) throws {
        var socketToInterrupt: Int32?
        stateLock.lock()
        guard var descriptor = activeTransferDescriptors[request.transferID] else {
            stateLock.unlock()
            throw LegacyProtocolError.invalidRecord("transfer no longer exists")
        }
        switch request.action {
        case .pause:
            guard !descriptor.aborting else {
                stateLock.unlock()
                throw LegacyProtocolError.invalidRecord("transfer is aborting")
            }
            descriptor.paused = true
            downloadBandwidthGeneration &+= 1
            if downloadBandwidthGeneration == 0 { downloadBandwidthGeneration = 1 }
        case .resume:
            guard !descriptor.aborting else {
                stateLock.unlock()
                throw LegacyProtocolError.invalidRecord("transfer is aborting")
            }
            descriptor.paused = false
            downloadBandwidthGeneration &+= 1
            if downloadBandwidthGeneration == 0 { downloadBandwidthGeneration = 1 }
        case .abort:
            descriptor.paused = false
            descriptor.aborting = true
            socketToInterrupt = descriptor.socketFD
            downloadBandwidthGeneration &+= 1
            if downloadBandwidthGeneration == 0 { downloadBandwidthGeneration = 1 }
        }
        activeTransferDescriptors[request.transferID] = descriptor
        stateLock.unlock()
        if let socketToInterrupt { LegacySocket.interrupt(socketToInterrupt) }
    }

    private func activeManagedTransferRecords() -> [LegacyManagedTransferRecord] {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeTransferDescriptors.values.sorted { $0.transferID < $1.transferID }.map { descriptor in
            var flags: UInt8 = 0
            if descriptor.paused { flags |= LegacyManagedTransferRecord.pausedFlag }
            if descriptor.aborting { flags |= LegacyManagedTransferRecord.abortingFlag }
            if descriptor.isDirectory { flags |= LegacyManagedTransferRecord.directoryFlag }
            return LegacyManagedTransferRecord(transferID: descriptor.transferID, kind: descriptor.kind,
                                               userID: descriptor.userID, path: descriptor.path,
                                               bytesTransferred: descriptor.bytesTransferred,
                                               totalBytes: descriptor.totalBytes, flags: flags)
        }
    }

    private func activeTransferInfoRecords() -> [LegacyTransferInfoRecord] {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeTransferDescriptors.values.sorted { $0.transferID < $1.transferID }.map {
            LegacyTransferInfoRecord(kind: $0.kind, userID: $0.userID, path: $0.path,
                                     bytesTransferred: $0.bytesTransferred, totalBytes: $0.totalBytes,
                                     legacyMetricBits: 0)
        }
    }

    private func activeTransferTasks(userID: UInt32) -> [LegacyCompactTaskInfo] {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeTransferDescriptors.values.filter { $0.userID == userID }.sorted { $0.transferID < $1.transferID }.map {
            let percent: UInt8
            if $0.totalBytes == 0 { percent = 0 }
            else { percent = UInt8(min(100, Int((Double($0.bytesTransferred) / Double($0.totalBytes)) * 100.0))) }
            return LegacyCompactTaskInfo(transferID: $0.transferID, kind: $0.kind,
                                         displayName: $0.path, progressPercent: percent)
        }
    }

    private func handleTransferInfo(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let account = session.account,
              account.mode == .administrator || account.permissions.contains(.manageTransfers) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 2)); return
        }
        do {
            if let limitField = packet.firstField(type: LegacyTransferMonitorField.uploadBandwidthLimit) {
                // This is a server-wide aggregate outbound cap, not a per-session preference.
                // Delegated transfer managers may inspect/control transfers, but only an
                // administrator may alter a global server runtime setting.
                guard account.mode == .administrator else {
                    try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 2)); return
                }
                guard limitField.value.count == 8 else {
                    throw LegacyProtocolError.invalidLength("transfer bandwidth limit must be exactly 8 bytes")
                }
                var cursor = LegacyByteCursor(limitField.value)
                let limit = try cursor.readUInt64BE()
                try cursor.requireEnd()
                setDownloadBandwidthLimit(limit)
                var runtimeSettings = backend.snapshot().runtime
                if runtimeSettings.uploadBandwidthLimitBytesPerSecond != limit {
                    runtimeSettings.uploadBandwidthLimitBytesPerSecond = limit
                    try backend.updateRuntime(runtimeSettings)
                    try persistStartupConfigurationToJSON(backend.snapshot())
                    onStateChanged?()
                }
            }
            if let controlField = packet.firstField(type: LegacyTransferMonitorField.transferControl) {
                try applyTransferControl(try LegacyTransferControlRequest.decode(controlField.value))
            }
            var fields = try activeTransferInfoRecords().map {
                LegacyTLV(type: LegacyTransferMonitorField.transferRecord, value: try $0.encoded())
            }
            fields.append(contentsOf: try activeManagedTransferRecords().map {
                LegacyTLV(type: LegacyTransferMonitorField.managedTransferRecord, value: try $0.encoded())
            })
            stateLock.lock()
            let limit = downloadBandwidthLimitBytesPerSecond
            let rate = currentDownloadTrafficRateLocked(now: ProcessInfo.processInfo.systemUptime)
            stateLock.unlock()
            fields.append(LegacyTLV(type: LegacyTransferMonitorField.uploadBandwidthLimit,
                                    value: LegacyWire.uint64BE(limit)))
            fields.append(LegacyTLV(type: LegacyTransferMonitorField.downloadTrafficRate,
                                    value: LegacyWire.uint64BE(rate)))
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.transferInfo,
                                                        transactionID: packet.transactionID, fields: fields))
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func endFileTransfer(transferID: UInt32, access: LegacyTransferAccess,
                                 direction: LegacyFileTransferDirection, succeeded: Bool) {
        stateLock.lock()
        let descriptor = activeTransferDescriptors[transferID]
        let completedBytes = descriptor?.wireBytesTransferred ?? 0
        activeTransferDescriptors.removeValue(forKey: transferID)
        if direction == .download {
            downloadBandwidthGeneration &+= 1
            if downloadBandwidthGeneration == 0 { downloadBandwidthGeneration = 1 }
        }
        activeFileTransfers = max(0, activeFileTransfers - 1)
        let next = max(0, activeFileTransfersByUser[access.userID, default: 1] - 1)
        if next == 0 { activeFileTransfersByUser.removeValue(forKey: access.userID) }
        else { activeFileTransfersByUser[access.userID] = next }
        stateLock.unlock()
        do {
            try backend.mutateStatistics { stats in
                switch direction {
                case .download:
                    if stats.downloadsInProgress > 0 { stats.downloadsInProgress -= 1 }
                    if succeeded { stats.totalDownloads &+= 1 }
                case .upload:
                    if stats.uploadsInProgress > 0 { stats.uploadsInProgress -= 1 }
                    if succeeded { stats.totalUploads &+= 1 }
                }
            }
        } catch { log("Could not persist transfer-end statistics: \(error.localizedDescription)") }
        if succeeded {
            do {
                try backend.recordCompletedTransfer(accountID: access.account.id, login: access.account.login,
                                                    direction: direction == .download ? .download : .upload,
                                                    bytes: completedBytes)
            } catch { log("Could not persist per-account transfer statistics: \(error.localizedDescription)") }
        }
        if let descriptor {
            logFileTransfer(descriptor, access: access, direction: direction, succeeded: succeeded)
            let status = succeeded ? "completed" : (descriptor.aborting ? "aborted" : "failed")
            let action = direction == .download ? "download" : "upload"
            let path = descriptor.path.isEmpty ? "/" : LegacyPath.displayString(descriptor.path)
            appendUserEvent(access: access, category: "transfers", action: action,
                            detail: "status=\(status) path=\(path) bytes=\(descriptor.wireBytesTransferred)")
        }
        emitStatus()
    }

    private func personalDiskName(for account: ServerAccount) -> String {
        let login = account.login
        if !login.isEmpty, login != ".", login != "..", !login.contains("/"), !login.contains("\0") {
            return login
        }
        return ".account-\(account.id.uuidString.lowercased())"
    }

    private func personalHomeURL(for account: ServerAccount, createIfNeeded: Bool) throws -> URL {
        let root = personalHomeRoot.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(personalDiskName(for: account), isDirectory: true).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw LegacyServerRuntimeError.protocolFailure("personal directory escaped Users/Home")
        }
        if createIfNeeded, account.personalDirectory != .none {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private func personalVirtualName(for account: ServerAccount) throws -> Data {
        guard !account.login.contains("/"), !account.login.contains("\0"),
              let data = ("~" + account.login).data(using: .macOSRoman),
              !data.isEmpty, data.count <= 255, !data.contains(LegacyPath.separator) else {
            throw LegacyServerRuntimeError.protocolFailure("personal directory name is not representable for Classic clients")
        }
        return data
    }

    /// Keeps the modern Users/Home layout in sync with account edits without deleting data.
    /// Disabling/deleting an account leaves the old directory on disk so an administrator can
    /// recover its contents; it is no longer reachable through that account's virtual file view.
    func synchronizePersonalDirectory(oldAccount: ServerAccount?, newAccount: ServerAccount?) throws {
        guard let newAccount else { return }
        guard newAccount.personalDirectory != .none else { return }
        let target = try personalHomeURL(for: newAccount, createIfNeeded: false)
        if let oldAccount, oldAccount.login != newAccount.login, oldAccount.personalDirectory != .none {
            let old = try personalHomeURL(for: oldAccount, createIfNeeded: false)
            if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: old, to: target)
            }
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }

    private func accountFilesRootGroup(_ account: ServerAccount?) -> ServerAccountGroup? {
        guard let account, account.personalDirectory != .rootDirectory else { return nil }
        return backend.snapshot().accountGroup(for: account)
    }

    private func configuredLegacyFilesRootURL() throws -> URL? {
        let path = backend.snapshot().runtime.legacyFilesRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        guard NSString(string: path).isAbsolutePath else {
            throw LegacyServerRuntimeError.protocolFailure("legacy Files root must be an absolute path")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func usesLegacyFilesRoot(legacyTransport: Bool) -> Bool {
        legacyTransport && !backend.snapshot().runtime.legacyFilesRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Classic can have its own physical Files root for compatibility. Explicit directory
    /// symlinks placed directly in the modern published root are still administrator-created
    /// shares, so expose them at the Classic root as virtual ordinary folders. A real entry in
    /// the Classic root with the same name always wins.
    private func legacyShareOverlayRootURL(_ account: ServerAccount?) -> URL? {
        guard usesLegacyFilesRoot(legacyTransport: true),
              account?.personalDirectory != .rootDirectory else { return nil }
        return try? accountFilesRootURL(account, legacyTransport: false, createIfNeeded: false)
    }

    private func legacyShareOverlayURL(firstComponent: Data, account: ServerAccount?,
                                       legacyRoot: URL) -> URL? {
        guard let modernRoot = legacyShareOverlayRootURL(account),
              let component = CarrachoTextWire.validatedString(from: firstComponent),
              !component.isEmpty, component != ".", component != ".." else { return nil }

        // Anything physically present in Files-Legacy shadows the overlay by design.
        let legacyCandidate = legacyRoot.appendingPathComponent(component).standardizedFileURL
        if FileManager.default.fileExists(atPath: legacyCandidate.path) { return nil }

        let modernCandidate = modernRoot.appendingPathComponent(component).standardizedFileURL
        guard FileManager.default.fileExists(atPath: modernCandidate.path),
              (try? modernCandidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
            return nil
        }
        let resolved = modernCandidate.resolvingSymlinksInPath().standardizedFileURL
        guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return modernRoot
    }

    private func metadataStore(legacyTransport: Bool) -> ServerFileMetadataStore? {
        usesLegacyFilesRoot(legacyTransport: legacyTransport) ? legacyFileMetadataStore : fileMetadataStore
    }

    private func accountFilesRootURL(_ account: ServerAccount?, legacyTransport: Bool = false, createIfNeeded: Bool = true) throws -> URL {
        let manager = FileManager.default
        let base = (legacyTransport ? try configuredLegacyFilesRootURL() : nil) ?? storageRoot.standardizedFileURL
        if createIfNeeded { try manager.createDirectory(at: base, withIntermediateDirectories: true) }
        guard let group = accountFilesRootGroup(account), !group.filesRootPath.isEmpty else { return base }
        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL

        func isInsideStorage(_ path: String) -> Bool {
            resolvedBase.path == "/" ? path.hasPrefix("/") : (path == resolvedBase.path || path.hasPrefix(resolvedBase.path + "/"))
        }

        func requireInsideStorage(_ url: URL) throws -> URL {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard isInsideStorage(resolved.path) else {
                throw LegacyServerRuntimeError.protocolFailure("account-group Files root resolves outside server storage")
            }
            return resolved
        }

        var candidate = base
        let components = group.filesRootPath.split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() {
            let value = String(component)
            guard !value.isEmpty, value != ".", value != "..", !value.contains("\0") else {
                throw LegacyServerRuntimeError.protocolFailure("invalid account-group Files root")
            }
            candidate.appendPathComponent(value, isDirectory: true)
            candidate = candidate.standardizedFileURL
            guard base.path == "/" ? candidate.path.hasPrefix("/") : candidate.path.hasPrefix(base.path + "/") else {
                throw LegacyServerRuntimeError.protocolFailure("account-group Files root escaped server storage")
            }

            let isFinalComponent = index == components.count - 1
            if manager.fileExists(atPath: candidate.path) {
                let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
                // Only the configured group's final root may intentionally be a server-side
                // share that resolves outside Files. Parents must remain anchored in Files.
                if !isFinalComponent { _ = try requireInsideStorage(candidate) }
                let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    throw LegacyServerRuntimeError.protocolFailure("account-group Files root is not a directory")
                }
            } else if createIfNeeded {
                // Missing components are always created inside Files. External roots are therefore
                // possible only through an explicitly provisioned final symlink.
                _ = try requireInsideStorage(candidate.deletingLastPathComponent())
                try manager.createDirectory(at: candidate, withIntermediateDirectories: false)
                _ = try requireInsideStorage(candidate)
            }
        }
        return candidate
    }

    private func accountFilesRootLegacyPrefix(_ account: ServerAccount?) throws -> Data {
        guard let group = accountFilesRootGroup(account), !group.filesRootPath.isEmpty else { return Data() }
        var path = Data()
        for component in group.filesRootPath.split(separator: "/", omittingEmptySubsequences: false) {
            let encoded = try CarrachoTextWire.encode(String(component), maximumBytes: 255)
            path = try LegacyPath.child(parent: path, name: encoded)
        }
        return path
    }

    private func storageMetadataPath(_ virtualPath: Data, account: ServerAccount?) throws -> Data {
        guard let account else { return virtualPath }
        if account.personalDirectory == .rootDirectory { return virtualPath }
        if account.personalDirectory == .nestedInRoot,
           let first = try pathComponents(virtualPath).first, first == (try personalVirtualName(for: account)) {
            return virtualPath
        }
        let prefix = try accountFilesRootLegacyPrefix(account)
        guard !prefix.isEmpty else { return virtualPath }
        var result = prefix
        if !virtualPath.isEmpty {
            result.append(LegacyPath.separator)
            result.append(virtualPath)
        }
        guard result.count <= LegacyPath.maximumWireLength else {
            throw LegacyServerRuntimeError.protocolFailure("mapped account-group storage path exceeds limit")
        }
        return result
    }

    private func pathComponents(_ legacyPath: Data) throws -> [Data] {
        guard legacyPath.count <= LegacyPath.maximumWireLength else {
            throw LegacyServerRuntimeError.protocolFailure("legacy storage path exceeds limit")
        }
        if legacyPath.isEmpty { return [] }
        return try legacyPath.split(separator: LegacyPath.separator, omittingEmptySubsequences: false).map { raw in
            let data = Data(raw)
            guard !data.isEmpty,
                  let component = String(data: data, encoding: .macOSRoman),
                  component != ".", component != "..", !component.contains("/"), !component.contains("\0") else {
                throw LegacyServerRuntimeError.protocolFailure("unsafe legacy storage path")
            }
            return data
        }
    }

    private func isInsideDropbox(_ path: Data, account: ServerAccount?, legacyTransport: Bool = false) throws -> Bool {
        guard let metadata = metadataStore(legacyTransport: legacyTransport) else { return false }
        var current = Data()
        for component in try pathComponents(path) {
            current = try LegacyPath.child(parent: current, name: component)
            let mapped = try storageMetadataPath(current, account: account)
            if let flags = metadata.metadata(for: mapped)?.flags,
               (flags & LegacyDirectoryFlags.dropBox) != 0 { return true }
        }
        return false
    }

    private func requireDropboxReadAccess(path: Data, account: ServerAccount?, legacyTransport: Bool = false) throws {
        guard account?.permissions.contains(.viewDropboxes) != true else { return }
        if try isInsideDropbox(path, account: account, legacyTransport: legacyTransport) {
            throw LegacyServerRuntimeError.protocolFailure("dropbox contents require view-dropboxes permission")
        }
    }

    /// Classic upload permission semantics: Can Upload permits writes only into a folder
    /// carrying either special mode bit. Can Upload Anywhere widens that to ordinary folders.
    /// A Dropbox is intentionally also an upload folder, matching the original server.
    private func requireUploadDestinationAccess(parentPath: Data, account: ServerAccount, legacyTransport: Bool = false) throws {
        guard account.permissions.contains(.upload) else {
            throw LegacyServerRuntimeError.protocolFailure("upload permission denied")
        }
        if account.permissions.contains(.uploadAnywhere) { return }
        let flags = metadataStore(legacyTransport: legacyTransport)?.metadata(for: try storageMetadataPath(parentPath, account: account))?.flags ?? 0
        guard (flags & LegacyDirectoryFlags.specialFolderModeMask) != 0 else {
            throw LegacyServerRuntimeError.protocolFailure("upload destination is not an Upload Folder or Dropbox")
        }
    }

    private func visibleDirectoryItemCount(at directory: URL, supportsTaggedUTF8Names: Bool) -> UInt32 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: Array(keys),
                                                                          options: [.skipsHiddenFiles]) else { return 0 }
        var count: UInt64 = 0
        for child in children {
            let name = child.lastPathComponent
            if Self.isTransferStagingName(name) { continue }
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isDirectory == true || values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            if supportsTaggedUTF8Names {
                guard let encoded = try? CarrachoTextWire.encode(name, maximumBytes: 255), !encoded.isEmpty else { continue }
            } else {
                guard let encoded = name.data(using: .macOSRoman, allowLossyConversion: true),
                      !encoded.isEmpty, encoded.count <= 255 else { continue }
            }
            count += 1
            if count >= UInt64(UInt32.max) { return UInt32.max }
        }
        return UInt32(count)
    }

    fileprivate func directoryListing(path: Data, account: ServerAccount?,
                                      supportsTaggedUTF8Names: Bool = true, legacyTransport: Bool = false) throws -> LegacyDirectoryListing {
        let directory = try storageURL(for: path, account: account, legacyTransport: legacyTransport, requireExisting: true)
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try resolvedDirectory.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw LegacyServerRuntimeError.protocolFailure("requested path is not a directory")
        }
        if account?.permissions.contains(.viewDropboxes) != true, try isInsideDropbox(path, account: account, legacyTransport: legacyTransport) {
            return LegacyDirectoryListing(currentPath: path, entries: [])
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let children = try FileManager.default.contentsOfDirectory(at: resolvedDirectory,
                                                                   includingPropertiesForKeys: Array(keys),
                                                                   options: [.skipsHiddenFiles])
        var entries: [LegacyDirectoryEntry] = []
        let virtualPersonalName: Data?
        if path.isEmpty, let account, account.personalDirectory == .nestedInRoot {
            virtualPersonalName = try personalVirtualName(for: account)
        } else {
            virtualPersonalName = nil
        }
        var visibleNames = Set<String>()
        for child in children.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard !Self.isTransferStagingName(child.lastPathComponent) else { continue }
            let values = try child.resourceValues(forKeys: keys)
            let isSymbolicLink = values.isSymbolicLink == true
            let childPathCandidate: Data
            do { childPathCandidate = try LegacyPath.child(parent: path, name: supportsTaggedUTF8Names ? CarrachoTextWire.encode(child.lastPathComponent, maximumBytes: 255) : (child.lastPathComponent.data(using: .macOSRoman, allowLossyConversion: true) ?? Data())) }
            catch { continue }
            let targetValues: URLResourceValues?
            var targetURL = child
            if isSymbolicLink {
                do {
                    let safeURL = try storageURL(for: childPathCandidate, account: account, legacyTransport: legacyTransport, requireExisting: true)
                    targetURL = safeURL.resolvingSymlinksInPath()
                    targetValues = try targetURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                } catch {
                    targetValues = nil
                }
            } else {
                targetValues = values
            }
            guard isSymbolicLink || targetValues?.isDirectory == true || targetValues?.isRegularFile == true else { continue }
            let name: Data
            if supportsTaggedUTF8Names {
                guard let encoded = try? CarrachoTextWire.encode(child.lastPathComponent, maximumBytes: 255), !encoded.isEmpty else { continue }
                name = encoded
            } else {
                guard let encoded = child.lastPathComponent.data(using: .macOSRoman, allowLossyConversion: true),
                      !encoded.isEmpty, encoded.count <= 255 else { continue }
                name = encoded
            }
            if let virtualPersonalName, name == virtualPersonalName { continue }
            let targetIsFolder = targetValues?.isDirectory == true
            let targetIsFile = targetValues?.isRegularFile == true
            let fileSize = targetIsFile ? UInt64(max(targetValues?.fileSize ?? 0, 0)) : 0
            let timestamp: UInt32
            if let date = targetValues?.contentModificationDate ?? values.contentModificationDate {
                let classic = max(0, date.timeIntervalSince1970 + Self.macEpochOffset)
                timestamp = UInt32(min(classic, TimeInterval(UInt32.max)))
            } else { timestamp = 0 }
            let childPath = try LegacyPath.child(parent: path, name: name)
            let storedMetadata = metadataStore(legacyTransport: legacyTransport)?.metadata(for: try storageMetadataPath(childPath, account: account))
            let storedFlags = storedMetadata?.flags ?? 0
            let storedLabel = legacyTransport ? LegacyFileLabel.none : (LegacyFileLabel(rawValue: storedMetadata?.label ?? 0) ?? .none)
            let wireFlags = storedFlags | (targetIsFolder ? LegacyDirectoryFlags.folder : 0)
            let wireSize: UInt32
            if targetIsFolder {
                let hiddenDropbox: Bool
                if account?.permissions.contains(.viewDropboxes) != true {
                    hiddenDropbox = try isInsideDropbox(childPath, account: account, legacyTransport: legacyTransport)
                } else {
                    hiddenDropbox = false
                }
                wireSize = hiddenDropbox ? 0 : visibleDirectoryItemCount(at: targetURL, supportsTaggedUTF8Names: supportsTaggedUTF8Names)
            } else {
                wireSize = UInt32(min(fileSize, UInt64(UInt32.max)))
            }
            let presentedAsFolder = targetIsFolder
            entries.append(LegacyDirectoryEntry(name: name,
                                                size: wireSize,
                                                timestamp: timestamp,
                                                fileType: presentedAsFolder ? Self.folderType : (isSymbolicLink ? Self.symbolicLinkType : 0),
                                                creator: (presentedAsFolder || isSymbolicLink) ? Self.folderCreator : 0,
                                                flags: wireFlags,
                                                label: storedLabel))
            visibleNames.insert(child.lastPathComponent.lowercased())
        }

        // Files-Legacy is intentionally a separate compatibility tree, but explicit directory
        // symlinks in the modern published root are administrator-created shares. Mirror those
        // root-level shares into Classic as ordinary FLDR entries so old clients can traverse them.
        if legacyTransport, path.isEmpty,
           let overlayRoot = legacyShareOverlayRootURL(account),
           let overlayChildren = try? FileManager.default.contentsOfDirectory(
               at: overlayRoot,
               includingPropertiesForKeys: Array(keys),
               options: [.skipsHiddenFiles]
           ) {
            for child in overlayChildren.sorted(by: {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }) {
                guard !Self.isTransferStagingName(child.lastPathComponent),
                      !visibleNames.contains(child.lastPathComponent.lowercased()) else { continue }
                let values = try child.resourceValues(forKeys: keys)
                guard values.isSymbolicLink == true else { continue }

                let name: Data
                if supportsTaggedUTF8Names {
                    guard let encoded = try? CarrachoTextWire.encode(child.lastPathComponent, maximumBytes: 255),
                          !encoded.isEmpty else { continue }
                    name = encoded
                } else {
                    guard let encoded = child.lastPathComponent.data(using: .macOSRoman),
                          !encoded.isEmpty, encoded.count <= 255 else { continue }
                    name = encoded
                }
                if let virtualPersonalName, name == virtualPersonalName { continue }

                let childPath = try LegacyPath.child(parent: path, name: name)
                guard let targetURL = try? storageURL(for: childPath, account: account,
                                                      legacyTransport: true, requireExisting: true),
                      (try? targetURL.resolvingSymlinksInPath()
                        .resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

                let resolvedTarget = targetURL.resolvingSymlinksInPath().standardizedFileURL
                let targetValues = try resolvedTarget.resourceValues(forKeys: [.contentModificationDateKey])
                let timestamp = targetValues.contentModificationDate?.legacyMacTimestamp ?? 0
                let wireSize = visibleDirectoryItemCount(at: resolvedTarget,
                                                         supportsTaggedUTF8Names: supportsTaggedUTF8Names)
                let storedMetadata = fileMetadataStore?.metadata(
                    for: try storageMetadataPath(childPath, account: account)
                )
                let wireFlags = (storedMetadata?.flags ?? 0) | LegacyDirectoryFlags.folder

                entries.append(LegacyDirectoryEntry(name: name,
                                                    size: wireSize,
                                                    timestamp: timestamp,
                                                    fileType: Self.folderType,
                                                    creator: Self.folderCreator,
                                                    flags: wireFlags,
                                                    label: .none))
                visibleNames.insert(child.lastPathComponent.lowercased())
            }
        }
        if let account, account.personalDirectory == .nestedInRoot, path.isEmpty,
           let name = virtualPersonalName {
            let home = try personalHomeURL(for: account, createIfNeeded: true)
            let values = try home.resourceValues(forKeys: [.contentModificationDateKey])
            let timestamp = values.contentModificationDate?.legacyMacTimestamp ?? 0
            let itemCount = visibleDirectoryItemCount(at: home, supportsTaggedUTF8Names: supportsTaggedUTF8Names)
            entries.append(LegacyDirectoryEntry(name: name, size: itemCount, timestamp: timestamp,
                                                fileType: Self.folderType, creator: Self.folderCreator,
                                                flags: LegacyDirectoryFlags.folder))
        }
        entries.sort {
            CarrachoTextWire.string(from: $0.name)
                .localizedCaseInsensitiveCompare(CarrachoTextWire.string(from: $1.name)) == .orderedAscending
        }
        return LegacyDirectoryListing(currentPath: path, entries: entries)
    }

    private func storageURL(for legacyPath: Data, account: ServerAccount?, legacyTransport: Bool = false, requireExisting: Bool) throws -> URL {
        var components = try pathComponents(legacyPath)
        var root = try accountFilesRootURL(account, legacyTransport: legacyTransport)
        var usesPersonalHomeRoot = false
        if let account {
            switch account.personalDirectory {
            case .none:
                break
            case .rootDirectory:
                root = try personalHomeURL(for: account, createIfNeeded: true)
                usesPersonalHomeRoot = true
            case .nestedInRoot:
                if let first = components.first, first == (try personalVirtualName(for: account)) {
                    root = try personalHomeURL(for: account, createIfNeeded: true)
                    usesPersonalHomeRoot = true
                    components.removeFirst()
                }
            }
        }
        if legacyTransport,
           !usesPersonalHomeRoot,
           let first = components.first,
           let overlayRoot = legacyShareOverlayURL(firstComponent: first, account: account,
                                                   legacyRoot: root.standardizedFileURL) {
            root = overlayRoot
        }

        let logicalRoot = root.standardizedFileURL
        let resolvedRoot = logicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try resolvedRoot.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw LegacyServerRuntimeError.protocolFailure("server storage root is not a directory")
        }

        func isInside(_ url: URL, root: URL) -> Bool {
            let path = url.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            return rootPath == "/" ? path.hasPrefix("/") : (path == rootPath || path.hasPrefix(rootPath + "/"))
        }

        var resolvedScope = resolvedRoot
        let allowServerSymlinkShares = !usesPersonalHomeRoot
        var symlinkShareHops = 0
        var current = logicalRoot
        for (index, data) in components.enumerated() {
            guard let component = CarrachoTextWire.validatedString(from: data) else {
                throw LegacyServerRuntimeError.protocolFailure("invalid storage path encoding")
            }
            current.appendPathComponent(component)
            current = current.standardizedFileURL
            let isLast = index == components.count - 1

            if FileManager.default.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
                let resolved = current.resolvingSymlinksInPath().standardizedFileURL
                if !isInside(resolved, root: resolvedScope) {
                    let targetValues = try resolved.resourceValues(forKeys: [.isDirectoryKey])
                    guard allowServerSymlinkShares,
                          values.isSymbolicLink == true,
                          targetValues.isDirectory == true else {
                        throw LegacyServerRuntimeError.protocolFailure("server storage symlink escaped account root")
                    }
                    symlinkShareHops += 1
                    guard symlinkShareHops <= 32 else {
                        throw LegacyServerRuntimeError.protocolFailure("too many nested server storage symlinks")
                    }
                    resolvedScope = resolved
                }
            } else if requireExisting || !isLast {
                throw LegacyServerRuntimeError.protocolFailure("server storage path does not exist")
            } else {
                let resolvedParent = current.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                guard isInside(resolvedParent, root: resolvedScope) else {
                    throw LegacyServerRuntimeError.protocolFailure("server storage path escaped account root")
                }
            }
        }

        let finalPath = current.path
        guard finalPath == logicalRoot.path || finalPath.hasPrefix(logicalRoot.path + "/") else {
            throw LegacyServerRuntimeError.protocolFailure("server storage path escaped root")
        }
        return current
    }

    private func serveDownload(stream: LegacySocketTransferStream, access: LegacyTransferAccess, transferID: UInt32) throws {
        let remotePath = try stream.readString16()
        guard !remotePath.isEmpty else { throw LegacyServerRuntimeError.protocolFailure("empty download path") }
        configureTransfer(transferID, path: remotePath)
        try requireDropboxReadAccess(path: remotePath, account: access.account, legacyTransport: access.legacyTransport)
        let source = try storageURL(for: remotePath, account: access.account, legacyTransport: access.legacyTransport, requireExisting: true)
        let entries = try downloadEntries(root: source, rootLegacyPath: remotePath, account: access.account, legacyTransport: access.legacyTransport)
        guard !entries.isEmpty else { throw LegacyServerRuntimeError.protocolFailure("empty download tree") }
        let total = try entries.reduce(UInt64(0)) { partial, entry in
            guard !entry.isFolder else { return partial }
            let (sum, overflow) = partial.addingReportingOverflow(entry.size)
            if overflow { throw LegacyServerRuntimeError.protocolFailure("download size overflow") }
            return sum
        }
        configureTransfer(transferID, path: remotePath, totalBytes: total,
                          isDirectory: entries.first?.isFolder == true)
        try stream.sendPayload(LegacyWire.uint32BE(0)) // immediate queue position
        var envelope = LegacyWire.uint64BE(total)
        envelope.append(LegacyWire.uint32BE(UInt32(entries.count)))
        try stream.sendPayload(envelope)
        for entry in entries {
            try stream.sendPayload(try transferEntryHeader(entry))
            guard !entry.isFolder else { continue }
            let resume = try stream.readUInt64()
            guard resume <= entry.size else { throw LegacyServerRuntimeError.protocolFailure("download resume offset exceeds file size") }
            let classicForkWire = access.legacyTransport
            if classicForkWire {
                // Classic operation 10 negotiates data and resource forks separately.
                // The portable server has no native HFS resource fork, but the second
                // resume value must still be consumed or the stream becomes misaligned.
                _ = try stream.readUInt64()
            }
            addTransferResumeProgress(transferID, bytes: resume)
            if resume > 0 { log("Resuming download for user \(access.userID) at \(resume)/\(entry.size) bytes") }
            let remaining = entry.size - resume
            var forkLengths = LegacyWire.uint64BE(remaining)
            if classicForkWire { forkLengths.append(LegacyWire.uint64BE(0)) }
            try stream.sendPayload(forkLengths)
            let handle = try FileHandle(forReadingFrom: entry.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: resume)
            var left = remaining
            while left > 0 {
                try awaitTransferReady(transferID)
                let chunkLimit = pacedDownloadChunkSize(maximum: Self.ioChunk)
                let requested = Int(min(UInt64(chunkLimit), left))
                let data = handle.readData(ofLength: requested)
                guard !data.isEmpty else { throw LegacyServerRuntimeError.protocolFailure("download file ended early") }
                throttleDownload(transferID, bytes: data.count)
                try awaitTransferReady(transferID)
                try stream.sendPayload(data)
                left -= UInt64(data.count)
                addTransferProgress(transferID, bytes: UInt64(data.count))
            }
            try stream.sendPayload(LegacyWire.uint16BE(0)) // no Finder comment
        }
        log("Download completed for user \(access.userID): \(LegacyPath.displayString(remotePath))")
    }

    private func downloadEntries(root: URL, rootLegacyPath: Data, account: ServerAccount, legacyTransport: Bool = false) throws -> [LegacyServerTransferEntry] {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try resolvedRoot.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        guard rootValues.isDirectory == true || rootValues.isRegularFile == true else {
            throw LegacyServerRuntimeError.protocolFailure("unsupported download root")
        }
        let rootName = try legacyLeafName(rootLegacyPath)
        var result = [LegacyServerTransferEntry(relativePath: rootName, url: resolvedRoot,
                                                isFolder: rootValues.isDirectory == true,
                                                size: rootValues.isRegularFile == true ? UInt64(max(rootValues.fileSize ?? 0, 0)) : 0)]
        guard rootValues.isDirectory == true else { return result }
        let configuredMaxDepth = backend.snapshot().advanced.maxFolderDownloadDepth
        // Advanced limit value 0 means unlimited. Treating it as literal depth zero
        // produced an empty directory transfer containing only the root folder.
        let maxDepth = configuredMaxDepth == 0 ? Int.max : Int(configuredMaxDepth)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var visitedDirectories: Set<String> = [resolvedRoot.path]

        func walk(_ directory: URL, relative: Data, serverPath: Data, depth: Int) throws {
            guard depth <= maxDepth else { return }
            let children = try FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: Array(keys),
                                                                       options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            for child in children {
                guard !Self.isTransferStagingName(child.lastPathComponent),
                      let name = child.lastPathComponent.data(using: .macOSRoman), !name.isEmpty else { continue }
                let childRelative = try LegacyPath.child(parent: relative, name: name)
                let childServerPath = try LegacyPath.child(parent: serverPath, name: name)
                let logicalURL: URL
                do { logicalURL = try storageURL(for: childServerPath, account: account, legacyTransport: legacyTransport, requireExisting: true) }
                catch { continue }
                let resolvedChild = logicalURL.resolvingSymlinksInPath().standardizedFileURL
                let values = try resolvedChild.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                guard values.isDirectory == true || values.isRegularFile == true else { continue }
                let isFolder = values.isDirectory == true
                result.append(LegacyServerTransferEntry(relativePath: childRelative, url: resolvedChild, isFolder: isFolder,
                                                        size: isFolder ? 0 : UInt64(max(values.fileSize ?? 0, 0))))
                if isFolder && depth < maxDepth {
                    let isDropbox = (metadataStore(legacyTransport: legacyTransport)?.metadata(for: try storageMetadataPath(childServerPath, account: account))?.flags ?? 0) & LegacyDirectoryFlags.dropBox != 0
                    if (!isDropbox || account.permissions.contains(.viewDropboxes)),
                       visitedDirectories.insert(resolvedChild.path).inserted {
                        try walk(resolvedChild, relative: childRelative, serverPath: childServerPath, depth: depth + 1)
                    }
                }
            }
        }
        if maxDepth > 0 { try walk(resolvedRoot, relative: rootName, serverPath: rootLegacyPath, depth: 1) }
        guard result.count <= Int(UInt32.max) else { throw LegacyServerRuntimeError.protocolFailure("too many download entries") }
        return result
    }

    private func transferEntryHeader(_ entry: LegacyServerTransferEntry) throws -> Data {
        var data = try LegacyWire.string16(entry.relativePath)
        data.append(LegacyWire.uint32BE(entry.isFolder ? Self.folderType : 0))
        data.append(LegacyWire.uint32BE(entry.isFolder ? Self.folderCreator : 0))
        data.append(LegacyWire.uint16BE(entry.isFolder ? LegacyDirectoryFlags.folder : 0))
        data.append(Data(repeating: 0, count: 16))
        if entry.isFolder {
            data.append(LegacyWire.uint32BE(0))
        } else {
            data.append(LegacyWire.uint32BE(8))
            data.append(LegacyWire.uint64BE(entry.size))
        }
        return data
    }

    private func serveUpload(stream: LegacySocketTransferStream, access: LegacyTransferAccess, transferID: UInt32) throws {
        let parentPath = try stream.readString16()
        let wireTargetPath = try stream.readString16()
        guard !wireTargetPath.isEmpty else {
            throw LegacyServerRuntimeError.protocolFailure("upload target is empty")
        }
        let targetPath: Data
        if LegacyPath.parent(of: wireTargetPath) == parentPath {
            targetPath = wireTargetPath
        } else if access.legacyTransport, !parentPath.isEmpty, !wireTargetPath.contains(LegacyPath.separator) {
            // Carracho's Classic client sends the current destination directory first and only
            // the uploaded leaf name second. Modern peers use the complete target path.
            targetPath = try LegacyPath.child(parent: parentPath, name: wireTargetPath)
        } else {
            throw LegacyServerRuntimeError.protocolFailure("upload target is not a direct child of parent")
        }
        configureTransfer(transferID, path: targetPath)
        try requireUploadDestinationAccess(parentPath: parentPath, account: access.account, legacyTransport: access.legacyTransport)
        let parentURL = try storageURL(for: parentPath, account: access.account, legacyTransport: access.legacyTransport, requireExisting: true)
        let parentValues = try parentURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw LegacyServerRuntimeError.protocolFailure("upload parent is not a directory")
        }
        let targetURL = try storageURL(for: targetPath, account: access.account, legacyTransport: access.legacyTransport, requireExisting: false)
        let exists = FileManager.default.fileExists(atPath: targetURL.path)
        if exists {
            // Published server content is never replaced by an upload. A partial/resumable upload
            // is stored separately as <name>.carracho, so rejecting an existing final target does
            // not interfere with legitimate resume behavior.
            try stream.sendPayload(Data([1]))
            throw LegacyServerRuntimeError.protocolFailure("upload destination already exists")
        }
        try stream.sendPayload(Data([0]))
        let overwrite = try stream.readUInt8()
        guard overwrite == 0 else {
            throw LegacyServerRuntimeError.protocolFailure("upload overwrite is not permitted")
        }

        let total = try stream.readUInt64()
        configureTransfer(transferID, path: targetPath, totalBytes: total)
        let count = try stream.readUInt32()
        guard count > 0, count <= 1_000_000, total <= 1 << 50 else {
            throw LegacyServerRuntimeError.protocolFailure("unreasonable upload envelope")
        }
        let expectedRootNameData: Data
        if let separator = targetPath.lastIndex(of: LegacyPath.separator) {
            expectedRootNameData = Data(targetPath[targetPath.index(after: separator)...])
        } else {
            expectedRootNameData = targetPath
        }
        guard let expectedRootName = String(data: expectedRootNameData, encoding: .macOSRoman),
              !expectedRootName.isEmpty else {
            throw LegacyServerRuntimeError.protocolFailure("invalid upload target root name")
        }
        let stagingRoot = parentURL.appendingPathComponent("\(expectedRootName).carracho")
        let legacyStagingRoot = parentURL.appendingPathComponent(".carracho.\(expectedRootName)")
        if !FileManager.default.fileExists(atPath: stagingRoot.path),
           FileManager.default.fileExists(atPath: legacyStagingRoot.path) {
            try FileManager.default.moveItem(at: legacyStagingRoot, to: stagingRoot)
        }
        var stagedRootIsFolder: Bool?
        var accountedTotal: UInt64 = 0

        for index in 0..<count {
            let entry = try readUploadEntry(stream: stream, modernExtensions: access.modernSalt != nil)
            let components = try safeTransferComponents(entry.relativePath)
            guard !components.isEmpty, components[0] == expectedRootName else {
                throw LegacyServerRuntimeError.protocolFailure("upload entry escaped root")
            }
            if index == 0 {
                guard components.count == 1 else {
                    throw LegacyServerRuntimeError.protocolFailure("first upload entry is not root")
                }
                stagedRootIsFolder = entry.isFolder
                configureTransfer(transferID, isDirectory: entry.isFolder)
            } else {
                guard stagedRootIsFolder == true else {
                    throw LegacyServerRuntimeError.protocolFailure("single-file upload contains nested entries")
                }
            }

            var local = stagingRoot
            for component in components.dropFirst() { local.appendPathComponent(component) }
            if entry.isFolder {
                if FileManager.default.fileExists(atPath: local.path) {
                    let values = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isDirectory != true || values.isSymbolicLink == true {
                        try FileManager.default.removeItem(at: local)
                        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                    }
                } else {
                    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                }
                continue
            }

            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            var writeURL = index == 0 ? stagingRoot : try uploadPartialURL(for: local)
            var resume: UInt64 = 0
            if index > 0, FileManager.default.fileExists(atPath: local.path), let expected = entry.declaredSize {
                let completedSize = try regularFileSize(at: local)
                if completedSize == expected {
                    writeURL = local
                    resume = expected
                } else {
                    try FileManager.default.removeItem(at: local)
                }
            }
            if resume == 0 {
                resume = try prepareUploadPartial(at: writeURL, expectedSize: entry.declaredSize)
            }
            let classicForkWire = access.modernSalt == nil
            if classicForkWire {
                // Classic encrypted upload (operation 11) negotiates both Macintosh forks.
                // Each resume offset is UInt64 in Blowfish mode: data fork first, then resource fork.
                // We persist the data fork on portable filesystems and deliberately advertise no
                // resumable resource fork, but we still consume one if a Classic client sends it.
                var resumes = LegacyWire.uint64BE(resume)
                resumes.append(LegacyWire.uint64BE(0))
                try stream.sendPayload(resumes)
            } else {
                try stream.sendPayload(LegacyWire.uint64BE(resume))
            }
            addTransferResumeProgress(transferID, bytes: resume)

            let dataLength = try stream.readUInt64()
            let resourceLength = classicForkWire ? try stream.readUInt64() : 0
            let (fullSize, overflow) = resume.addingReportingOverflow(dataLength)
            guard !overflow else { throw LegacyServerRuntimeError.protocolFailure("upload file size overflow") }
            if let expected = entry.declaredSize, fullSize != expected {
                throw LegacyServerRuntimeError.protocolFailure("upload remaining length does not match declared file size")
            }
            let (forkTotal, forkOverflow) = fullSize.addingReportingOverflow(resourceLength)
            let (newAccounted, totalOverflow) = accountedTotal.addingReportingOverflow(forkTotal)
            guard !forkOverflow, !totalOverflow, newAccounted <= total else {
                throw LegacyServerRuntimeError.protocolFailure("upload byte count exceeds declared total")
            }
            accountedTotal = newAccounted

            let handle = try FileHandle(forWritingTo: writeURL)
            do {
                try handle.seek(toOffset: resume)
                var remaining = dataLength
                while remaining > 0 {
                    try awaitTransferReady(transferID)
                    let chunk = Int(min(UInt64(Self.ioChunk), remaining))
                    let data = try stream.readPayload(chunk)
                    handle.write(data)
                    remaining -= UInt64(data.count)
                    addTransferProgress(transferID, bytes: UInt64(data.count))
                }
                try handle.close()
            } catch {
                try? handle.close(); throw error
            }

            // Linux and the portable server model have no native HFS resource fork. Consume it so
            // Classic clients can finish the transfer instead of deadlocking after the 0-byte stage.
            var resourceRemaining = resourceLength
            while resourceRemaining > 0 {
                try awaitTransferReady(transferID)
                let chunk = Int(min(UInt64(Self.ioChunk), resourceRemaining))
                _ = try stream.readPayload(chunk)
                resourceRemaining -= UInt64(chunk)
                addTransferProgress(transferID, bytes: UInt64(chunk))
            }

            let commentLength = Int(try stream.readUInt16())
            guard commentLength <= 4096 else { throw LegacyServerRuntimeError.protocolFailure("upload comment exceeds limit") }
            _ = try stream.readPayload(commentLength)

            let finalSize = try regularFileSize(at: writeURL)
            guard finalSize == fullSize else {
                throw LegacyServerRuntimeError.protocolFailure("partial upload size mismatch after receive")
            }
            if writeURL != local {
                if FileManager.default.fileExists(atPath: local.path) { try FileManager.default.removeItem(at: local) }
                try FileManager.default.moveItem(at: writeURL, to: local)
            }
        }
        guard accountedTotal == total, stagedRootIsFolder != nil,
              FileManager.default.fileExists(atPath: stagingRoot.path) else {
            throw LegacyServerRuntimeError.protocolFailure("upload total/root mismatch")
        }

        // Re-check at commit time as well. FileManager.moveItem itself refuses an existing
        // destination, so a second uploader that wins the race cannot be clobbered by this one.
        guard !FileManager.default.fileExists(atPath: targetURL.path) else {
            throw LegacyServerRuntimeError.protocolFailure("upload destination already exists at commit")
        }
        try FileManager.default.moveItem(at: stagingRoot, to: targetURL)
        refreshSearchIndexSubtree(at: targetURL, path: try storageMetadataPath(targetPath, account: access.account), legacyTransport: access.legacyTransport)
        log("Upload completed for user \(access.userID): \(LegacyPath.displayString(targetPath))")
    }

    private func uploadPartialURL(for finalURL: URL) throws -> URL {
        let parent = finalURL.deletingLastPathComponent()
        let partial = parent.appendingPathComponent("\(finalURL.lastPathComponent).carracho")
        let legacyPartial = parent.appendingPathComponent(".carracho.\(finalURL.lastPathComponent)")
        if !FileManager.default.fileExists(atPath: partial.path),
           FileManager.default.fileExists(atPath: legacyPartial.path) {
            try FileManager.default.moveItem(at: legacyPartial, to: partial)
        }
        return partial
    }

    private func regularFileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw LegacyServerRuntimeError.protocolFailure("upload partial is not a regular file")
        }
        return size.uint64Value
    }

    private func prepareUploadPartial(at url: URL, expectedSize: UInt64?) throws -> UInt64 {
        if FileManager.default.fileExists(atPath: url.path) {
            let size: UInt64
            do { size = try regularFileSize(at: url) }
            catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            if let expectedSize, size > expectedSize {
                try FileManager.default.removeItem(at: url)
            } else {
                return size
            }
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw LegacyServerRuntimeError.protocolFailure("could not create .carracho upload partial")
        }
        return 0
    }

    private func readUploadEntry(stream: LegacySocketTransferStream, modernExtensions: Bool) throws -> (relativePath: Data, isFolder: Bool, declaredSize: UInt64?) {
        let path = try stream.readString16()
        let fixed = try stream.readPayload(30)
        var cursor = LegacyByteCursor(fixed)
        let fileType = try cursor.readUInt32BE()
        let creator = try cursor.readUInt32BE()
        _ = try cursor.readUInt16BE()
        _ = try cursor.readBytes(count: 16)
        let extraLength = Int(try cursor.readUInt32BE())
        guard extraLength <= 4096 else { throw LegacyServerRuntimeError.protocolFailure("upload extra metadata exceeds limit") }
        let extra = try stream.readPayload(extraLength)
        let isFolder = fileType == Self.folderType && creator == Self.folderCreator
        let declaredSize: UInt64?
        if modernExtensions, !isFolder, extra.count >= 8 {
            var sizeCursor = LegacyByteCursor(Data(extra.prefix(8)))
            declaredSize = try sizeCursor.readUInt64BE()
        } else { declaredSize = nil }
        return (path, isFolder, declaredSize)
    }

    private func safeTransferComponents(_ path: Data) throws -> [String] {
        guard !path.isEmpty, path.count <= LegacyPath.maximumWireLength else {
            throw LegacyServerRuntimeError.protocolFailure("invalid transfer relative path")
        }
        return try path.split(separator: LegacyPath.separator, omittingEmptySubsequences: false).map { raw in
            let data = Data(raw)
            guard !data.isEmpty, let name = String(data: data, encoding: .macOSRoman),
                  name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw LegacyServerRuntimeError.protocolFailure("unsafe transfer relative path")
            }
            return name
        }
    }

    private func configuredNewsgroup(named data: Data) -> ServerNewsgroup? {
        guard !data.isEmpty, data.count <= LegacyNewsTransfer.maximumGroupNameLength,
              let name = String(data: data, encoding: .macOSRoman) else { return nil }
        return backend.snapshot().newsgroups.first {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func sendForumThreadList(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let account = session.account,
              let groupData = packet.firstField(type: 1)?.value,
              let group = configuredNewsgroup(named: groupData),
              canRead(group: group, account: account) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        let threads = try newsStore.threadSummaries(groupID: group.id)
        try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.forumThreadList,
                                                    transactionID: packet.transactionID,
                                                    fields: [LegacyTLV(type: 1, value: try LegacyPackedRecords.encodeNewsThreadList(threads))]))
    }

    private func sendForumThreadEntries(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let account = session.account,
              let groupData = packet.firstField(type: 1)?.value,
              let threadField = packet.firstField(type: 2),
              let group = configuredNewsgroup(named: groupData),
              canRead(group: group, account: account) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        do {
            let threadID = try threadField.uint32BE()
            let posts = try newsStore.threadPosts(groupID: group.id, threadID: threadID)
            let capabilities = try newsStore.threadPostCapabilities(groupID: group.id, threadID: threadID,
                                                                     accountID: account.id,
                                                                     canModerate: account.permissions.contains(.manageNewsgroups))
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.forumThreadEntries,
                                                        transactionID: packet.transactionID,
                                                        fields: [
                LegacyTLV(type: 1, value: try LegacyPackedRecords.encodeNewsThreadPosts(posts)),
                LegacyTLV(type: 2, value: try LegacyPackedRecords.encodeNewsPostCapabilities(capabilities)),
            ]))
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func newsReactionSummariesWithUsers(groupID: UUID, articleID: UInt32,
                                                accountID: String, summaries: [LegacyNewsReactionSummary]? = nil) throws -> [LegacyNewsReactionSummary] {
        var result = try summaries ?? newsStore.reactionSummary(groupID: groupID, articleID: articleID, accountID: accountID)
        let reactorIDs = try newsStore.reactionAccountIDs(groupID: groupID, articleID: articleID)
        let snapshot = backend.snapshot()
        let accounts = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id.uuidString.lowercased(), $0) })
        for index in result.indices {
            let ids = reactorIDs[result[index].kind] ?? []
            result[index].userNames = ids.map { rawID in
                let key = rawID.lowercased()
                if let uuid = UUID(uuidString: rawID),
                   let live = authenticatedSession(accountID: uuid),
                   let nickname = String(data: live.nickname, encoding: .macOSRoman)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !nickname.isEmpty { return nickname }
                guard let account = accounts[key] else { return "" }
                if let nickname = account.lastNickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty { return nickname }
                let name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? account.login : name
            }.sorted { left, right in
                if left.isEmpty != right.isEmpty { return !left.isEmpty }
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
        }
        return result
    }

    private func sendForumArticleReactions(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let account = session.account,
              let groupData = packet.firstField(type: 1)?.value,
              let articleField = packet.firstField(type: 2),
              let group = configuredNewsgroup(named: groupData),
              canRead(group: group, account: account) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        do {
            let articleID = try articleField.uint32BE()
            let summary = try newsReactionSummariesWithUsers(groupID: group.id, articleID: articleID,
                                                             accountID: account.id.uuidString.lowercased())
            var fields = [LegacyTLV(type: 1, value: try LegacyPackedRecords.encodeNewsReactions(summary))]
            if let users = try? LegacyPackedRecords.encodeNewsReactionUsers(summary),
               users.count <= Int(UInt16.max) {
                fields.append(LegacyTLV(type: 2, value: users))
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.forumArticleReactions,
                                                        transactionID: packet.transactionID, fields: fields))
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func setForumArticleReaction(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let account = session.account,
              let groupData = packet.firstField(type: 1)?.value,
              let articleField = packet.firstField(type: 2),
              let reactionField = packet.firstField(type: 3), reactionField.value.count == 1,
              let reaction = reactionField.value.first,
              reaction == 0 || LegacyNewsReactionKind(rawValue: reaction) != nil,
              let group = configuredNewsgroup(named: groupData),
              canRead(group: group, account: account) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        do {
            let articleID = try articleField.uint32BE()
            let aggregate = try newsStore.setReaction(groupID: group.id, articleID: articleID,
                                                       accountID: account.id.uuidString.lowercased(),
                                                       reaction: reaction == 0 ? nil : reaction)
            let summary = try newsReactionSummariesWithUsers(groupID: group.id, articleID: articleID,
                                                             accountID: account.id.uuidString.lowercased(), summaries: aggregate)
            var fields = [LegacyTLV(type: 1, value: try LegacyPackedRecords.encodeNewsReactions(summary))]
            if let users = try? LegacyPackedRecords.encodeNewsReactionUsers(summary),
               users.count <= Int(UInt16.max) {
                fields.append(LegacyTLV(type: 2, value: users))
            }
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.forumArticleReactionSet,
                                                        transactionID: packet.transactionID, fields: fields))

            let changedEvent = LegacyPacket(command: LegacyCommand.forumArticleReactionChanged,
                                            transactionID: 0,
                                            fields: [
                                                LegacyTLV(type: 1, value: Self.macRoman(group.name)),
                                                LegacyTLV(type: 2, value: LegacyWire.uint32BE(articleID)),
                                            ])
            authenticatedSessions().forEach { recipient in
                guard recipient !== session,
                      !recipient.isLegacyTransport,
                      let recipientAccount = recipient.account,
                      canRead(group: group, account: recipientAccount) else { return }
                try? recipient.sendAuthenticated(changedEvent)
            }
            onNewsChanged?()
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func deleteForumPost(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let account = session.account,
              let groupData = packet.firstField(type: 1)?.value,
              let articleField = packet.firstField(type: 2),
              let group = configuredNewsgroup(named: groupData),
              canRead(group: group, account: account) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        do {
            let articleID = try articleField.uint32BE()
            guard try newsStore.softDelete(groupID: group.id, articleID: articleID,
                                           requesterAccountID: account.id,
                                           canModerate: account.permissions.contains(.manageNewsgroups)) else {
                try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
                return
            }
            try mediaStore.removeReferences(kind: .news, scope: group.id.uuidString.lowercased(),
                                            messageIDs: [String(articleID)])
            try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                        transactionID: packet.transactionID, fields: []))
            onNewsChanged?()
            log("News post \(articleID) deleted from \(group.name) by user \(session.userID.map(String.init) ?? "?")")
        } catch {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
        }
    }

    private func sendArticle(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let account = session.account,
              let groupData = packet.firstField(type: 1)?.value,
              let articleField = packet.firstField(type: 2),
              let group = configuredNewsgroup(named: groupData),
              canRead(group: group, account: account) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        let articleID = try articleField.uint32BE()
        guard let reply = try newsStore.legacyReply(groupID: group.id, groupName: groupData, articleID: articleID) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.newsgroupListReply,
                                                    transactionID: packet.transactionID,
                                                    fields: [
            LegacyTLV(type: 1, value: try reply.metadata.encoded()),
            LegacyTLV(type: 2, value: try reply.body.encoded()),
        ]))
    }

    private func deleteArticle(packet: LegacyPacket, session: LegacyServerSession) throws {
        guard let account = session.account,
              account.permissions.contains(.manageNewsgroups),
              let groupData = packet.firstField(type: 1)?.value,
              let articleField = packet.firstField(type: 2),
              let group = configuredNewsgroup(named: groupData) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        let articleID = try articleField.uint32BE()
        guard try newsStore.delete(groupID: group.id, articleID: articleID) else {
            try session.sendAuthenticated(Self.errorPacket(transactionID: packet.transactionID, code: 1))
            return
        }
        try synchronizeArticleCount(groupID: group.id)
        try session.sendAuthenticated(LegacyPacket(command: LegacyCommand.taskComplete,
                                                    transactionID: packet.transactionID,
                                                    fields: []))
        onStateChanged?()
        onNewsChanged?()
        log("Article \(articleID) deleted from \(group.name) by user \(session.userID.map(String.init) ?? "?")")
    }

    private func serveArticlePost(stream: LegacySocketTransferStream, access: LegacyTransferAccess) throws {
        let prefix = try stream.readPayload(4)
        var lengthCursor = LegacyByteCursor(prefix)
        let length = Int(try lengthCursor.readUInt32BE())
        guard length > 0, length <= LegacyNewsTransfer.maximumArticleReceiverPayload else {
            throw LegacyServerRuntimeError.protocolFailure("article-receiver payload length is invalid")
        }
        var wire = prefix
        wire.append(try stream.readPayload(length))
        let upload = try LegacyNewsTransfer.decodeArticleReceiverStream(wire)
        guard upload.group.count <= LegacyNewsTransfer.maximumGroupNameLength,
              let group = configuredNewsgroup(named: upload.group) else {
            throw LegacyServerRuntimeError.protocolFailure("article post permission denied or newsgroup unavailable")
        }
        let canModerate = access.account.permissions.contains(.manageNewsgroups)
        if upload.body.articleID == 0 {
            let mayPost = access.legacyTransport
                ? canPost(group: group, account: access.account)
                : (access.account.permissions.contains(.postNews) && canRead(group: group, account: access.account))
            guard mayPost else {
                throw LegacyServerRuntimeError.protocolFailure("article post permission denied or newsgroup unavailable")
            }
        }
        let now = Date()
        let classicDate = UInt32(min(max(0, now.timeIntervalSince1970 + Self.macEpochOffset), TimeInterval(UInt32.max)))
        let sender = access.nickname.isEmpty ? Self.macRoman(access.account.login) : access.nickname
        let parentArticleID = upload.body.reservedWord == LegacyArticle.noArticle ? nil : upload.body.reservedWord
        guard LegacyYouTubeReference.hasOnlyValidTokens(inWire: upload.body.text,
                                                        maximum: LegacyMediaTransfer.maximumYouTubeLinksPerNewsPost) else {
            throw LegacyServerRuntimeError.protocolFailure("invalid or excessive News YouTube references")
        }
        let mediaIDs = LegacyMediaReference.references(inWire: upload.body.text).map(\.id)
        guard mediaIDs.count <= LegacyMediaTransfer.maximumImagesPerNewsPost else {
            throw LegacyServerRuntimeError.protocolFailure("too many News media attachments")
        }
        if upload.body.articleID != 0 {
            let articleID = upload.body.articleID
            let existing = try newsStore.article(groupID: group.id, articleID: articleID)
            let ownsPost = existing?.ownerAccountID?.caseInsensitiveCompare(access.account.id.uuidString) == .orderedSame
            guard let existing, !existing.isDeleted, ownsPost || canModerate else {
                throw LegacyServerRuntimeError.protocolFailure("only the post owner or a News administrator can edit this News article")
            }
            let existingMediaIDs = Set(LegacyMediaReference.references(inWire: existing.body.text).map(\.id))
            let editedMediaIDs = Set(mediaIDs)
            guard editedMediaIDs.isSubset(of: existingMediaIDs) else {
                throw LegacyServerRuntimeError.protocolFailure("editing a News post cannot attach previously unrelated media")
            }
            let removedMediaIDs = existingMediaIDs.subtracting(editedMediaIDs)
            _ = try newsStore.updateOwned(groupID: group.id, articleID: articleID,
                                          ownerAccountID: access.account.id, canModerate: canModerate,
                                          subject: upload.subject, body: upload.body)
            let scope = group.id.uuidString.lowercased()
            for id in removedMediaIDs {
                if try mediaStore.removeReference(id: id, kind: .news, scope: scope, messageID: String(articleID)) {
                    broadcastMediaDeleted(id)
                }
            }
            onNewsChanged?()
            log("Article \(articleID) edited in \(group.name) by user \(access.userID); removed \(removedMediaIDs.count) media attachment(s)")
        } else {
            for id in mediaIDs where try !mediaStore.isOwned(id: id, by: access.account.id) {
                throw LegacyServerRuntimeError.protocolFailure("News media attachment is not owned by sender")
            }
            let stored = try newsStore.post(groupID: group.id, subject: upload.subject, sender: sender,
                                            date: classicDate, body: upload.body,
                                            parentArticleID: parentArticleID,
                                            ownerAccountID: access.account.id, createdAt: now)
            do {
                try mediaStore.bind(ids: mediaIDs, ownerAccountID: access.account.id, kind: .news,
                                    scope: group.id.uuidString.lowercased(), messageID: String(stored.articleID), expiresAt: nil)
            } catch {
                _ = try? newsStore.delete(groupID: group.id, articleID: stored.articleID)
                throw error
            }
            try synchronizeArticleCount(groupID: group.id)
            onStateChanged?()
            onNewsChanged?()
            log("Article \(stored.articleID) posted to \(group.name) by user \(access.userID)")
        }
        // Modern Carracho requires an authenticated success acknowledgement so a rejected
        // transfer can never be mistaken for a successful post merely because the socket closed.
        if !access.legacyTransport { try stream.sendPayload(Data([1])) }
    }

    private func synchronizeArticleCount(groupID: UUID) throws {
        try backend.updateNewsgroupArticleCounts([groupID: try newsStore.count(groupID: groupID)])
        try mediaStore.pruneNewsReferences(newsDatabaseURL: newsStore.databaseURL)
    }

    private func synchronizeNewsState() throws {
        let groups = backend.snapshot().newsgroups
        try newsStore.prune(validGroupIDs: Set(groups.map(\.id)))
        try mediaStore.pruneNewsReferences(newsDatabaseURL: newsStore.databaseURL)
        var counts: [UUID: UInt32] = [:]
        for group in groups { counts[group.id] = try newsStore.count(groupID: group.id) }
        try backend.updateNewsgroupArticleCounts(counts)
    }

    @discardableResult
    func runNewsExpiration(now: Date = Date()) throws -> Int {
        let groups = backend.snapshot().newsgroups
        var counts: [UUID: UInt32] = [:]
        var removed = 0
        for group in groups {
            removed += try newsStore.expire(groupID: group.id, expireAfterSeconds: group.expireAfterSeconds, now: now).count
            counts[group.id] = try newsStore.count(groupID: group.id)
        }
        try newsStore.prune(validGroupIDs: Set(groups.map(\.id)))
        try mediaStore.pruneNewsReferences(newsDatabaseURL: newsStore.databaseURL)
        try backend.updateNewsgroupArticleCounts(counts)
        if removed > 0 {
            onStateChanged?()
            onNewsChanged?()
            log("Expired \(removed) article\(removed == 1 ? "" : "s")")
        }
        return removed
    }

    func refreshNewsConfiguration() {
        do {
            try synchronizeNewsState()
            scheduleNextNewsExpiration()
            onStateChanged?()
            onNewsChanged?()
        } catch {
            log("Could not refresh News configuration: \(error.localizedDescription)")
        }
    }

    private func cancelNewsExpirationTimer() {
        newsTimerLock.lock()
        let timer = newsExpirationTimer
        newsExpirationTimer = nil
        newsTimerLock.unlock()
        timer?.cancel()
    }

    private func scheduleNextNewsExpiration() {
        cancelNewsExpirationTimer()
        guard status.isRunning else { return }
        let advanced = backend.snapshot().advanced
        let now = Date()
        var calendar = Calendar.current
        calendar.locale = Locale.current
        let components = DateComponents(hour: Int(advanced.newsExpirationHour),
                                        minute: Int(advanced.newsExpirationMinute), second: 0)
        guard let next = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) else { return }
        let delay = max(1, next.timeIntervalSince(now))
        let timer = DispatchSource.makeTimerSource(queue: newsExpirationQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do { _ = try self.runNewsExpiration(now: Date()) }
            catch { self.log("News expiration failed: \(error.localizedDescription)") }
            self.scheduleNextNewsExpiration()
        }
        newsTimerLock.lock()
        newsExpirationTimer = timer
        newsTimerLock.unlock()
        timer.resume()
    }

    private func cancelAutomaticSleepMonitor() {
        presenceTimerLock.lock()
        let timer = automaticSleepTimer
        automaticSleepTimer = nil
        presenceTimerLock.unlock()
        timer?.cancel()
    }

    private func scheduleAutomaticSleepMonitor() {
        cancelAutomaticSleepMonitor()
        guard status.isRunning else { return }
        let interval = min(1.0, max(0.1, automaticSleepAfter / 2.0))
        let timer = DispatchSource.makeTimerSource(queue: presenceMonitorQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.applyAutomaticSleepIfNeeded(now: Date()) }
        presenceTimerLock.lock()
        automaticSleepTimer = timer
        presenceTimerLock.unlock()
        timer.resume()
    }

    private func applyAutomaticSleepIfNeeded(now: Date) {
        var sleepers: [(UInt32, [LegacyServerSession])] = []
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        for (userID, session) in authenticatedByUserID where !session.sleeping {
            guard activeFileTransfersByUser[userID, default: 0] == 0 else { continue }
            if now.timeIntervalSince(session.lastActivityAt) >= automaticSleepAfter {
                session.sleeping = true
                sleepers.append((userID, authenticatedByUserID.values.filter { !$0.isLegacyTransport }))
            }
        }
        stateLock.unlock()
        for (userID, recipients) in sleepers {
            let event = LegacyPacket(command: LegacyCommand.userPresenceState, transactionID: 0, fields: [
                LegacyTLV(type: LegacyPresenceStateField.userID, value: LegacyWire.uint32BE(userID)),
                LegacyTLV(type: LegacyPresenceStateField.state, value: Data([LegacyPresenceState.sleeping])),
            ])
            recipients.forEach { try? $0.sendAuthenticated(event) }
        }
    }

    func refreshTrackerConfiguration() {
        cancelTrackerNotificationTimer()
        guard status.isRunning else { return }
        sendTrackerRegistration()
        let timer = DispatchSource.makeTimerSource(queue: trackerNotificationQueue)
        timer.schedule(deadline: .now() + .seconds(300), repeating: .seconds(300), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.sendTrackerRegistration() }
        trackerTimerLock.lock()
        trackerNotificationTimer = timer
        trackerTimerLock.unlock()
        timer.resume()
    }

    private func cancelTrackerNotificationTimer() {
        trackerTimerLock.lock()
        let timer = trackerNotificationTimer
        trackerNotificationTimer = nil
        trackerTimerLock.unlock()
        timer?.cancel()
    }

    private func sendTrackerRegistration() {
        let runtimeStatus = status
        guard runtimeStatus.isRunning, let port = runtimeStatus.port else { return }
        let state = backend.snapshot()
        let users = runtimeStatus.connectedClients
        trackerNotificationQueue.async { [weak self] in
            guard let self else { return }
            LegacyTrackerNotifier.notify(state: state, controlPort: port, users: users) { [weak self] message in
                self?.log(message)
            }
        }
    }

    private func serveNewsIndex(stream: LegacySocketTransferStream, access: LegacyTransferAccess) throws {
        let lengthData = try stream.readPayload(2)
        var lengthCursor = LegacyByteCursor(lengthData)
        let length = Int(try lengthCursor.readUInt16BE())
        guard length <= LegacyNewsTransfer.maximumGroupNameLength else {
            throw LegacyServerRuntimeError.protocolFailure("news-index group name exceeds limit")
        }
        let groupData = try stream.readPayload(length)
        guard let groupName = String(data: groupData, encoding: .macOSRoman),
              let group = backend.snapshot().newsgroups.first(where: {
                  $0.name.compare(groupName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
              }), canRead(group: group, account: access.account) else {
            try stream.sendPayload(try LegacyNewsTransfer.encodeIndexResponse(nil)); return
        }
        let index = try newsStore.legacyIndex(groupID: group.id, groupName: groupData)
        try stream.sendPayload(try LegacyNewsTransfer.encodeIndexResponse(try index.encoded()))
        log("News index served for user \(access.userID): \(groupName)")
    }

    private func canRead(group: ServerNewsgroup, account: ServerAccount) -> Bool {
        switch account.mode {
        case .administrator: return group.access.administratorsRead
        case .accountHolder: return group.access.accountHoldersRead
        case .guest: return group.access.guestsRead
        }
    }

    private func canPost(group: ServerNewsgroup, account: ServerAccount) -> Bool {
        switch account.mode {
        case .administrator: return group.access.administratorsPost
        case .accountHolder: return group.access.accountHoldersPost
        case .guest: return group.access.guestsPost
        }
    }
}

private enum LegacySocket {
    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif

    static func makeIPv4Listener(bindAddress: String, port: UInt16, backlog: Int32 = 64) throws -> Int32 {
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw socketError("socket") }
        do {
            var yes: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
                throw socketError("setsockopt(SO_REUSEADDR)")
            }
            #if canImport(Darwin)
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            #endif
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard bindAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
                throw LegacyServerRuntimeError.socket("invalid IPv4 bind address \(bindAddress)")
            }
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { throw socketError("bind") }
            guard listen(fd, backlog) == 0 else { throw socketError("listen") }
            return fd
        } catch {
            closeFD(fd)
            throw error
        }
    }

    static func makeListener(port: UInt16) throws -> Int32 {
        try makeIPv4Listener(bindAddress: "0.0.0.0", port: port)
    }

    static func makeListenerPair(controlPort requestedPort: UInt16) throws -> (controlFD: Int32, transferFD: Int32, controlPort: UInt16, transferPort: UInt16) {
        if requestedPort == UInt16.max {
            throw LegacyServerRuntimeError.socket("control port 65535 cannot have transfer port +1")
        }
        let attempts = requestedPort == 0 ? 64 : 1
        var lastError: Error?
        for _ in 0..<attempts {
            let controlFD: Int32
            do { controlFD = try makeListener(port: requestedPort) }
            catch { throw error }
            do {
                let actualControl = try localPort(fd: controlFD)
                guard actualControl < UInt16.max else {
                    shutdownAndClose(controlFD)
                    lastError = LegacyServerRuntimeError.socket("ephemeral control port 65535 cannot have transfer port +1")
                    continue
                }
                let transferPort = actualControl + 1
                let transferFD = try makeListener(port: transferPort)
                return (controlFD, transferFD, actualControl, transferPort)
            } catch {
                shutdownAndClose(controlFD)
                lastError = error
                if requestedPort != 0 { throw error }
            }
        }
        throw lastError ?? LegacyServerRuntimeError.socket("could not allocate adjacent control/transfer ports")
    }

    static func localPort(fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw socketError("getsockname") }
        return UInt16(bigEndian: address.sin_port)
    }

    static func accept(fd: Int32) throws -> (fd: Int32, peerIP: String) {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let clientFD = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                #if canImport(Darwin)
                return Darwin.accept(fd, address, &length)
                #else
                return Glibc.accept(fd, address, &length)
                #endif
            }
        }
        guard clientFD >= 0 else { throw socketError("accept") }
        var yes: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_KEEPALIVE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        // Keep idle-but-live users connected indefinitely, but detect peers that vanished without
        // a TCP FIN (crash, Wi-Fi loss, sleeping laptop, cable pull) within roughly two minutes.
        // This is deliberately transport liveness, not a user-idle timeout; the separate 5-minute
        // presence timer may mark a healthy quiet user as sleeping without disconnecting them.
        var keepaliveIdle: Int32 = 60
        var keepaliveInterval: Int32 = 15
        var keepaliveCount: Int32 = 4
        #if canImport(Darwin)
        _ = setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPALIVE, &keepaliveIdle, socklen_t(MemoryLayout.size(ofValue: keepaliveIdle)))
        _ = setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPINTVL, &keepaliveInterval, socklen_t(MemoryLayout.size(ofValue: keepaliveInterval)))
        _ = setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPCNT, &keepaliveCount, socklen_t(MemoryLayout.size(ofValue: keepaliveCount)))
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        #elseif canImport(Glibc)
        _ = setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPIDLE, &keepaliveIdle, socklen_t(MemoryLayout.size(ofValue: keepaliveIdle)))
        _ = setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPINTVL, &keepaliveInterval, socklen_t(MemoryLayout.size(ofValue: keepaliveInterval)))
        _ = setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPCNT, &keepaliveCount, socklen_t(MemoryLayout.size(ofValue: keepaliveCount)))
        #endif
        return (clientFD, peerAddress(storage))
    }

    static func setTimeouts(fd: Int32, seconds: Int) {
        var timeout = timeval()
        timeout.tv_sec = seconds
        timeout.tv_usec = 0
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    static func readAEADFrame(fd: Int32, maximumCiphertextLength: Int) throws -> Data {
        let header = try readExactly(fd: fd, count: CarrachoModernCrypto.frameHeaderLength)
        var cursor = LegacyByteCursor(header)
        let length = Int(try cursor.readUInt32BE())
        _ = try cursor.readUInt64BE()
        guard length >= 0, length <= maximumCiphertextLength else {
            throw LegacyServerRuntimeError.protocolFailure("invalid authenticated frame length \(length)")
        }
        var frame = header
        frame.append(try readExactly(fd: fd, count: length + CarrachoModernCrypto.tagLength))
        return frame
    }

    static func readControlFrame(fd: Int32) throws -> Data {
        let prefix = try readExactly(fd: fd, count: 4)
        var cursor = LegacyByteCursor(prefix)
        let length = Int(try cursor.readUInt32BE())
        guard length > 0, length.isMultiple(of: 8), length <= LegacyControlCodec.maximumCiphertextLength else {
            throw LegacyServerRuntimeError.protocolFailure("invalid encrypted control-frame length \(length)")
        }
        var frame = prefix
        frame.append(try readExactly(fd: fd, count: length))
        return frame
    }

    static func readSome(fd: Int32, maximum: Int) throws -> Data {
        guard maximum > 0 else { return Data() }
        var result = Data(count: maximum)
        let count = try result.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            while true {
                let n = platformRecv(fd, base, maximum)
                if n == 0 { throw LegacyServerRuntimeError.stopped }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw socketError("recv")
                }
                return n
            }
        }
        result.count = count
        return result
    }

    static func readExactly(fd: Int32, count: Int) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < count {
                let n = platformRecv(fd, base.advanced(by: offset), count - offset)
                if n == 0 { throw LegacyServerRuntimeError.stopped }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw socketError("recv")
                }
                offset += n
            }
        }
        return result
    }

    static func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let n = platformSend(fd, base.advanced(by: offset), data.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw socketError("send")
                }
                if n == 0 { throw LegacyServerRuntimeError.stopped }
                offset += n
            }
        }
    }

    static func interrupt(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = shutdown(fd, Int32(SHUT_RDWR))
    }

    static func shutdownAndClose(_ fd: Int32) {
        guard fd >= 0 else { return }
        interrupt(fd)
        closeFD(fd)
    }

    private static func peerAddress(_ storage: sockaddr_storage) -> String {
        var copy = storage
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return withUnsafePointer(to: &copy) { pointer -> String in
            if Int32(storage.ss_family) == AF_INET {
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                    var addr = p.pointee.sin_addr
                    guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else { return "unknown" }
                    return String(cString: buffer)
                }
            }
            if Int32(storage.ss_family) == AF_INET6 {
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                    var addr = p.pointee.sin6_addr
                    guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else { return "unknown" }
                    return String(cString: buffer)
                }
            }
            return "unknown"
        }
    }

    private static func socketError(_ operation: String) -> LegacyServerRuntimeError {
        LegacyServerRuntimeError.socket("\(operation): \(String(cString: strerror(errno)))")
    }

    private static func platformRecv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.recv(fd, buffer, count, 0)
        #else
        return Glibc.recv(fd, buffer, count, 0)
        #endif
    }

    private static func platformSend(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.send(fd, buffer, count, 0)
        #else
        return Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
        #endif
    }

    private static func closeFD(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }
}
