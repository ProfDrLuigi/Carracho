#if CARRACHO_SERVER
import Foundation

struct CarrachoServerTrackerConfiguration: Codable, Equatable {
    var enabled: Bool = false
    var port: UInt16 = LegacyTrackerProtocol.port
}

struct CarrachoHTTPAdminConfiguration: Codable, Equatable {
    var enabled: Bool = false
    var bind: String = "127.0.0.1"
    var port: UInt16 = 6780
    var token: String?
}

/// Startup/runtime configuration shared with the native Linux server. The JSON file is
/// authoritative for these fields whenever the standalone server starts or restarts.
struct CarrachoServerConfiguration: Codable, Equatable {
    var serverName: String = "Carracho Server"
    var description: String = ""
    var serverPort: UInt16 = 6700
    var filesRoot: String = "../Files"
    var legacyFilesRoot: String = ""
    var authenticationMode: ServerAuthenticationMode = .legacyCompatible
    var maxConnections: UInt16 = 100
    var maxConnectionsPerIP: UInt16 = 5
    var maxSimultaneousFileTransfers: UInt16 = 20
    var maxFileTransfersPerUser: UInt16 = 1
    var maxFolderDownloadDepth: UInt16 = 8
    var uploadBandwidthLimitBytesPerSecond: UInt64 = 0
    var searchIndexExclusions: [String] = []
    var searchIndexRebuildIntervalHours: UInt32 = 0
    var httpAdmin = CarrachoHTTPAdminConfiguration()
    var newsExpirationHour: UInt8 = 0
    var newsExpirationMinute: UInt8 = 0

    private enum CodingKeys: String, CodingKey {
        case serverName, description, serverPort, filesRoot, legacyFilesRoot, authenticationMode
        case maxConnections, maxConnectionsPerIP, maxSimultaneousFileTransfers
        case maxFileTransfersPerUser, maxFolderDownloadDepth
        case uploadBandwidthLimitBytesPerSecond, searchIndexExclusions, searchIndexRebuildIntervalHours
        case httpAdmin, newsExpirationHour, newsExpirationMinute
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverName = try values.decodeIfPresent(String.self, forKey: .serverName) ?? "Carracho Server"
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        serverPort = try values.decodeIfPresent(UInt16.self, forKey: .serverPort) ?? 6700
        filesRoot = try values.decodeIfPresent(String.self, forKey: .filesRoot) ?? "../Files"
        legacyFilesRoot = try values.decodeIfPresent(String.self, forKey: .legacyFilesRoot) ?? ""
        authenticationMode = try values.decodeIfPresent(ServerAuthenticationMode.self, forKey: .authenticationMode) ?? .legacyCompatible
        maxConnections = try values.decodeIfPresent(UInt16.self, forKey: .maxConnections) ?? 100
        maxConnectionsPerIP = try values.decodeIfPresent(UInt16.self, forKey: .maxConnectionsPerIP) ?? 5
        maxSimultaneousFileTransfers = try values.decodeIfPresent(UInt16.self, forKey: .maxSimultaneousFileTransfers) ?? 20
        maxFileTransfersPerUser = try values.decodeIfPresent(UInt16.self, forKey: .maxFileTransfersPerUser) ?? 1
        maxFolderDownloadDepth = try values.decodeIfPresent(UInt16.self, forKey: .maxFolderDownloadDepth) ?? 8
        uploadBandwidthLimitBytesPerSecond = try values.decodeIfPresent(UInt64.self, forKey: .uploadBandwidthLimitBytesPerSecond) ?? 0
        searchIndexExclusions = try values.decodeIfPresent([String].self, forKey: .searchIndexExclusions) ?? []
        searchIndexRebuildIntervalHours = try values.decodeIfPresent(UInt32.self, forKey: .searchIndexRebuildIntervalHours) ?? 0
        httpAdmin = try values.decodeIfPresent(CarrachoHTTPAdminConfiguration.self, forKey: .httpAdmin) ?? CarrachoHTTPAdminConfiguration()
        newsExpirationHour = try values.decodeIfPresent(UInt8.self, forKey: .newsExpirationHour) ?? 0
        newsExpirationMinute = try values.decodeIfPresent(UInt8.self, forKey: .newsExpirationMinute) ?? 0
    }
}

/// Standalone service layer used by the dedicated “Carracho Server” app target.
/// macOS and Linux intentionally use the same config keys and the same fixed database
/// filenames (`server.db`, `news.db`, `media.db` and `file-index.db`).
final class CarrachoServerService {
    private struct LegacyFileRootConfiguration: Codable {
        var path: String
    }

    let rootURL: URL
    let databaseURL: URL
    private(set) var filesURL: URL
    let backend: ModernServerBackend
    let runtime: LegacyServerRuntime
    let botController: CarrachoServerBotController
    let trackerRuntime: LegacyTrackerRuntime
    private(set) var configuration: CarrachoServerConfiguration
    private(set) var trackerConfiguration: CarrachoServerTrackerConfiguration

    init(rootURL: URL = CarrachoServerService.defaultRootURL(), defaultBannerPNG: Data? = nil) throws {
        let resolvedRoot = rootURL.standardizedFileURL
        try Self.migrateLegacyDatabaseLayout(rootURL: resolvedRoot)
        let databaseRoot = Self.databaseDirectoryURL(rootURL: resolvedRoot)
        let databaseURL = databaseRoot.appendingPathComponent("server.db", isDirectory: false)
        let databaseExisted = FileManager.default.fileExists(atPath: databaseURL.path)
        let backend = try ModernServerBackend(store: ServerStateStore(url: databaseURL))
        // The Bot is a persisted, normally editable account, but can only ever be used by the
        // local in-process Bot controller. Provision it before runtime/config reconciliation.
        try backend.ensureLocalBotAccount()
        if !databaseExisted, let defaultBannerPNG, !defaultBannerPNG.isEmpty {
            try backend.updateServerState { state in
                // Bootstrap only. Existing servers, including ones whose administrator
                // deliberately removed the banner, are never repopulated here.
                if state.identity.bannerData == nil { state.identity.bannerData = defaultBannerPNG }
            }
        }
        let configuration = try Self.loadOrCreateConfiguration(
            rootURL: resolvedRoot,
            state: backend.snapshot(),
            databaseExisted: databaseExisted
        )
        let filesURL = try Self.resolveFilesURL(configuration.filesRoot, rootURL: resolvedRoot)
        try Self.reconcile(configuration: configuration, filesURL: filesURL, rootURL: resolvedRoot, backend: backend)

        self.rootURL = resolvedRoot
        self.databaseURL = databaseURL
        self.filesURL = filesURL
        self.backend = backend
        let runtime = LegacyServerRuntime(backend: backend, storageRoot: filesURL, supportRoot: resolvedRoot,
                                          databaseRoot: databaseRoot)
        self.runtime = runtime
        self.botController = CarrachoServerBotController(rootURL: resolvedRoot, runtime: runtime)
        self.runtime.configureDownloadBandwidthLimit(configuration.uploadBandwidthLimitBytesPerSecond)
        try self.runtime.configureHTTPAdministration(enabled: configuration.httpAdmin.enabled,
                                                     bindAddress: configuration.httpAdmin.bind,
                                                     port: configuration.httpAdmin.port,
                                                     token: Self.effectiveHTTPAdminToken(configuration))
        self.trackerRuntime = LegacyTrackerRuntime()
        self.configuration = configuration
        self.trackerConfiguration = Self.loadTrackerConfiguration(rootURL: resolvedRoot)
    }

    deinit {
        if runtime.status.isRunning { botController.serverWillStop() }
        runtime.stop()
        trackerRuntime.stop()
    }

    static func defaultRootURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        return base.appendingPathComponent("Carracho", isDirectory: true)
            .appendingPathComponent("Server", isDirectory: true)
    }

    static func defaultFilesURL(rootURL: URL) -> URL {
        rootURL.standardizedFileURL.appendingPathComponent("Files", isDirectory: true)
    }

    static func databaseDirectoryURL(rootURL: URL) -> URL {
        rootURL.standardizedFileURL.appendingPathComponent("db", isDirectory: true)
    }

    private static func migrateLegacyDatabaseLayout(rootURL: URL) throws {
        let manager = FileManager.default
        let root = rootURL.standardizedFileURL
        let databaseRoot = databaseDirectoryURL(rootURL: root)
        try manager.createDirectory(at: databaseRoot, withIntermediateDirectories: true)
        for name in ["server.db", "server.db-wal", "server.db-shm",
                     "news.db", "news.db-wal", "news.db-shm",
                     "media.db", "media.db-wal", "media.db-shm",
                     "file-index.db", "file-index.db-wal", "file-index.db-shm"] {
            let oldURL = root.appendingPathComponent(name, isDirectory: false)
            let newURL = databaseRoot.appendingPathComponent(name, isDirectory: false)
            guard manager.fileExists(atPath: oldURL.path), !manager.fileExists(atPath: newURL.path) else { continue }
            try manager.moveItem(at: oldURL, to: newURL)
        }
    }

    static func configurationURL(rootURL: URL) -> URL {
        rootURL.standardizedFileURL
            .appendingPathComponent("etc", isDirectory: true)
            .appendingPathComponent("carracho-server.json", isDirectory: false)
    }

    private static func legacyFileRootConfigurationURL(rootURL: URL) -> URL {
        rootURL.standardizedFileURL.appendingPathComponent("file-root.json", isDirectory: false)
    }

    private static func initialConfiguration(rootURL: URL, state: ServerState, databaseExisted: Bool) -> CarrachoServerConfiguration {
        var configuration = CarrachoServerConfiguration()
        guard databaseExisted else {
            if let legacy = loadLegacyFilesRoot(rootURL: rootURL) { configuration.filesRoot = legacy.path }
            return configuration
        }

        configuration.serverName = state.identity.name
        configuration.description = state.identity.description
        configuration.serverPort = state.advanced.controlPort
        configuration.authenticationMode = state.authentication.mode
        configuration.maxConnections = state.advanced.maxConnections
        configuration.maxConnectionsPerIP = state.advanced.maxConnectionsPerIP
        configuration.maxSimultaneousFileTransfers = state.advanced.maxSimultaneousFileTransfers
        configuration.maxFileTransfersPerUser = state.advanced.maxFileTransfersPerUser
        configuration.maxFolderDownloadDepth = state.advanced.maxFolderDownloadDepth
        configuration.newsExpirationHour = state.advanced.newsExpirationHour
        configuration.newsExpirationMinute = state.advanced.newsExpirationMinute
        configuration.uploadBandwidthLimitBytesPerSecond = state.runtime.uploadBandwidthLimitBytesPerSecond
        configuration.searchIndexExclusions = state.runtime.searchIndexExclusions
        configuration.searchIndexRebuildIntervalHours = state.runtime.searchIndexRebuildIntervalHours
        configuration.legacyFilesRoot = state.runtime.legacyFilesRoot
        if !state.runtime.filesRoot.isEmpty {
            configuration.filesRoot = state.runtime.filesRoot
        } else if let legacy = loadLegacyFilesRoot(rootURL: rootURL) {
            configuration.filesRoot = legacy.path
        }
        return configuration
    }

    private static func loadLegacyFilesRoot(rootURL: URL) -> LegacyFileRootConfiguration? {
        let url = legacyFileRootConfigurationURL(rootURL: rootURL)
        guard let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(LegacyFileRootConfiguration.self, from: data),
              !configuration.path.isEmpty else { return nil }
        return configuration
    }

    private static func loadOrCreateConfiguration(rootURL: URL, state: ServerState,
                                                  databaseExisted: Bool) throws -> CarrachoServerConfiguration {
        let url = configurationURL(rootURL: rootURL)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            var configuration = try JSONDecoder().decode(CarrachoServerConfiguration.self, from: data)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            var migrated = false
            if object?["serverName"] == nil { configuration.serverName = state.identity.name; migrated = true }
            if object?["description"] == nil { configuration.description = state.identity.description; migrated = true }
            try validate(configuration)
            try secureConfigurationPermissions(url)
            if migrated { try saveConfiguration(configuration, rootURL: rootURL) }
            if object?["trackerRegistration"] == nil {
                try persistTrackerRegistrationMirror(state: state, rootURL: rootURL)
            }
            return configuration
        }
        let configuration = initialConfiguration(rootURL: rootURL, state: state, databaseExisted: databaseExisted)
        try saveConfiguration(configuration, rootURL: rootURL)
        try persistTrackerRegistrationMirror(state: state, rootURL: rootURL)
        return configuration
    }

    private static func loadConfiguration(rootURL: URL) throws -> CarrachoServerConfiguration {
        let url = configurationURL(rootURL: rootURL)
        let data = try Data(contentsOf: url)
        let configuration = try JSONDecoder().decode(CarrachoServerConfiguration.self, from: data)
        try validate(configuration)
        try secureConfigurationPermissions(url)
        return configuration
    }

    private static func secureConfigurationPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func saveConfiguration(_ configuration: CarrachoServerConfiguration, rootURL: URL) throws {
        try validate(configuration)
        let url = configurationURL(rootURL: rootURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(configuration).write(to: url, options: .atomic)
        // This file may contain the HTTP administration bearer token. Keep it private to
        // the configured server user; the LaunchDaemon runs as that same user.
        try secureConfigurationPermissions(url)
    }

    private static func persistTrackerRegistrationMirror(state: ServerState, rootURL: URL) throws {
        let url = configurationURL(rootURL: rootURL)
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerStateError.invalidValue(L("carracho-server.json is not a JSON object."))
        }
        let flags = state.advanced.trackerAdvertisementFlags
        let bandwidthCode = UInt8((flags >> 24) & 0xff)
        let bandwidthTitle = LegacyTrackerProtocol.bandwidthTitle(for: bandwidthCode)
            ?? (bandwidthCode == 0 ? "Not specified" : "Unknown (code \(bandwidthCode))")
        object["trackerRegistration"] = [
            "enabled": (flags & LegacyTrackerProtocol.registeredFlag) != 0,
            "private": (flags & LegacyTrackerProtocol.privateFlag) != 0,
            "bandwidthCode": Int(bandwidthCode),
            "bandwidth": bandwidthTitle,
            "flags": NSNumber(value: flags),
            "description": state.advanced.trackerDescription,
            "trackers": state.advanced.trackers.map { tracker in
                ["name": tracker.name, "address": tracker.address,
                 "enabled": tracker.isRegistrationEnabled,
                 "reservedString": tracker.reservedString, "reservedValue": NSNumber(value: tracker.reservedValue)] as [String: Any]
            },
        ] as [String: Any]
        let updated = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try updated.write(to: url, options: .atomic)
        try secureConfigurationPermissions(url)
    }

    private static func effectiveHTTPAdminToken(_ configuration: CarrachoServerConfiguration) -> String {
        let environment = ProcessInfo.processInfo.environment["CARRACHO_HTTP_ADMIN_TOKEN"] ?? ""
        return environment.isEmpty ? (configuration.httpAdmin.token ?? "") : environment
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isNumber }),
                  let number = UInt16(part), number <= 255 else { return false }
            return String(number) == part || part == "0"
        }
    }

    private static func validate(_ configuration: CarrachoServerConfiguration) throws {
        guard !configuration.serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              configuration.serverName.utf8.count <= 255 else {
            throw ServerStateError.invalidValue(L("serverName must contain 1 to 255 UTF-8 bytes."))
        }
        guard configuration.description.utf8.count <= 16_384 else {
            throw ServerStateError.invalidValue(L("description must not exceed 16384 UTF-8 bytes."))
        }
        guard configuration.serverPort > 0, configuration.serverPort < UInt16.max else {
            throw ServerStateError.invalidValue(L("Server port must be between 1 and 65534 because transfers use port +1."))
        }
        guard !configuration.filesRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerStateError.invalidValue(L("filesRoot must not be empty."))
        }
        guard configuration.legacyFilesRoot.utf8.count < 4096 else {
            throw ServerStateError.invalidValue(L("legacyFilesRoot path is too long."))
        }
        guard isIPv4Address(configuration.httpAdmin.bind), configuration.httpAdmin.port > 0 else {
            throw ServerStateError.invalidValue(L("httpAdmin.bind must be an IPv4 address and httpAdmin.port must be between 1 and 65535."))
        }
        if configuration.httpAdmin.enabled {
            guard effectiveHTTPAdminToken(configuration).utf8.count >= 24 else {
                throw ServerStateError.invalidValue(L("Enabled httpAdmin requires a token of at least 24 UTF-8 bytes or CARRACHO_HTTP_ADMIN_TOKEN."))
            }
        }
        guard configuration.maxConnections > 0, configuration.maxConnectionsPerIP > 0,
              configuration.maxSimultaneousFileTransfers > 0, configuration.maxFileTransfersPerUser > 0 else {
            throw ServerStateError.invalidValue(L("Connection and transfer limits in carracho-server.json must be greater than zero."))
        }
        _ = try LegacyServerSettingField.encodeSearchIndexExclusions(configuration.searchIndexExclusions)
        guard configuration.newsExpirationHour < 24, configuration.newsExpirationMinute < 60 else {
            throw ServerStateError.invalidValue(L("News expiration time in carracho-server.json is invalid."))
        }
    }

    private static func resolveFilesURL(_ configuredPath: String, rootURL: URL) throws -> URL {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerStateError.invalidValue(L("filesRoot must not be empty.")) }
        if NSString(string: trimmed).isAbsolutePath {
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        }
        let etcURL = configurationURL(rootURL: rootURL).deletingLastPathComponent()
        return etcURL.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
    }

    private static func reconcile(configuration: CarrachoServerConfiguration, filesURL: URL, rootURL: URL,
                                  backend: ModernServerBackend) throws {
        let previous = backend.snapshot()
        var identity = previous.identity
        identity.name = configuration.serverName
        identity.description = configuration.description
        var advanced = previous.advanced
        advanced.controlPort = configuration.serverPort
        advanced.maxConnections = configuration.maxConnections
        advanced.maxConnectionsPerIP = configuration.maxConnectionsPerIP
        advanced.maxSimultaneousFileTransfers = configuration.maxSimultaneousFileTransfers
        advanced.maxFileTransfersPerUser = configuration.maxFileTransfersPerUser
        advanced.maxFolderDownloadDepth = configuration.maxFolderDownloadDepth
        advanced.newsExpirationHour = configuration.newsExpirationHour
        advanced.newsExpirationMinute = configuration.newsExpirationMinute
        let legacyFilesURL = configuration.legacyFilesRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : try resolveFilesURL(configuration.legacyFilesRoot, rootURL: rootURL)
        let runtime = ServerRuntimeSettings(
            filesRoot: filesURL.standardizedFileURL.path,
            legacyFilesRoot: legacyFilesURL?.standardizedFileURL.path ?? "",
            uploadBandwidthLimitBytesPerSecond: configuration.uploadBandwidthLimitBytesPerSecond,
            searchIndexExclusions: configuration.searchIndexExclusions,
            searchIndexRebuildIntervalHours: configuration.searchIndexRebuildIntervalHours
        )
        guard identity != previous.identity || advanced != previous.advanced || runtime != previous.runtime ||
                configuration.authenticationMode != previous.authentication.mode else { return }
        try backend.reconcileStartupConfiguration(
            identity: identity,
            advanced: advanced,
            authenticationMode: configuration.authenticationMode,
            runtime: runtime
        )
    }

    private func reloadConfigurationAndReconcile() throws {
        let latest = try Self.loadConfiguration(rootURL: rootURL)
        let latestFilesURL = try Self.resolveFilesURL(latest.filesRoot, rootURL: rootURL)
        try Self.reconcile(configuration: latest, filesURL: latestFilesURL, rootURL: rootURL, backend: backend)
        try runtime.configureStorageRoot(latestFilesURL)
        runtime.configureDownloadBandwidthLimit(latest.uploadBandwidthLimitBytesPerSecond)
        try runtime.configureHTTPAdministration(enabled: latest.httpAdmin.enabled,
                                                bindAddress: latest.httpAdmin.bind,
                                                port: latest.httpAdmin.port,
                                                token: Self.effectiveHTTPAdminToken(latest))
        configuration = latest
        filesURL = latestFilesURL
    }

    private static func trackerConfigurationURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent("tracker-runtime.json", isDirectory: false)
    }

    private static func loadTrackerConfiguration(rootURL: URL) -> CarrachoServerTrackerConfiguration {
        let url = trackerConfigurationURL(rootURL: rootURL)
        guard let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(CarrachoServerTrackerConfiguration.self, from: data),
              configuration.port > 0 else {
            return CarrachoServerTrackerConfiguration()
        }
        return configuration
    }

    private static func saveTrackerConfiguration(_ configuration: CarrachoServerTrackerConfiguration, rootURL: URL) throws {
        guard configuration.port > 0 else {
            throw ServerStateError.invalidValue(L("The tracker port must be between 1 and 65535."))
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: trackerConfigurationURL(rootURL: rootURL), options: .atomic)
    }

    var status: LegacyServerRuntimeStatus { runtime.status }
    var trackerStatus: LegacyTrackerRuntimeStatus { trackerRuntime.status }
    var serverState: ServerState { backend.snapshot() }
    var httpAdminConfiguration: CarrachoHTTPAdminConfiguration { configuration.httpAdmin }
    var httpAdminEnvironmentTokenActive: Bool {
        !(ProcessInfo.processInfo.environment["CARRACHO_HTTP_ADMIN_TOKEN"] ?? "").isEmpty
    }

    func updateServerPort(_ port: UInt16) throws {
        guard port > 0, port < UInt16.max else {
            throw ServerStateError.invalidValue(L("Server port must be between 1 and 65534 because transfers use port +1."))
        }
        var latest = try Self.loadConfiguration(rootURL: rootURL)
        guard latest.serverPort != port else { return }
        latest.serverPort = port
        try Self.saveConfiguration(latest, rootURL: rootURL)
        let wasRunning = runtime.status.isRunning
        if wasRunning { runtime.stop() }
        try reloadConfigurationAndReconcile()
        if wasRunning { _ = try runtime.start() }
    }

    func updateHTTPAdminConfiguration(_ value: CarrachoHTTPAdminConfiguration) throws {
        var latest = try Self.loadConfiguration(rootURL: rootURL)
        guard latest.httpAdmin != value else { return }
        latest.httpAdmin = value
        try Self.validate(latest)

        if value.enabled {
            let control = latest.serverPort
            let transfer = control < UInt16.max ? control + 1 : UInt16.max
            guard value.port != control, value.port != transfer else {
                throw ServerStateError.invalidValue(L("The HTTP administration port must differ from the server control and transfer ports."))
            }
            guard value.port != trackerConfiguration.port else {
                throw ServerStateError.invalidValue(L("The HTTP administration port must differ from the configured tracker port."))
            }
        }

        let previous = configuration
        let wasRunning = runtime.status.isRunning
        try Self.saveConfiguration(latest, rootURL: rootURL)
        if wasRunning { runtime.stop() }

        do {
            try reloadConfigurationAndReconcile()
            if wasRunning { _ = try runtime.start() }
        } catch {
            // A bad bind address/port can still fail at socket-open time. Restore the previously
            // working configuration and listener instead of leaving a saved-but-dead server.
            try? Self.saveConfiguration(previous, rootURL: rootURL)
            try? reloadConfigurationAndReconcile()
            if wasRunning, !runtime.status.isRunning { _ = try? runtime.start() }
            throw error
        }
    }

    func updateFilesRoot(_ filesURL: URL) throws {
        guard !runtime.status.isRunning else {
            throw ServerStateError.invalidValue(L("Stop the server before changing filesRoot."))
        }
        var latest = try Self.loadConfiguration(rootURL: rootURL)
        latest.filesRoot = filesURL.standardizedFileURL.path
        try Self.saveConfiguration(latest, rootURL: rootURL)
        try reloadConfigurationAndReconcile()
    }

    var legacyFilesURL: URL? {
        let path = backend.snapshot().runtime.legacyFilesRoot
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    func updateLegacyFilesRoot(_ filesURL: URL?) throws {
        guard !runtime.status.isRunning else {
            throw ServerStateError.invalidValue(L("Stop the server before changing legacyFilesRoot."))
        }
        var latest = try Self.loadConfiguration(rootURL: rootURL)
        latest.legacyFilesRoot = filesURL?.standardizedFileURL.path ?? ""
        try Self.saveConfiguration(latest, rootURL: rootURL)
        try reloadConfigurationAndReconcile()
    }

    @discardableResult
    func startConfiguredTracker() throws -> UInt16? {
        guard trackerConfiguration.enabled else { return nil }
        if trackerRuntime.status.isRunning { return trackerRuntime.status.port }
        return try trackerRuntime.start(port: trackerConfiguration.port)
    }

    func setTrackerEnabled(_ enabled: Bool, manageRuntime: Bool = true) throws {
        guard trackerConfiguration.enabled != enabled else {
            if manageRuntime {
                if enabled && !trackerRuntime.status.isRunning { _ = try startConfiguredTracker() }
                else if !enabled && trackerRuntime.status.isRunning { trackerRuntime.stop() }
            }
            return
        }
        if enabled {
            if manageRuntime {
                let port = trackerConfiguration.port
                _ = try trackerRuntime.start(port: port)
            }
            do {
                var configuration = trackerConfiguration
                configuration.enabled = true
                try Self.saveTrackerConfiguration(configuration, rootURL: rootURL)
                trackerConfiguration = configuration
            } catch {
                if manageRuntime { trackerRuntime.stop() }
                throw error
            }
        } else {
            var configuration = trackerConfiguration
            configuration.enabled = false
            try Self.saveTrackerConfiguration(configuration, rootURL: rootURL)
            trackerConfiguration = configuration
            if manageRuntime { trackerRuntime.stop() }
        }
    }

    func setTrackerPort(_ port: UInt16) throws {
        guard port > 0 else {
            throw ServerStateError.invalidValue(L("The tracker port must be between 1 and 65535."))
        }
        guard !trackerRuntime.status.isRunning else {
            throw ServerStateError.invalidValue(L("Stop the built-in tracker before changing its port."))
        }
        var configuration = trackerConfiguration
        configuration.port = port
        try Self.saveTrackerConfiguration(configuration, rootURL: rootURL)
        trackerConfiguration = configuration
    }

    func shutdown() {
        if runtime.status.isRunning { botController.serverWillStop() }
        runtime.stop()
        trackerRuntime.stop()
    }

    var botDesiredEnabled: Bool {
        CarrachoServerBotController.desiredEnabled(rootURL: rootURL)
    }

    var botInterfaceURL: URL { botController.pipeURL }

    var botAvatarURL: URL { CarrachoServerBotAvatar.url(rootURL: rootURL) }

    var botAvatarData: Data? {
        if let path = CarrachoServerBotController.configuredAvatarPath(rootURL: rootURL) {
            guard !path.isEmpty else { return nil }
            return CarrachoServerBotController.configuredAvatarData(rootURL: rootURL)
        }
        return backend.localBotAccount()?.picture
    }

    func setBotAvatar(_ data: Data?) throws {
        try CarrachoServerBotController.setAvatarData(data, rootURL: rootURL)
        try runtime.updateLocalBotAvatar(data)
        botController.desiredStateChanged()
    }

    var botGreetingConfiguration: (enabled: Bool, template: String) {
        CarrachoServerBotController.greetingConfiguration(rootURL: rootURL)
    }

    func setBotGreeting(enabled: Bool, template: String) throws {
        try CarrachoServerBotController.setGreeting(enabled: enabled, template: template, rootURL: rootURL)
        botController.desiredStateChanged()
    }

    var botStatus: CarrachoServerBotStatus? {
        CarrachoServerBotController.currentStatus(rootURL: rootURL)
    }

    func setBotEnabled(_ enabled: Bool) throws {
        try CarrachoServerBotController.setDesiredEnabled(enabled, rootURL: rootURL)
        botController.desiredStateChanged()
    }

    var administratorAccount: ServerAccount? {
        let accounts = backend.snapshot().accounts
        return accounts.first {
            $0.mode == .administrator && $0.login.caseInsensitiveCompare("admin") == .orderedSame
        } ?? accounts.first { $0.mode == .administrator }
    }

    var suggestedAdministratorLogin: String {
        let accounts = backend.snapshot().accounts
        func available(_ candidate: String) -> Bool {
            !accounts.contains { $0.login.compare(candidate, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        if available("admin") { return "admin" }
        if available("administrator") { return "administrator" }
        var suffix = 2
        while !available("admin\(suffix)") { suffix += 1 }
        return "admin\(suffix)"
    }

    @discardableResult
    func createAdministrator(login: String, name: String, password: String) throws -> ServerAccount {
        guard administratorAccount == nil else {
            throw ServerStateError.invalidValue(L("An administrator account already exists."))
        }
        let normalizedLogin = login.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLogin.isEmpty else {
            throw ServerStateError.invalidValue(L("The administrator login must not be empty."))
        }
        guard !password.isEmpty else {
            throw ServerStateError.invalidValue(L("The administrator password must not be empty."))
        }
        return try backend.createAccount(
            ServerAccount(login: normalizedLogin,
                          name: normalizedName.isEmpty ? "Administrator" : normalizedName,
                          mode: .administrator,
                          permissions: Set(ServerPermission.allCases)),
            password: password
        )
    }

    @discardableResult
    func start(port: UInt16? = nil) throws -> UInt16 {
        try reloadConfigurationAndReconcile()
        let boundPort = try runtime.start(port: port)
        botController.serverDidStart()
        return boundPort
    }

    func stop() {
        if runtime.status.isRunning { botController.serverWillStop() }
        runtime.stop()
    }

    @discardableResult
    func changeAdministratorPassword(to newPassword: String) throws -> ServerAccount {
        guard !newPassword.isEmpty else {
            throw ServerStateError.invalidValue(L("The administrator password must not be empty."))
        }
        guard let account = administratorAccount else {
            throw ServerStateError.invalidValue(L("No administrator account exists in the server database."))
        }
        return try backend.updateAccount(id: account.id, with: account, newPassword: newPassword)
    }
}
#endif
