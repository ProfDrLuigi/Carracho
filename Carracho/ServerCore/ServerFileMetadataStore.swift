import Foundation
import Dispatch
import SQLite3

struct ServerFileMetadata: Codable, Equatable {
    var flags: UInt16 = 0
    var comment: Data = Data()
    var finderInfo: Data = Data(repeating: 0, count: 16)
    var createdAt: Date? = nil
    /// Modern-only Finder-style color label. Stored alongside portable file metadata so it
    /// survives server restarts and follows move/rename operations. Classic sessions ignore it.
    var label: UInt8 = LegacyFileLabel.none.rawValue

    private enum CodingKeys: String, CodingKey {
        case flags, comment, finderInfo, createdAt, label
    }

    init(flags: UInt16 = 0,
         comment: Data = Data(),
         finderInfo: Data = Data(repeating: 0, count: 16),
         createdAt: Date? = nil,
         label: UInt8 = LegacyFileLabel.none.rawValue) {
        self.flags = flags
        self.comment = comment
        self.finderInfo = finderInfo
        self.createdAt = createdAt
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        flags = try values.decodeIfPresent(UInt16.self, forKey: .flags) ?? 0
        comment = try values.decodeIfPresent(Data.self, forKey: .comment) ?? Data()
        finderInfo = try values.decodeIfPresent(Data.self, forKey: .finderInfo) ?? Data(repeating: 0, count: 16)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
        let raw = try values.decodeIfPresent(UInt8.self, forKey: .label) ?? LegacyFileLabel.none.rawValue
        label = LegacyFileLabel(rawValue: raw)?.rawValue ?? LegacyFileLabel.none.rawValue
    }
}

enum ServerFileMetadataStoreError: Error, LocalizedError {
    case database(String)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case let .database(message): return "File metadata database error: \(message)"
        case let .corrupt(message): return "File metadata is corrupt: \(message)"
        }
    }
}

/// Portable metadata for Classic file-info fields that no longer have a natural
/// filesystem representation on modern macOS/Linux. Metadata is kept in server.db.
/// The two scopes deliberately share one table so the Swift and native-C servers use
/// exactly the same durable representation.
final class ServerFileMetadataStore {
    enum Scope: Int32 {
        case published = 0
        case legacy = 1
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let databaseURL: URL
    private let scope: Scope
    private let queue: DispatchQueue
    private var db: OpaquePointer?

    init(databaseURL: URL, scope: Scope, legacyJSONURL: URL? = nil) throws {
        self.databaseURL = databaseURL
        self.scope = scope
        self.queue = DispatchQueue(label: "com.carracho.server-file-metadata.\(scope.rawValue)")

        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, db != nil else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(databaseURL.path)"
            if let db { sqlite3_close(db) }
            self.db = nil
            throw ServerFileMetadataStoreError.database(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
            try createSchema()
            if let legacyJSONURL { try migrateLegacyJSONIfNeeded(from: legacyJSONURL) }
        } catch {
            if let db { sqlite3_close(db) }
            self.db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func metadata(for path: Data) -> ServerFileMetadata? {
        queue.sync {
            do { return try load(path: path) }
            catch { return nil }
        }
    }

    func set(_ metadata: ServerFileMetadata, for path: Data) throws {
        try queue.sync { try upsert(metadata, path: path) }
    }

    func remove(path: Data, includingDescendants: Bool) throws {
        try queue.sync {
            if !includingDescendants {
                try delete(path: path)
                return
            }
            let paths = try allRecords().compactMap { candidate, _ in
                candidate == path || isDescendant(candidate, of: path) ? candidate : nil
            }
            guard !paths.isEmpty else { return }
            try transaction {
                for candidate in paths { try delete(path: candidate) }
            }
        }
    }

    func move(from source: Data, to destination: Data, includingDescendants: Bool) throws {
        try queue.sync {
            let moves = try allRecords().compactMap { path, metadata -> (Data, Data, ServerFileMetadata)? in
                if path == source { return (path, destination, metadata) }
                guard includingDescendants, isDescendant(path, of: source) else { return nil }
                var mapped = destination
                mapped.append(path.dropFirst(source.count))
                return (path, mapped, metadata)
            }
            guard !moves.isEmpty else { return }
            try transaction {
                for (oldPath, _, _) in moves { try delete(path: oldPath) }
                for (_, newPath, metadata) in moves { try upsert(metadata, path: newPath) }
            }
        }
    }

    private func createSchema() throws {
        try execute("""
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
    }

    private func migrateLegacyJSONIfNeeded(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([String: ServerFileMetadata].self, from: data)

        try transaction {
            for (rawPath, metadata) in records {
                guard let path = Data(base64Encoded: rawPath) else {
                    throw ServerFileMetadataStoreError.corrupt("invalid base64 path in \(url.lastPathComponent)")
                }
                try insertIfAbsent(metadata, path: path)
            }
        }
        // The database is authoritative from this point onward. Removal is best-effort so a
        // read-only legacy file cannot make an otherwise healthy server fail to start.
        try? FileManager.default.removeItem(at: url)
    }

    private func load(path: Data) throws -> ServerFileMetadata? {
        var statement: OpaquePointer?
        try prepare("SELECT flags,comment,finder_info,created_at,label FROM file_metadata WHERE scope=? AND path=?", &statement)
        defer { sqlite3_finalize(statement) }
        try bindScope(statement, index: 1)
        try bindBlob(statement, index: 2, data: path)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw databaseError() }
        return try decodeMetadata(statement)
    }

    private func allRecords() throws -> [(Data, ServerFileMetadata)] {
        var statement: OpaquePointer?
        try prepare("SELECT path,flags,comment,finder_info,created_at,label FROM file_metadata WHERE scope=?", &statement)
        defer { sqlite3_finalize(statement) }
        try bindScope(statement, index: 1)
        var values: [(Data, ServerFileMetadata)] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw databaseError() }
            let path = columnBlob(statement, index: 0)
            let metadata = try decodeMetadata(statement, startingAt: 1)
            values.append((path, metadata))
        }
        return values
    }

    private func decodeMetadata(_ statement: OpaquePointer?, startingAt base: Int32 = 0) throws -> ServerFileMetadata {
        let flags = UInt16(clamping: sqlite3_column_int64(statement, base))
        let comment = columnBlob(statement, index: base + 1)
        let finderInfo = columnBlob(statement, index: base + 2)
        guard finderInfo.count == 16 else {
            throw ServerFileMetadataStoreError.corrupt("finder_info must contain exactly 16 bytes")
        }
        var createdAt: Date?
        if sqlite3_column_type(statement, base + 3) != SQLITE_NULL,
           let raw = sqlite3_column_text(statement, base + 3) {
            let text = String(cString: raw)
            guard let date = Self.iso8601.date(from: text) else {
                throw ServerFileMetadataStoreError.corrupt("invalid created_at timestamp")
            }
            createdAt = date
        }
        let rawLabel = UInt8(clamping: sqlite3_column_int64(statement, base + 4))
        let label = LegacyFileLabel(rawValue: rawLabel)?.rawValue ?? LegacyFileLabel.none.rawValue
        return ServerFileMetadata(flags: flags, comment: comment, finderInfo: finderInfo,
                                  createdAt: createdAt, label: label)
    }

    private func upsert(_ metadata: ServerFileMetadata, path: Data) throws {
        try write(metadata, path: path, conflictClause: "ON CONFLICT(scope,path) DO UPDATE SET flags=excluded.flags,comment=excluded.comment,finder_info=excluded.finder_info,created_at=excluded.created_at,label=excluded.label")
    }

    private func insertIfAbsent(_ metadata: ServerFileMetadata, path: Data) throws {
        try write(metadata, path: path, conflictClause: "ON CONFLICT(scope,path) DO NOTHING")
    }

    private func write(_ metadata: ServerFileMetadata, path: Data, conflictClause: String) throws {
        guard metadata.finderInfo.count == 16 else {
            throw ServerFileMetadataStoreError.corrupt("finderInfo must contain exactly 16 bytes")
        }
        guard LegacyFileLabel(rawValue: metadata.label) != nil else {
            throw ServerFileMetadataStoreError.corrupt("invalid file label \(metadata.label)")
        }
        var statement: OpaquePointer?
        try prepare("INSERT INTO file_metadata(scope,path,flags,comment,finder_info,created_at,label) VALUES(?,?,?,?,?,?,?) \(conflictClause)", &statement)
        defer { sqlite3_finalize(statement) }
        try bindScope(statement, index: 1)
        try bindBlob(statement, index: 2, data: path)
        guard sqlite3_bind_int64(statement, 3, sqlite3_int64(metadata.flags)) == SQLITE_OK else { throw databaseError() }
        try bindBlob(statement, index: 4, data: metadata.comment)
        try bindBlob(statement, index: 5, data: metadata.finderInfo)
        if let createdAt = metadata.createdAt {
            let text = Self.iso8601.string(from: createdAt)
            guard sqlite3_bind_text(statement, 6, text, -1, Self.sqliteTransient) == SQLITE_OK else { throw databaseError() }
        } else {
            guard sqlite3_bind_null(statement, 6) == SQLITE_OK else { throw databaseError() }
        }
        guard sqlite3_bind_int(statement, 7, Int32(metadata.label)) == SQLITE_OK else { throw databaseError() }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func delete(path: Data) throws {
        var statement: OpaquePointer?
        try prepare("DELETE FROM file_metadata WHERE scope=? AND path=?", &statement)
        defer { sqlite3_finalize(statement) }
        try bindScope(statement, index: 1)
        try bindBlob(statement, index: 2, data: path)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? databaseErrorMessage()
            sqlite3_free(error)
            throw ServerFileMetadataStoreError.database(message)
        }
    }

    private func prepare(_ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func bindScope(_ statement: OpaquePointer?, index: Int32) throws {
        guard sqlite3_bind_int(statement, index, scope.rawValue) == SQLITE_OK else { throw databaseError() }
    }

    private func bindBlob(_ statement: OpaquePointer?, index: Int32, data: Data) throws {
        let result: Int32
        if data.isEmpty {
            result = sqlite3_bind_zeroblob(statement, index, 0)
        } else {
            result = data.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.sqliteTransient)
            }
        }
        guard result == SQLITE_OK else { throw databaseError() }
    }

    private func columnBlob(_ statement: OpaquePointer?, index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func databaseError() -> ServerFileMetadataStoreError { .database(databaseErrorMessage()) }
    private func databaseErrorMessage() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is unavailable" }

    private func isDescendant(_ candidate: Data, of parent: Data) -> Bool {
        guard candidate.count > parent.count else { return false }
        if parent.isEmpty { return true }
        guard candidate.starts(with: parent) else { return false }
        return candidate[parent.count] == LegacyPath.separator
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
