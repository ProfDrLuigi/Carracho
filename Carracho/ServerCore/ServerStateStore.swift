import Foundation
import SQLite3

enum ServerStateError: LocalizedError, Equatable {
    case unsupportedFormat(Int)
    case invalidValue(String)
    case duplicateAccount(String)
    case accountNotFound(UUID)
    case duplicateAccountGroup(String)
    case accountGroupNotFound(UUID)
    case accountGroupInUse(String)
    case duplicateNewsgroup(String)
    case newsgroupNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(version): return "Unsupported server-state format version \(version)."
        case let .invalidValue(message): return message
        case let .duplicateAccount(login): return "An account named “\(login)” already exists."
        case .accountNotFound: return "The account no longer exists."
        case let .duplicateAccountGroup(name): return "An account group named “\(name)” already exists."
        case .accountGroupNotFound: return "The account group no longer exists."
        case let .accountGroupInUse(name): return "The group “\(name)” is still assigned to one or more accounts."
        case let .duplicateNewsgroup(name): return "A newsgroup named “\(name)” already exists."
        case .newsgroupNotFound: return "The newsgroup no longer exists."
        }
    }
}

enum ServerStateSQLiteError: LocalizedError {
    case open(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case step(String)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case let .open(message): return "Could not open server database: \(message)"
        case let .execute(message): return "Server database command failed: \(message)"
        case let .prepare(message): return "Server database statement failed: \(message)"
        case let .bind(message): return "Server database binding failed: \(message)"
        case let .step(message): return "Server database operation failed: \(message)"
        case let .corrupt(message): return "Server database is incomplete or corrupt: \(message)"
        }
    }
}


struct ServerAccountTransferStatistics: Equatable {
    var accountID: UUID
    var login: String
    var downloadCount: UInt64
    var downloadBytes: UInt64
    var uploadCount: UInt64
    var uploadBytes: UInt64
}

enum ServerTransferStatisticDirection { case download, upload }

struct ServerStateStore {
    /// `url` is the requested persistence location. New callers should pass `server.db`.
    /// For compatibility, a `.json` URL is treated as a legacy import source and the
    /// canonical SQLite database is created next to it as `server.db`.
    let url: URL
    var passwordIterations: UInt32 = ServerPasswordHasher.defaultIterations

    private static let databaseSchemaVersion = 4
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    var databaseURL: URL {
        if url.pathExtension.lowercased() == "json" {
            return url.deletingLastPathComponent().appendingPathComponent("server.db")
        }
        return url
    }

    var legacyJSONURL: URL {
        if url.pathExtension.lowercased() == "json" { return url }
        return url.deletingLastPathComponent().appendingPathComponent("server-state.json")
    }

    func loadOrCreate() throws -> ServerState {
        let manager = FileManager.default
        let directory = databaseURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var db: OpaquePointer?
        try openDatabase(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)

        if try hasPersistedState(db) {
            let decoded = try loadState(db)
            let migrated = try ServerStateMigrator.toCurrent(decoded, passwordIterations: passwordIterations)
            try ServerStateValidator.validate(migrated)
            try ensureAccountTransferRows(migrated.accounts, db: db)
            if migrated != decoded { return try save(migrated) }
            return migrated
        }

        if manager.fileExists(atPath: legacyJSONURL.path) {
            let data = try Data(contentsOf: legacyJSONURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(ServerState.self, from: data)
            let migrated = try ServerStateMigrator.toCurrent(decoded, passwordIterations: passwordIterations)
            try ServerStateValidator.validate(migrated)
            return try save(migrated)
        }

        return try save(ServerState.initial)
    }

    @discardableResult
    func save(_ state: ServerState) throws -> ServerState {
        let normalized = try ServerStateMigrator.toCurrent(state, passwordIterations: passwordIterations)
        try ServerStateValidator.validate(normalized)
        let manager = FileManager.default
        try manager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        try openDatabase(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE TRANSACTION")
        do {
            try replaceState(normalized, db: db)
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
        return normalized
    }

    private func openDatabase(_ db: inout OpaquePointer?) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(databaseURL.path, &db, flags, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let db { sqlite3_close(db) }
            db = nil
            throw ServerStateSQLiteError.open(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        try exec(db, "PRAGMA foreign_keys=ON")
        try exec(db, "PRAGMA journal_mode=WAL")
        try exec(db, "PRAGMA synchronous=FULL")
    }

    private func createSchema(_ db: OpaquePointer?) throws {
        try exec(db, """
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS settings (
            section TEXT PRIMARY KEY,
            json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS accounts (
            id TEXT PRIMARY KEY,
            login TEXT NOT NULL COLLATE NOCASE UNIQUE,
            sort_order INTEGER NOT NULL,
            json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS accounts_login_idx ON accounts(login COLLATE NOCASE);
        CREATE TABLE IF NOT EXISTS newsgroups (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL COLLATE NOCASE UNIQUE,
            sort_order INTEGER NOT NULL,
            json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS newsgroups_name_idx ON newsgroups(name COLLATE NOCASE);
        CREATE TABLE IF NOT EXISTS statistics (
            name TEXT PRIMARY KEY,
            value INTEGER NOT NULL CHECK(value >= 0)
        );
        CREATE TABLE IF NOT EXISTS account_transfer_statistics (
            account_id TEXT PRIMARY KEY,
            login TEXT NOT NULL,
            download_count INTEGER NOT NULL DEFAULT 0 CHECK(download_count >= 0),
            download_bytes INTEGER NOT NULL DEFAULT 0 CHECK(download_bytes >= 0),
            upload_count INTEGER NOT NULL DEFAULT 0 CHECK(upload_count >= 0),
            upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK(upload_bytes >= 0)
        );
        CREATE INDEX IF NOT EXISTS account_transfer_statistics_login_idx ON account_transfer_statistics(login COLLATE NOCASE);
        CREATE TABLE IF NOT EXISTS offline_messages (
            id TEXT PRIMARY KEY,
            recipient_account_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL,
            tag BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS offline_messages_recipient_idx ON offline_messages(recipient_account_id, created_at, id);
        CREATE TABLE IF NOT EXISTS file_metadata (
            scope INTEGER NOT NULL CHECK(scope IN (0, 1)),
            path BLOB NOT NULL,
            flags INTEGER NOT NULL DEFAULT 0 CHECK(flags BETWEEN 0 AND 65535),
            comment BLOB NOT NULL DEFAULT X'',
            finder_info BLOB NOT NULL CHECK(length(finder_info) = 16),
            created_at TEXT,
            label INTEGER NOT NULL DEFAULT 0 CHECK(label BETWEEN 0 AND 7),
            PRIMARY KEY(scope, path)
        ) WITHOUT ROWID;
        """)
        try setPragmaUserVersion(db, Self.databaseSchemaVersion)
    }

    private func hasPersistedState(_ db: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        try prepare(db, "SELECT 1 FROM meta WHERE key='state_format_version' LIMIT 1", &statement)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw ServerStateSQLiteError.step(errorMessage(db))
    }

    private func loadState(_ db: OpaquePointer?) throws -> ServerState {
        let formatVersion = Int(try requiredScalarText(db, sql: "SELECT value FROM meta WHERE key='state_format_version'"))
            ?? ServerState.currentFormatVersion
        let authentication: ServerAuthenticationSettings = try decodeSetting("authentication", db: db)
        let identity: ServerIdentity = try decodeSetting("identity", db: db)
        let advanced: ServerAdvancedSettings = try decodeSetting("advanced", db: db)
        let runtime: ServerRuntimeSettings = try decodeSettingIfPresent("runtime", db: db) ?? ServerRuntimeSettings()
        let agreement: ServerAgreement = try decodeSetting("agreement", db: db)
        let accountGroups: [ServerAccountGroup] = try decodeSettingIfPresent("accountGroups", db: db) ?? []
        let accounts: [ServerAccount] = try loadJSONRows(db, sql: "SELECT json FROM accounts ORDER BY sort_order, login COLLATE NOCASE")
        let newsgroups: [ServerNewsgroup] = try loadJSONRows(db, sql: "SELECT json FROM newsgroups ORDER BY sort_order, name COLLATE NOCASE")
        let statistics = try loadStatistics(db)
        return ServerState(formatVersion: formatVersion,
                           authentication: authentication,
                           identity: identity,
                           advanced: advanced,
                           runtime: runtime,
                           agreement: agreement,
                           accountGroups: accountGroups,
                           accounts: accounts,
                           newsgroups: newsgroups,
                           statistics: statistics)
    }

    private func replaceState(_ state: ServerState, db: OpaquePointer?) throws {
        try exec(db, "DELETE FROM meta; DELETE FROM settings; DELETE FROM accounts; DELETE FROM newsgroups; DELETE FROM statistics;")
        try insert(db, sql: "INSERT INTO meta(key,value) VALUES(?,?)", values: ["schema_version", String(Self.databaseSchemaVersion)])
        try insert(db, sql: "INSERT INTO meta(key,value) VALUES(?,?)", values: ["state_format_version", String(state.formatVersion)])
        try insertSetting("authentication", value: state.authentication, db: db)
        try insertSetting("identity", value: state.identity, db: db)
        try insertSetting("advanced", value: state.advanced, db: db)
        try insertSetting("runtime", value: state.runtime, db: db)
        try insertSetting("agreement", value: state.agreement, db: db)
        try insertSetting("accountGroups", value: state.accountGroups, db: db)

        let encoder = stateEncoder()
        for (index, account) in state.accounts.enumerated() {
            let json = String(decoding: try encoder.encode(account), as: UTF8.self)
            try insert(db, sql: "INSERT INTO accounts(id,login,sort_order,json) VALUES(?,?,?,?)",
                       values: [account.id.uuidString, account.login, Int64(index), json])
        }
        try ensureAccountTransferRows(state.accounts, db: db)
        for (index, group) in state.newsgroups.enumerated() {
            let json = String(decoding: try encoder.encode(group), as: UTF8.self)
            try insert(db, sql: "INSERT INTO newsgroups(id,name,sort_order,json) VALUES(?,?,?,?)",
                       values: [group.id.uuidString, group.name, Int64(index), json])
        }
        let stats: [(String, UInt64)] = [
            ("hits", state.statistics.hits),
            ("connectionPeak", state.statistics.connectionPeak),
            ("incorrectLogins", state.statistics.incorrectLogins),
            ("adminsConnected", state.statistics.adminsConnected),
            ("accountHoldersConnected", state.statistics.accountHoldersConnected),
            ("guestsConnected", state.statistics.guestsConnected),
            ("downloadsInProgress", state.statistics.downloadsInProgress),
            ("totalDownloads", state.statistics.totalDownloads),
            ("uploadsInProgress", state.statistics.uploadsInProgress),
            ("totalUploads", state.statistics.totalUploads),
            ("totalMessages", state.statistics.totalMessages),
        ]
        for (name, value) in stats {
            let safe = min(value, UInt64(Int64.max))
            try insert(db, sql: "INSERT INTO statistics(name,value) VALUES(?,?)", values: [name, Int64(safe)])
        }
    }

    private func ensureAccountTransferRows(_ accounts: [ServerAccount], db: OpaquePointer?) throws {
        for account in accounts {
            try insert(db, sql: "INSERT INTO account_transfer_statistics(account_id,login,download_count,download_bytes,upload_count,upload_bytes) VALUES(?,?,0,0,0,0) ON CONFLICT(account_id) DO UPDATE SET login=excluded.login", values: [account.id.uuidString, account.login])
        }
    }

    func recordCompletedTransfer(accountID: UUID, login: String, direction: ServerTransferStatisticDirection, bytes: UInt64) throws {
        var db: OpaquePointer?
        try openDatabase(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        let cappedBytes = Int64(min(bytes, UInt64(Int64.max)))
        try exec(db, "BEGIN IMMEDIATE TRANSACTION")
        do {
            try insert(db, sql: "INSERT INTO account_transfer_statistics(account_id,login,download_count,download_bytes,upload_count,upload_bytes) VALUES(?,?,0,0,0,0) ON CONFLICT(account_id) DO UPDATE SET login=excluded.login", values: [accountID.uuidString, login])
            let countColumn = direction == .download ? "download_count" : "upload_count"
            let bytesColumn = direction == .download ? "download_bytes" : "upload_bytes"
            try exec(db, "UPDATE account_transfer_statistics SET \(countColumn)=CASE WHEN \(countColumn)>=9223372036854775807 THEN 9223372036854775807 ELSE \(countColumn)+1 END, \(bytesColumn)=CASE WHEN \(bytesColumn)>9223372036854775807-\(cappedBytes) THEN 9223372036854775807 ELSE \(bytesColumn)+\(cappedBytes) END WHERE account_id='\(accountID.uuidString.replacingOccurrences(of: "'", with: "''"))'")
            try exec(db, "COMMIT")
        } catch { try? exec(db, "ROLLBACK"); throw error }
    }

    func loadAccountTransferStatistics() throws -> [ServerAccountTransferStatistics] {
        var db: OpaquePointer?
        try openDatabase(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var statement: OpaquePointer?
        try prepare(db, "SELECT account_id,login,download_count,download_bytes,upload_count,upload_bytes FROM account_transfer_statistics ORDER BY login COLLATE NOCASE, account_id", &statement)
        defer { sqlite3_finalize(statement) }
        var rows: [ServerAccountTransferStatistics] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement,0), let loginText = sqlite3_column_text(statement,1), let id = UUID(uuidString:String(cString:idText)) else { continue }
            rows.append(.init(accountID:id, login:String(cString:loginText), downloadCount:UInt64(max(0,sqlite3_column_int64(statement,2))), downloadBytes:UInt64(max(0,sqlite3_column_int64(statement,3))), uploadCount:UInt64(max(0,sqlite3_column_int64(statement,4))), uploadBytes:UInt64(max(0,sqlite3_column_int64(statement,5)))))
        }
        return rows
    }

    private func loadStatistics(_ db: OpaquePointer?) throws -> ServerStatistics {
        var values: [String: UInt64] = [:]
        var statement: OpaquePointer?
        try prepare(db, "SELECT name,value FROM statistics", &statement)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw ServerStateSQLiteError.step(errorMessage(db)) }
            guard let namePtr = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: namePtr)
            let value = sqlite3_column_int64(statement, 1)
            values[name] = UInt64(max(0, value))
        }
        return ServerStatistics(hits: values["hits"] ?? 0,
                                connectionPeak: values["connectionPeak"] ?? 0,
                                incorrectLogins: values["incorrectLogins"] ?? 0,
                                adminsConnected: values["adminsConnected"] ?? 0,
                                accountHoldersConnected: values["accountHoldersConnected"] ?? 0,
                                guestsConnected: values["guestsConnected"] ?? 0,
                                downloadsInProgress: values["downloadsInProgress"] ?? 0,
                                totalDownloads: values["totalDownloads"] ?? 0,
                                uploadsInProgress: values["uploadsInProgress"] ?? 0,
                                totalUploads: values["totalUploads"] ?? 0,
                                totalMessages: values["totalMessages"] ?? 0)
    }

    private func insertSetting<T: Encodable>(_ section: String, value: T, db: OpaquePointer?) throws {
        let json = String(decoding: try stateEncoder().encode(value), as: UTF8.self)
        try insert(db, sql: "INSERT INTO settings(section,json) VALUES(?,?)", values: [section, json])
    }

    private func decodeSetting<T: Decodable>(_ section: String, db: OpaquePointer?) throws -> T {
        let json = try requiredScalarText(db, sql: "SELECT json FROM settings WHERE section=?", bindText: section)
        guard let data = json.data(using: .utf8) else { throw ServerStateSQLiteError.corrupt("invalid UTF-8 in \(section)") }
        return try stateDecoder().decode(T.self, from: data)
    }

    private func decodeSettingIfPresent<T: Decodable>(_ section: String, db: OpaquePointer?) throws -> T? {
        var statement: OpaquePointer?
        try prepare(db, "SELECT json FROM settings WHERE section=?", &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, section, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw ServerStateSQLiteError.bind(errorMessage(db))
        }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw ServerStateSQLiteError.step(errorMessage(db))
        }
        let json = String(cString: text)
        guard let data = json.data(using: .utf8) else {
            throw ServerStateSQLiteError.corrupt("invalid UTF-8 in \(section)")
        }
        return try stateDecoder().decode(T.self, from: data)
    }

    private func loadJSONRows<T: Decodable>(_ db: OpaquePointer?, sql: String) throws -> [T] {
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        let decoder = stateDecoder()
        var resultRows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw ServerStateSQLiteError.step(errorMessage(db)) }
            guard let text = sqlite3_column_text(statement, 0) else { throw ServerStateSQLiteError.corrupt("NULL JSON row") }
            let json = String(cString: text)
            guard let data = json.data(using: .utf8) else { throw ServerStateSQLiteError.corrupt("invalid UTF-8 JSON row") }
            resultRows.append(try decoder.decode(T.self, from: data))
        }
        return resultRows
    }

    private func requiredScalarText(_ db: OpaquePointer?, sql: String, bindText: String? = nil) throws -> String {
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        if let bindText {
            guard sqlite3_bind_text(statement, 1, bindText, -1, Self.sqliteTransient) == SQLITE_OK else {
                throw ServerStateSQLiteError.bind(errorMessage(db))
            }
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw ServerStateSQLiteError.corrupt("missing row for query: \(sql)")
        }
        return String(cString: text)
    }

    private func insert(_ db: OpaquePointer?, sql: String, values: [Any]) throws {
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let value as String:
                result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
            case let value as Int:
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case let value as Int64:
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            default:
                throw ServerStateSQLiteError.bind("unsupported binding type")
            }
            guard result == SQLITE_OK else { throw ServerStateSQLiteError.bind(errorMessage(db)) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ServerStateSQLiteError.step(errorMessage(db)) }
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ServerStateSQLiteError.prepare(errorMessage(db))
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &message)
        if result != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? errorMessage(db)
            sqlite3_free(message)
            throw ServerStateSQLiteError.execute(text)
        }
    }

    private func setPragmaUserVersion(_ db: OpaquePointer?, _ version: Int) throws {
        try exec(db, "PRAGMA user_version=\(version)")
    }

    private func errorMessage(_ db: OpaquePointer?) -> String {
        guard let db else { return "unknown SQLite error" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func stateEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func stateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum ServerStateMigrator {
    static func toCurrent(_ source: ServerState, passwordIterations: UInt32) throws -> ServerState {
        guard source.formatVersion > 0, source.formatVersion <= ServerState.currentFormatVersion else {
            throw ServerStateError.unsupportedFormat(source.formatVersion)
        }
        var state = source
        if source.formatVersion < 3 {
            // Transfer monitoring historically rode on editAdvancedSettings. Preserve
            // existing administrators' access once it becomes an independent right.
            for index in state.accounts.indices
            where state.accounts[index].mode == .administrator
                && state.accounts[index].permissions.contains(.editAdvancedSettings) {
                state.accounts[index].permissions.insert(.manageTransfers)
            }
        }
        if source.formatVersion < 4 {
            // Threaded News historically had only per-category read/post ACLs. The modern
            // account-level postNews permission is additive: preserve the old effective access
            // for administrators/account holders, and for guests only when a category already
            // allowed Guest posting.
            let guestsCouldPost = state.newsgroups.contains(where: { $0.access.guestsPost })
            for index in state.accountGroups.indices {
                switch state.accountGroups[index].legacyMode {
                case .administrator, .accountHolder:
                    state.accountGroups[index].permissions.insert(.postNews)
                case .guest:
                    if guestsCouldPost { state.accountGroups[index].permissions.insert(.postNews) }
                }
            }
            for index in state.accounts.indices {
                switch state.accounts[index].mode {
                case .administrator, .accountHolder:
                    state.accounts[index].permissions.insert(.postNews)
                case .guest:
                    if guestsCouldPost { state.accounts[index].permissions.insert(.postNews) }
                }
            }
        }
        migrateAccountGroups(&state)
        for index in state.accounts.indices {
            if state.accounts[index].passwordVerifier == nil {
                guard let legacyPassword = state.accounts[index].legacyPassword else {
                    throw ServerStateError.invalidValue("Account “\(state.accounts[index].login)” has no usable password credential.")
                }
                state.accounts[index].passwordVerifier = ServerPasswordHasher.makeVerifier(
                    password: legacyPassword,
                    iterations: passwordIterations
                )
            }
            if state.authentication.mode == .modernOnly {
                state.accounts[index].legacyPassword = nil
            }
        }
        state.formatVersion = ServerState.currentFormatVersion
        return state
    }

    private static func migrateAccountGroups(_ state: inout ServerState) {
        let oldGroups = state.accountGroups
        let initial = ServerState.initialAccountGroups

        func sourceGroup(for mode: ServerAccountMode) -> ServerAccountGroup? {
            let fixedID = ServerState.builtInAccountGroupID(for: mode)
            return oldGroups.first(where: { $0.id == fixedID })
                ?? oldGroups.first(where: { $0.legacyMode == mode })
        }

        // Collapse every historical/custom group layout onto the three Classic account classes.
        // Existing effective permissions are deliberately kept on each account: group values are
        // assignment defaults now, not a live inheritance chain.
        state.accountGroups = initial.map { fallback in
            guard let old = sourceGroup(for: fallback.legacyMode) else { return fallback }
            return ServerAccountGroup(
                id: fallback.id,
                name: ServerState.builtInAccountGroupName(for: fallback.legacyMode),
                colorRGB: old.colorRGB,
                legacyMode: fallback.legacyMode,
                permissions: old.permissions,
                filesRootPath: old.filesRootPath,
                filesRootName: old.effectiveFilesRootName
            )
        }

        for index in state.accounts.indices {
            let account = state.accounts[index]
            let oldGroup = account.groupID.flatMap { id in oldGroups.first(where: { $0.id == id }) }
            let effectiveMode = oldGroup?.legacyMode ?? account.mode
            state.accounts[index].mode = effectiveMode
            if state.accounts[index].colorRGB == nil {
                let fallback = state.accountGroups.first(where: { $0.legacyMode == effectiveMode })?.colorRGB
                state.accounts[index].colorRGB = oldGroup?.colorRGB ?? fallback
            }
            state.accounts[index].groupID = ServerState.builtInAccountGroupID(for: effectiveMode)
        }
    }
}

enum ServerStateValidator {
    static func validate(_ state: ServerState) throws {
        guard state.formatVersion == ServerState.currentFormatVersion else {
            throw ServerStateError.unsupportedFormat(state.formatVersion)
        }
        try validate(identity: state.identity)
        try validate(advanced: state.advanced)

        guard state.accountGroups.count == ServerState.builtInAccountGroupOrder.count else {
            throw ServerStateError.invalidValue("The server must contain exactly the three Classic account groups.")
        }
        var accountGroupIDs = Set<UUID>()
        for group in state.accountGroups {
            try validate(accountGroup: group)
            guard accountGroupIDs.insert(group.id).inserted else {
                throw ServerStateError.invalidValue("Duplicate account-group identifier.")
            }
            guard group.id == ServerState.builtInAccountGroupID(for: group.legacyMode),
                  group.name == ServerState.builtInAccountGroupName(for: group.legacyMode) else {
                throw ServerStateError.invalidValue("Account groups are fixed to Administrator, Account Holder and Guest.")
            }
        }
        guard accountGroupIDs == Set(ServerState.builtInAccountGroupOrder) else {
            throw ServerStateError.invalidValue("One or more fixed Classic account groups are missing.")
        }

        var accountNames = Set<String>()
        for account in state.accounts {
            try validate(account: account)
            if state.authentication.mode == .modernOnly, account.legacyPassword != nil {
                throw ServerStateError.invalidValue("Modern-only state must not retain legacy password material.")
            }
            guard let groupID = account.groupID,
                  let group = state.accountGroups.first(where: { $0.id == groupID }) else {
                throw ServerStateError.invalidValue("Account “\(account.login)” has no valid Classic account group.")
            }
            guard account.mode == group.legacyMode else {
                throw ServerStateError.invalidValue("Account “\(account.login)” has a group/type mismatch.")
            }
            if let color = account.colorRGB, color > 0x00ff_ffff {
                throw ServerStateError.invalidValue("Account nickname color must be a 24-bit RGB value.")
            }
            let key = normalized(account.login)
            guard accountNames.insert(key).inserted else { throw ServerStateError.duplicateAccount(account.login) }
        }

        var groupNames = Set<String>()
        for group in state.newsgroups {
            try validate(newsgroup: group)
            let key = normalized(group.name)
            guard groupNames.insert(key).inserted else { throw ServerStateError.duplicateNewsgroup(group.name) }
        }
    }

    static func validate(accountGroup: ServerAccountGroup) throws {
        let name = accountGroup.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 64 else {
            throw ServerStateError.invalidValue("Account-group name must be 1…64 UTF-8 bytes.")
        }
        guard accountGroup.colorRGB <= 0x00ff_ffff else {
            throw ServerStateError.invalidValue("Account-group color must be a 24-bit RGB value.")
        }
        let filesPath = accountGroup.filesRootPath
        guard filesPath.utf8.count <= 1024, !filesPath.contains("\0") else {
            throw ServerStateError.invalidValue("Account-group Files root path is too long or invalid.")
        }
        if !filesPath.isEmpty {
            guard !filesPath.hasPrefix("/"), !filesPath.hasSuffix("/") else {
                throw ServerStateError.invalidValue("Account-group Files root must be relative to Allgemein.")
            }
            let components = filesPath.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 252
            }) else {
                throw ServerStateError.invalidValue("Account-group Files root contains an unsafe path component.")
            }
            let rootName = accountGroup.filesRootName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rootName.isEmpty, rootName.utf8.count <= 64, !rootName.contains("\0") else {
                throw ServerStateError.invalidValue("Account-group Files root name must be 1…64 UTF-8 bytes.")
            }
        }
    }

    static func validate(account: ServerAccount) throws {
        let login = account.login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty, login.utf8.count <= 63 else {
            throw ServerStateError.invalidValue("Account login must be 1…63 UTF-8 bytes.")
        }
        guard account.name.utf8.count <= 64 else {
            throw ServerStateError.invalidValue("Account name exceeds 64 UTF-8 bytes.")
        }
        if let email = account.email, email.utf8.count > 64 {
            throw ServerStateError.invalidValue("Account e-mail exceeds 64 UTF-8 bytes.")
        }
        if let about = account.aboutMe, about.utf8.count > 128 {
            throw ServerStateError.invalidValue("Account About me exceeds 128 UTF-8 bytes.")
        }
        if let picture = account.picture, picture.count > LegacyUserInfoField.maximumPictureLength {
            throw ServerStateError.invalidValue("Account picture exceeds the 65535-byte protocol limit.")
        }
        if let legacyPassword = account.legacyPassword, legacyPassword.utf8.count > 64 {
            throw ServerStateError.invalidValue("Legacy-compatible password exceeds 64 UTF-8 bytes.")
        }
        guard let verifier = account.passwordVerifier else {
            throw ServerStateError.invalidValue("Account “\(account.login)” has no modern password verifier.")
        }
        guard verifier.algorithm == .pbkdf2SHA256,
              verifier.iterations > 0 && verifier.iterations <= 10_000_000,
              verifier.salt.count >= 16 && verifier.salt.count <= 64,
              verifier.derivedKey.count == ServerPasswordHasher.derivedKeyLength else {
            throw ServerStateError.invalidValue("Account “\(account.login)” has an invalid password verifier.")
        }
    }

    static func validate(newsgroup: ServerNewsgroup) throws {
        let name = newsgroup.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 64 else {
            throw ServerStateError.invalidValue("Newsgroup name must be 1…64 UTF-8 bytes.")
        }
    }

    static func validate(identity: ServerIdentity) throws {
        guard !identity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerStateError.invalidValue("Server name must not be empty.")
        }
        guard identity.name.utf8.count <= 255,
              identity.operatorName.utf8.count <= 255,
              identity.location.utf8.count <= 255,
              identity.description.utf8.count <= 16_384,
              identity.bannerURL.utf8.count <= 2_048 else {
            throw ServerStateError.invalidValue("One or more server-information fields are too long.")
        }
        guard let legacyBannerURL = identity.bannerURL.data(using: .macOSRoman), legacyBannerURL.count <= 255 else {
            throw ServerStateError.invalidValue("Banner URL must be representable in MacRoman and at most 255 bytes.")
        }
        if let bannerData = identity.bannerData, bannerData.count > 8 * 1024 * 1024 {
            throw ServerStateError.invalidValue("Banner image exceeds 8 MiB.")
        }
    }

    static func validateTrackerRegistrationEligibility(_ state: ServerState) throws {
        // CTT v1 registrations carry no credentials and the Classic server does not impose
        // account-policy prerequisites. Keep this hook for transaction symmetry, but do not
        // reject public publication merely because anonymous access is disabled or protected.
        _ = state
    }

    static func validate(advanced: ServerAdvancedSettings) throws {
        guard advanced.controlPort > 0, advanced.controlPort < UInt16.max else {
            throw ServerStateError.invalidValue("Server control port must be between 1 and 65534 because the transfer service uses port +1.")
        }
        guard advanced.maxConnections > 0 else { throw ServerStateError.invalidValue("Max. connections must be greater than zero.") }
        guard advanced.maxConnectionsPerIP > 0 else { throw ServerStateError.invalidValue("Max. connections per IP must be greater than zero.") }
        guard advanced.maxSimultaneousFileTransfers > 0 else { throw ServerStateError.invalidValue("Max. simultaneous file transfers must be greater than zero.") }
        guard advanced.maxFileTransfersPerUser > 0 else { throw ServerStateError.invalidValue("Max. file transfers per user must be greater than zero.") }
        guard advanced.newsExpirationHour < 24, advanced.newsExpirationMinute < 60 else {
            throw ServerStateError.invalidValue("News expiration time is invalid.")
        }
        guard advanced.ipRestrictions.count <= 4096 else {
            throw ServerStateError.invalidValue("Allow/Deny IP list exceeds 4096 rules.")
        }
        for rule in advanced.ipRestrictions {
            guard rule.network.count == 4, rule.mask.count == 4 else {
                throw ServerStateError.invalidValue("Allow/Deny IP rules require exactly four network and mask bytes.")
            }
        }
        guard advanced.trackers.count <= Int(UInt16.max) else {
            throw ServerStateError.invalidValue("Tracker list exceeds 65535 records.")
        }
        for tracker in advanced.trackers {
            guard let name = tracker.name.data(using: .macOSRoman), name.count <= 32,
                  let address = tracker.address.data(using: .macOSRoman), !address.isEmpty, address.count <= 64,
                  let reserved = tracker.reservedString.data(using: .macOSRoman), reserved.count <= 16 else {
                throw ServerStateError.invalidValue("Tracker name/address/reserved text is invalid or exceeds Classic limits.")
            }
        }
        guard let trackerDescription = advanced.trackerDescription.data(using: .macOSRoman),
              trackerDescription.count <= 255 else {
            throw ServerStateError.invalidValue("Tracker description must be representable in MacRoman and at most 255 bytes.")
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
