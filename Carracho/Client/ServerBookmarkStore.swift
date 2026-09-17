import Foundation

struct ServerBookmark: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var login: String
    var nickname: String
    var statusMessage: String
    var autoReconnect: Bool
    var connectAtLaunch: Bool
    var acceptsOfflineMessages: Bool

    init(id: UUID = UUID(), name: String, host: String, port: UInt16,
         login: String, nickname: String, statusMessage: String = "", autoReconnect: Bool = false,
         connectAtLaunch: Bool = false, acceptsOfflineMessages: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.login = login
        self.nickname = nickname
        self.statusMessage = statusMessage
        self.autoReconnect = autoReconnect
        self.connectAtLaunch = connectAtLaunch
        self.acceptsOfflineMessages = acceptsOfflineMessages
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, login, nickname, statusMessage, autoReconnect, connectAtLaunch, acceptsOfflineMessages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        login = try container.decode(String.self, forKey: .login)
        nickname = try container.decode(String.self, forKey: .nickname)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage) ?? ""
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
        connectAtLaunch = try container.decodeIfPresent(Bool.self, forKey: .connectAtLaunch) ?? false
        acceptsOfflineMessages = try container.decodeIfPresent(Bool.self, forKey: .acceptsOfflineMessages) ?? true
    }
}

struct ServerBookmarkPortableEntry: Codable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var login: String
    var nickname: String
    var statusMessage: String
    var password: String
    var autoReconnect: Bool
    var connectAtLaunch: Bool
    var acceptsOfflineMessages: Bool

    init(id: UUID, name: String, host: String, port: UInt16, login: String,
         nickname: String, statusMessage: String = "", password: String, autoReconnect: Bool = false,
         connectAtLaunch: Bool = false, acceptsOfflineMessages: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.login = login
        self.nickname = nickname
        self.statusMessage = statusMessage
        self.password = password
        self.autoReconnect = autoReconnect
        self.connectAtLaunch = connectAtLaunch
        self.acceptsOfflineMessages = acceptsOfflineMessages
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, login, nickname, statusMessage, password, autoReconnect, connectAtLaunch, acceptsOfflineMessages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        login = try container.decode(String.self, forKey: .login)
        nickname = try container.decode(String.self, forKey: .nickname)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage) ?? ""
        password = try container.decode(String.self, forKey: .password)
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
        connectAtLaunch = try container.decodeIfPresent(Bool.self, forKey: .connectAtLaunch) ?? false
        acceptsOfflineMessages = try container.decodeIfPresent(Bool.self, forKey: .acceptsOfflineMessages) ?? true
    }

    var bookmark: ServerBookmark {
        ServerBookmark(id: id, name: name, host: host, port: port, login: login,
                       nickname: nickname, statusMessage: statusMessage, autoReconnect: autoReconnect,
                       connectAtLaunch: connectAtLaunch, acceptsOfflineMessages: acceptsOfflineMessages)
    }
}

struct ServerBookmarkPortableDocument: Codable, Equatable {
    static let currentVersion = 4
    static let formatIdentifier = "CarrachoServerBookmarks"

    var format: String = Self.formatIdentifier
    var version: Int = Self.currentVersion
    var selectedBookmarkID: UUID?
    var bookmarks: [ServerBookmarkPortableEntry]
}

enum ServerBookmarkImportMode { case merge, replaceAll }

enum ServerBookmarkStoreError: LocalizedError {
    case invalidExportFormat
    case unsupportedExportVersion(Int)
    case invalidBookmark(String)

    var errorDescription: String? {
        switch self {
        case .invalidExportFormat:
            return L("This is not a Carracho bookmark export file.")
        case let .unsupportedExportVersion(version):
            return LF("Bookmark export version %@ is not supported.", String(version))
        case let .invalidBookmark(message):
            return LF("Invalid bookmark in import file: %@", message)
        }
    }
}

struct ServerBookmarkStore {
    struct Snapshot: Equatable {
        var bookmarks: [ServerBookmark]
        var selectedID: UUID?
    }

    static let bookmarksKey = "CarrachoServerBookmarks.v1"
    static let selectedKey = "CarrachoSelectedServerBookmark.v1"
    static let defaultBookmarkHost = "carracho.istation.pw"

    var defaults: UserDefaults = .standard

    func load() -> Snapshot {
        let bookmarks: [ServerBookmark]
        if let data = defaults.data(forKey: Self.bookmarksKey),
           let decoded = try? JSONDecoder().decode([ServerBookmark].self, from: data) {
            bookmarks = decoded
        } else if defaults.object(forKey: Self.bookmarksKey) == nil {
            let bookmark = ServerBookmark(
                name: Self.defaultBookmarkHost,
                host: Self.defaultBookmarkHost,
                port: 6700,
                login: "anonymous",
                nickname: ""
            )
            let initial = Snapshot(bookmarks: [bookmark], selectedID: bookmark.id)
            save(initial)
            return initial
        } else {
            // A present but unreadable value is not a first launch. Do not silently replace
            // existing state with the bundled default if preferences ever become corrupted.
            bookmarks = []
        }

        let selectedID: UUID?
        if let value = defaults.string(forKey: Self.selectedKey),
           let id = UUID(uuidString: value),
           bookmarks.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = nil
        }
        return Snapshot(bookmarks: bookmarks, selectedID: selectedID)
    }

    func save(_ snapshot: Snapshot) {
        if let data = try? JSONEncoder().encode(snapshot.bookmarks) {
            defaults.set(data, forKey: Self.bookmarksKey)
        }
        if let selectedID = snapshot.selectedID,
           snapshot.bookmarks.contains(where: { $0.id == selectedID }) {
            defaults.set(selectedID.uuidString, forKey: Self.selectedKey)
        } else {
            defaults.removeObject(forKey: Self.selectedKey)
        }
    }

    func exportData(snapshot: Snapshot, keychain: ServerBookmarkPasswordStore) throws -> Data {
        let entries = try snapshot.bookmarks.map { bookmark -> ServerBookmarkPortableEntry in
            ServerBookmarkPortableEntry(id: bookmark.id,
                                        name: bookmark.name,
                                        host: bookmark.host,
                                        port: bookmark.port,
                                        login: bookmark.login,
                                        nickname: bookmark.nickname,
                                        statusMessage: bookmark.statusMessage,
                                        password: try keychain.password(for: bookmark.id) ?? "",
                                        autoReconnect: bookmark.autoReconnect,
                                        connectAtLaunch: bookmark.connectAtLaunch,
                                        acceptsOfflineMessages: bookmark.acceptsOfflineMessages)
        }
        let document = ServerBookmarkPortableDocument(selectedBookmarkID: snapshot.selectedID, bookmarks: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    func decodeImport(_ data: Data) throws -> ServerBookmarkPortableDocument {
        let document = try JSONDecoder().decode(ServerBookmarkPortableDocument.self, from: data)
        guard document.format == ServerBookmarkPortableDocument.formatIdentifier else {
            throw ServerBookmarkStoreError.invalidExportFormat
        }
        guard (1...ServerBookmarkPortableDocument.currentVersion).contains(document.version) else {
            throw ServerBookmarkStoreError.unsupportedExportVersion(document.version)
        }
        var ids = Set<UUID>()
        for entry in document.bookmarks {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = entry.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ServerBookmarkStoreError.invalidBookmark(L("name must not be empty")) }
            guard !host.isEmpty else { throw ServerBookmarkStoreError.invalidBookmark(L("server address must not be empty")) }
            guard entry.port > 0 && entry.port < UInt16.max else { throw ServerBookmarkStoreError.invalidBookmark(L("port must be between 1 and 65534")) }
            guard entry.password.utf8.count <= 4096 else { throw ServerBookmarkStoreError.invalidBookmark(L("password is too long")) }
            guard let statusData = entry.statusMessage.data(using: .macOSRoman), statusData.count <= 255 else {
                throw ServerBookmarkStoreError.invalidBookmark(L("status must be MacRoman-compatible and at most 255 bytes"))
            }
            guard ids.insert(entry.id).inserted else { throw ServerBookmarkStoreError.invalidBookmark("duplicate bookmark ID \(entry.id.uuidString)") }
        }
        return document
    }

    @discardableResult
    func importDocument(_ document: ServerBookmarkPortableDocument,
                        mode: ServerBookmarkImportMode,
                        keychain: ServerBookmarkPasswordStore) throws -> Snapshot {
        // Capture old secrets before changing Keychain so an error can be rolled back.
        let old = load()
        let affectedIDs = Set(old.bookmarks.map(\.id)).union(document.bookmarks.map(\.id))
        var oldPasswords: [UUID: String?] = [:]
        for id in affectedIDs { oldPasswords[id] = try keychain.password(for: id) }

        do {
            for entry in document.bookmarks { try keychain.setPassword(entry.password, for: entry.id) }

            var merged: [ServerBookmark]
            switch mode {
            case .replaceAll:
                merged = document.bookmarks.map(\.bookmark)
                let imported = Set(merged.map(\.id))
                for bookmark in old.bookmarks where !imported.contains(bookmark.id) {
                    try keychain.removePassword(for: bookmark.id)
                }
            case .merge:
                merged = old.bookmarks
                for entry in document.bookmarks {
                    if let index = merged.firstIndex(where: { $0.id == entry.id }) {
                        merged[index] = entry.bookmark
                    } else {
                        merged.append(entry.bookmark)
                    }
                }
            }

            let importedSelection = document.selectedBookmarkID.flatMap { id in merged.contains(where: { $0.id == id }) ? id : nil }
            let selected: UUID?
            switch mode {
            case .replaceAll:
                selected = importedSelection ?? merged.first?.id
            case .merge:
                selected = old.selectedID ?? importedSelection ?? merged.first?.id
            }
            let snapshot = Snapshot(bookmarks: merged, selectedID: selected)
            save(snapshot)
            return snapshot
        } catch {
            for id in affectedIDs {
                do {
                    if let prior = oldPasswords[id] ?? nil {
                        try keychain.setPassword(prior, for: id)
                    } else {
                        try keychain.removePassword(for: id)
                    }
                } catch {
                    // Preserve the original import error. A subsequent edit/import can repair a failed rollback.
                }
            }
            save(old)
            throw error
        }
    }
}
