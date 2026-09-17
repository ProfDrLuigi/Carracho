import Foundation
import Dispatch
import SQLite3

enum ServerFlatNewsStoreError: LocalizedError {
    case unsupportedFormat(Int)
    case invalidIndex(UInt32)
    case invalidEntry(String)
    case database(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(version): return "Unsupported flat-news format version \(version)."
        case let .invalidIndex(index): return "Flat-news entry \(index) does not exist."
        case let .invalidEntry(message): return message
        case let .database(message): return "Flat-news database error: \(message)"
        }
    }
}

/// Classic single-stream News stored in the shared dedicated `news.db`.
final class ServerFlatNewsStore {
    private struct LegacyManifest: Codable {
        static let currentFormatVersion = 1
        var formatVersion = currentFormatVersion
        var entries: [Data] = []
    }

    let databaseURL: URL
    let legacyURL: URL?
    let classicURL: URL?
    private let queue = DispatchQueue(label: "com.carracho.server-flat-news-store")
    private let manager = FileManager.default
    private var database: OpaquePointer?
    private var initialized = false

    /// Compatibility initializer. A legacy `.json` URL is migrated to sibling
    /// `news.db`; a `.db` URL is used directly.
    convenience init(url: URL) {
        if url.pathExtension.lowercased() == "db" { self.init(databaseURL: url, legacyURL: nil, classicURL: nil) }
        else { self.init(databaseURL: url.deletingLastPathComponent().appendingPathComponent("news.db"), legacyURL: url, classicURL: nil) }
    }

    init(databaseURL: URL, legacyURL: URL? = nil, classicURL: URL? = nil) {
        self.databaseURL = databaseURL
        self.legacyURL = legacyURL
        self.classicURL = classicURL
    }

    deinit {
        queue.sync { if let database { sqlite3_close(database) }; database = nil }
    }

    func all() throws -> [Data] {
        try queue.sync {
            let db = try db(); var result: [Data] = []
            try statement(db, "SELECT entry FROM flat_news ORDER BY sequence") { stmt in
                while true {
                    let rc = sqlite3_step(stmt); if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW else { throw databaseError(db) }
                    result.append(blob(stmt, 0))
                }
            }
            return result
        }
    }

    @discardableResult
    func append(_ entry: Data) throws -> UInt32 {
        try queue.sync {
            guard !entry.isEmpty, entry.count <= Int(UInt16.max) else {
                throw ServerFlatNewsStoreError.invalidEntry("Flat-news entries must be 1…65535 bytes.")
            }
            let db = try db()
            try statement(db, "INSERT INTO flat_news(entry) VALUES(?)") { stmt in
                bindBlob(stmt, 1, entry); try stepDone(stmt, db: db)
            }
            var count: UInt32 = 0
            try statement(db, "SELECT COUNT(*) FROM flat_news") { stmt in
                guard sqlite3_step(stmt) == SQLITE_ROW else { throw databaseError(db) }
                let raw = sqlite3_column_int64(stmt, 0)
                guard raw <= Int64(UInt32.max) else { throw ServerFlatNewsStoreError.invalidEntry("Flat-news entry count exhausted.") }
                count = UInt32(raw)
            }
            return count
        }
    }

    @discardableResult
    func delete(wireIndex: UInt32) throws -> Data {
        try queue.sync {
            guard wireIndex > 0 else { throw ServerFlatNewsStoreError.invalidIndex(wireIndex) }
            let db = try db(); var sequence: Int64?, removed: Data?
            try statement(db, "SELECT sequence,entry FROM flat_news ORDER BY sequence LIMIT 1 OFFSET ?") { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(wireIndex - 1))
                guard sqlite3_step(stmt) == SQLITE_ROW else { throw ServerFlatNewsStoreError.invalidIndex(wireIndex) }
                sequence = sqlite3_column_int64(stmt, 0); removed = blob(stmt, 1)
            }
            guard let sequence, let removed else { throw ServerFlatNewsStoreError.invalidIndex(wireIndex) }
            try statement(db, "DELETE FROM flat_news WHERE sequence=?") { stmt in
                sqlite3_bind_int64(stmt, 1, sequence); try stepDone(stmt, db: db)
            }
            return removed
        }
    }

    func clear() throws {
        try queue.sync { try ServerNewsDatabaseSchema.exec(try db(), "DELETE FROM flat_news;") }
    }

    private func db() throws -> OpaquePointer {
        if let database, initialized { return database }
        try manager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            let text = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(databaseURL.path)"
            if let handle { sqlite3_close(handle) }
            throw ServerFlatNewsStoreError.database(text)
        }
        database = handle
        do {
            try ServerNewsDatabaseSchema.configure(handle)
            try migrateLegacyIfNeeded(db: handle)
            try migrateClassicIfNeeded(db: handle)
            initialized = true
            return handle
        } catch {
            sqlite3_close(handle); database = nil; initialized = false; throw error
        }
    }

    private func migrateLegacyIfNeeded(db: OpaquePointer) throws {
        let marker = try ServerNewsDatabaseSchema.scalarText(db, "SELECT value FROM news_meta WHERE key='flat_legacy_migrated_v1'")
        guard marker == nil else { return }
        guard let legacyURL, manager.fileExists(atPath: legacyURL.path) else {
            try ServerNewsDatabaseSchema.exec(db, "INSERT OR REPLACE INTO news_meta(key,value) VALUES('flat_legacy_migrated_v1','1');")
            return
        }
        let manifest = try JSONDecoder().decode(LegacyManifest.self, from: Data(contentsOf: legacyURL))
        guard manifest.formatVersion == LegacyManifest.currentFormatVersion else {
            throw ServerFlatNewsStoreError.unsupportedFormat(manifest.formatVersion)
        }
        try ServerNewsDatabaseSchema.exec(db, "BEGIN IMMEDIATE;")
        do {
            var existing = 0
            try statement(db, "SELECT COUNT(*) FROM flat_news") { stmt in
                guard sqlite3_step(stmt) == SQLITE_ROW else { throw databaseError(db) }
                existing = Int(sqlite3_column_int64(stmt, 0))
            }
            if existing == 0 {
                for entry in manifest.entries {
                    guard !entry.isEmpty, entry.count <= Int(UInt16.max) else {
                        throw ServerFlatNewsStoreError.invalidEntry("Stored flat-news data contains an invalid entry.")
                    }
                    try statement(db, "INSERT INTO flat_news(entry) VALUES(?)") { stmt in bindBlob(stmt, 1, entry); try stepDone(stmt, db: db) }
                }
            }
            try ServerNewsDatabaseSchema.exec(db, "INSERT OR REPLACE INTO news_meta(key,value) VALUES('flat_legacy_migrated_v1','1');")
            try ServerNewsDatabaseSchema.exec(db, "COMMIT;")
        } catch {
            try? ServerNewsDatabaseSchema.exec(db, "ROLLBACK;"); throw error
        }
        try? manager.removeItem(at: legacyURL)
    }

    /// Carracho Server 1.0 stored Flat News in `News/Flat News` as a native PowerPC
    /// big-endian count followed by repeated big-endian length + MacRoman byte strings.
    /// Keep the source file intact after import; the database marker prevents duplicates and
    /// preserving original Classic data is preferable to pretending migrations never go wrong.
    private func migrateClassicIfNeeded(db: OpaquePointer) throws {
        let markerKey = "flat_classic_migrated_v1"
        let marker = try ServerNewsDatabaseSchema.scalarText(db, "SELECT value FROM news_meta WHERE key='\(markerKey)'")
        guard marker == nil else { return }
        guard let classicURL, manager.fileExists(atPath: classicURL.path) else {
            try ServerNewsDatabaseSchema.exec(db, "INSERT OR REPLACE INTO news_meta(key,value) VALUES('\(markerKey)','1');")
            return
        }

        let source = try Data(contentsOf: classicURL, options: [.mappedIfSafe])
        let entries = try Self.decodeClassicFlatNews(source)
        try ServerNewsDatabaseSchema.exec(db, "BEGIN IMMEDIATE;")
        do {
            var existing = 0
            try statement(db, "SELECT COUNT(*) FROM flat_news") { stmt in
                guard sqlite3_step(stmt) == SQLITE_ROW else { throw databaseError(db) }
                existing = Int(sqlite3_column_int64(stmt, 0))
            }
            if existing == 0 {
                for entry in entries {
                    try statement(db, "INSERT INTO flat_news(entry) VALUES(?)") { stmt in
                        bindBlob(stmt, 1, entry)
                        try stepDone(stmt, db: db)
                    }
                }
            }
            try ServerNewsDatabaseSchema.exec(db, "INSERT OR REPLACE INTO news_meta(key,value) VALUES('\(markerKey)','1');")
            try ServerNewsDatabaseSchema.exec(db, "COMMIT;")
        } catch {
            try? ServerNewsDatabaseSchema.exec(db, "ROLLBACK;")
            throw error
        }
    }

    private static func decodeClassicFlatNews(_ data: Data) throws -> [Data] {
        var offset = 0
        func readUInt32() throws -> UInt32 {
            guard offset <= data.count - 4 else {
                throw ServerFlatNewsStoreError.invalidEntry("Classic News/Flat News is truncated.")
            }
            let value = data.withUnsafeBytes { raw -> UInt32 in
                let bytes = raw.bindMemory(to: UInt8.self)
                return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
                    UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            }
            offset += 4
            return value
        }

        let count = try readUInt32()
        // Each entry requires at least a 4-byte length. This also prevents a corrupt count
        // from turning a tiny file into a heroic allocation attempt.
        guard UInt64(count) <= UInt64((data.count - offset) / 4) else {
            throw ServerFlatNewsStoreError.invalidEntry("Classic News/Flat News contains an invalid entry count.")
        }
        var result: [Data] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            let length = try readUInt32()
            guard length > 0, length <= UInt32(UInt16.max), UInt64(length) <= UInt64(data.count - offset) else {
                throw ServerFlatNewsStoreError.invalidEntry("Classic News/Flat News contains an invalid entry length.")
            }
            let end = offset + Int(length)
            result.append(data.subdata(in: offset..<end))
            offset = end
        }
        guard offset == data.count else {
            throw ServerFlatNewsStoreError.invalidEntry("Classic News/Flat News contains trailing data.")
        }
        return result
    }

    private func statement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw databaseError(db) }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }
    private func stepDone(_ stmt: OpaquePointer, db: OpaquePointer) throws { guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError(db) } }
    private func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ value: Data) { _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), carrachoSQLiteTransient) } }
    private func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data { let count = Int(sqlite3_column_bytes(stmt, index)); guard count > 0, let bytes = sqlite3_column_blob(stmt, index) else { return Data() }; return Data(bytes: bytes, count: count) }
    private func databaseError(_ db: OpaquePointer) -> ServerFlatNewsStoreError { .database(String(cString: sqlite3_errmsg(db))) }
}
