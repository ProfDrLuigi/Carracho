import Foundation
import SQLite3

enum ServerFileSearchIndexError: LocalizedError {
    case sqlite(String)
    case invalidPath
    case invalidName

    var errorDescription: String? {
        switch self {
        case let .sqlite(message): return "File-search index error: \(message)"
        case .invalidPath: return "File-search index encountered an invalid Classic path."
        case .invalidName: return "File-search index encountered a filename that cannot be represented in MacRoman."
        }
    }
}

struct ServerFileSearchIndexEntry: Equatable {
    var path: Data
    var name: Data
    var isFolder: Bool
    var size: UInt32
    var timestamp: UInt32
}

/// Rebuildable server-side search cache. The canonical data remains the Files tree
/// plus ServerFileMetadataStore; this database may be deleted at any time and is
/// rebuilt on the next server start.
final class ServerFileSearchIndex {
    static let schemaVersion = 2
    static let maximumResults = 100_000
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let macEpochOffset: TimeInterval = 2_082_844_800

    private static func isTransferStagingName(_ name: String) -> Bool {
        name.hasSuffix(".carracho") || name.hasPrefix(".carracho.")
    }

    /// Stable filesystem identity used to stop recursion if the same directory is reachable
    /// through more than one path (for example a bind/directory mount cycle). Symlinks are
    /// rejected separately before recursion; this is a second line of defence.
    static func directoryIdentityKey(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        return "\(device):\(inode)"
    }

    let url: URL
    private let exclusionPatterns: [String]
    private let queue = DispatchQueue(label: "com.carracho.server-file-search-index", qos: .utility)

    init(url: URL, exclusionPatterns: [String] = []) {
        self.url = url
        self.exclusionPatterns = exclusionPatterns
    }

    static func globMatches(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        var memo: [Int: Bool] = [:]
        func solve(_ pi: Int, _ ni: Int) -> Bool {
            let key = pi * 65_537 + ni
            if let cached = memo[key] { return cached }
            let result: Bool
            if pi == p.count {
                result = ni == n.count
            } else if p[pi] == "*" {
                result = solve(pi + 1, ni) || (ni < n.count && solve(pi, ni + 1))
            } else if p[pi] == "?" {
                result = ni < n.count && solve(pi + 1, ni + 1)
            } else {
                result = ni < n.count && p[pi] == n[ni] && solve(pi + 1, ni + 1)
            }
            memo[key] = result
            return result
        }
        return solve(0, 0)
    }

    func excludesName(_ name: String) -> Bool {
        exclusionPatterns.contains { Self.globMatches($0, name) }
    }

    func excludesPath(_ path: Data) -> Bool {
        guard !path.isEmpty else { return false }
        var start = path.startIndex
        for end in path.indices where path[end] == LegacyPath.separator {
            let part = path[start..<end]
            if let name = String(data: Data(part), encoding: .macOSRoman), excludesName(name) { return true }
            start = path.index(after: end)
        }
        let part = path[start..<path.endIndex]
        return String(data: Data(part), encoding: .macOSRoman).map(excludesName) ?? false
    }

    private func isInsideDropbox(_ path: Data, metadata: ServerFileMetadataStore?) -> Bool {
        guard let metadata, !path.isEmpty else { return false }
        var prefixEnd = path.startIndex
        while prefixEnd < path.endIndex {
            if path[prefixEnd] == LegacyPath.separator {
                let prefix = Data(path[..<prefixEnd])
                if (metadata.metadata(for: prefix)?.flags ?? 0) & LegacyDirectoryFlags.dropBox != 0 {
                    return true
                }
            }
            prefixEnd = path.index(after: prefixEnd)
        }
        return (metadata.metadata(for: path)?.flags ?? 0) & LegacyDirectoryFlags.dropBox != 0
    }

    func rebuild(storageRoot: URL, metadata: ServerFileMetadataStore?) throws {
        try queue.sync {
            let db = try openDatabase(); defer { sqlite3_close(db) }
            try createSchema(db)
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try execute(db, "DELETE FROM trigrams")
                try execute(db, "DELETE FROM entries")
                if FileManager.default.fileExists(atPath: storageRoot.path) {
                    var visitedDirectories = Set<String>()
                    if let identity = Self.directoryIdentityKey(storageRoot) { visitedDirectories.insert(identity) }
                    try indexChildren(of: storageRoot, legacyParent: Data(), db: db, metadata: metadata,
                                      visitedDirectories: &visitedDirectories)
                }
                let rebuiltAt = Int64(Date().timeIntervalSince1970)
                try setMetadataInteger(db, key: "last_full_rebuild_unix", value: rebuiltAt)
                try setMetadataInteger(db, key: "schedule_anchor_unix", value: rebuiltAt)
                try execute(db, "COMMIT")
                try compactAfterFullRebuild(db)
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    func upsertSubtree(at fileURL: URL, path: Data, metadata: ServerFileMetadataStore?) throws {
        try queue.sync {
            let db = try openDatabase(); defer { sqlite3_close(db) }
            try createSchema(db)
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try deleteSubtree(path: path, db: db)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    var visitedDirectories = Set<String>()
                    try indexItem(at: fileURL, path: path, db: db, metadata: metadata, recurse: true,
                                  visitedDirectories: &visitedDirectories)
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    func removeSubtree(path: Data) throws {
        try queue.sync {
            let db = try openDatabase(); defer { sqlite3_close(db) }
            try createSchema(db)
            try deleteSubtree(path: path, db: db)
        }
    }

    func moveSubtree(from source: Data, to destination: Data, destinationURL: URL,
                     metadata: ServerFileMetadataStore?) throws {
        try queue.sync {
            let db = try openDatabase(); defer { sqlite3_close(db) }
            try createSchema(db)
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try deleteSubtree(path: source, db: db)
                try deleteSubtree(path: destination, db: db)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    var visitedDirectories = Set<String>()
                    try indexItem(at: destinationURL, path: destination, db: db, metadata: metadata, recurse: true,
                                  visitedDirectories: &visitedDirectories)
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    func search(_ query: Data) throws -> [ServerFileSearchIndexEntry] {
        try queue.sync {
            guard let raw = String(data: query, encoding: .macOSRoman), !raw.isEmpty else {
                throw ServerFileSearchIndexError.invalidName
            }
            let needle = Self.fold(raw)
            let grams = Self.trigrams(needle)
            let db = try openDatabase(); defer { sqlite3_close(db) }
            try createSchema(db)

            let sql: String
            if grams.isEmpty {
                sql = """
                SELECT path,name,is_folder,size,timestamp
                FROM entries
                WHERE instr(name_search, ?) > 0
                ORDER BY path
                LIMIT ?
                """
            } else {
                let placeholders = Array(repeating: "?", count: grams.count).joined(separator: ",")
                sql = """
                SELECT e.path,e.name,e.is_folder,e.size,e.timestamp
                FROM entries e
                JOIN (
                    SELECT entry_id
                    FROM trigrams
                    WHERE term IN (\(placeholders))
                    GROUP BY entry_id
                    HAVING COUNT(DISTINCT term) = ?
                ) candidates ON candidates.entry_id = e.id
                WHERE instr(e.name_search, ?) > 0
                ORDER BY e.path
                LIMIT ?
                """
            }

            var statement: OpaquePointer?
            try prepare(db, sql, &statement); defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            if !grams.isEmpty {
                for gram in grams {
                    try bindText(statement, bindIndex, gram); bindIndex += 1
                }
                try bindInt64(statement, bindIndex, Int64(grams.count)); bindIndex += 1
            }
            try bindText(statement, bindIndex, needle); bindIndex += 1
            try bindInt64(statement, bindIndex, Int64(Self.maximumResults + 1))

            var results: [ServerFileSearchIndexEntry] = []
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw sqliteError(db) }
                guard let path = blob(statement, 0), let name = blob(statement, 1) else {
                    throw ServerFileSearchIndexError.sqlite("indexed path/name is NULL")
                }
                let folder = sqlite3_column_int(statement, 2) != 0
                let size = UInt32(clamping: sqlite3_column_int64(statement, 3))
                let timestamp = UInt32(clamping: sqlite3_column_int64(statement, 4))
                if !excludesPath(path) {
                    results.append(.init(path: path, name: name, isFolder: folder, size: size, timestamp: timestamp))
                }
            }
            guard results.count <= Self.maximumResults else {
                throw ServerFileSearchIndexError.sqlite("file-search result limit exceeded")
            }
            return results
        }
    }

    func entryCount() throws -> Int {
        try queue.sync {
            let db = try openDatabase(); defer { sqlite3_close(db) }
            try createSchema(db)
            var statement: OpaquePointer?
            try prepare(db, "SELECT COUNT(*) FROM entries", &statement); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func lastFullRebuildDate() throws -> Date? {
        try queue.sync {
            let db = try openDatabase(); defer { sqlite3_close(db) }
            try createSchema(db)
            return try metadataDate(db, key: "last_full_rebuild_unix")
        }
    }

    /// Persistent reference used by the automatic rebuild scheduler. Existing pre-scheduler
    /// indexes get an anchor when first observed so restarts cannot postpone the interval forever.
    func rebuildScheduleReferenceDate(now: Date = Date()) throws -> Date {
        try queue.sync {
            let db = try openDatabase(); defer { sqlite3_close(db) }
            try createSchema(db)
            if let full = try metadataDate(db, key: "last_full_rebuild_unix") { return full }
            if let anchor = try metadataDate(db, key: "schedule_anchor_unix") { return anchor }
            let value = Int64(now.timeIntervalSince1970)
            try setMetadataInteger(db, key: "schedule_anchor_unix", value: value)
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
    }

    private func indexChildren(of directory: URL, legacyParent: Data, db: OpaquePointer?,
                               metadata: ServerFileMetadataStore?,
                               visitedDirectories: inout Set<String>) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey]
        let children = try FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: Array(keys),
                                                                   options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        for child in children {
            guard !Self.isTransferStagingName(child.lastPathComponent), !excludesName(child.lastPathComponent) else { continue }
            guard let name = child.lastPathComponent.data(using: .macOSRoman),
                  !name.isEmpty, name.count <= 255 else { continue }
            let path: Data
            do { path = try LegacyPath.child(parent: legacyParent, name: name) }
            catch { continue }
            guard path.count <= LegacyPath.maximumWireLength else { continue }
            try indexItem(at: child, path: path, db: db, metadata: metadata, recurse: true,
                          visitedDirectories: &visitedDirectories)
        }
    }

    private func indexItem(at fileURL: URL, path: Data, db: OpaquePointer?,
                           metadata: ServerFileMetadataStore?, recurse: Bool,
                           visitedDirectories: inout Set<String>) throws {
        guard !Self.isTransferStagingName(fileURL.lastPathComponent),
              !excludesName(fileURL.lastPathComponent), !excludesPath(path) else { return }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey]
        let originalValues = try fileURL.resourceValues(forKeys: keys)
        let effectiveURL = originalValues.isSymbolicLink == true
            ? fileURL.resolvingSymlinksInPath().standardizedFileURL
            : fileURL
        let values = try effectiveURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                                 .fileSizeKey, .contentModificationDateKey])
        guard values.isDirectory == true || values.isRegularFile == true else { return }
        guard let name = fileURL.lastPathComponent.data(using: .macOSRoman),
              !name.isEmpty, name.count <= 255 else { return }

        let isFolder = values.isDirectory == true
        // Exclude the Dropbox directory itself and every descendant. Checking
        // ancestors here also closes the incremental-upload path, where the
        // indexer may be asked to upsert a file directly below a Dropbox.
        if isInsideDropbox(path, metadata: metadata) { return }
        let rawSize = UInt64(max(values.fileSize ?? 0, 0))
        let size = isFolder ? UInt32(0) : UInt32(min(rawSize, UInt64(UInt32.max)))
        let timestamp: UInt32
        if let date = values.contentModificationDate {
            let classic = max(0, date.timeIntervalSince1970 + Self.macEpochOffset)
            timestamp = UInt32(min(classic, TimeInterval(UInt32.max)))
        } else { timestamp = 0 }
        let comment = metadata?.metadata(for: path)?.comment ?? Data()
        let commentString = String(data: comment, encoding: .macOSRoman) ?? ""
        let nameString = String(data: name, encoding: .macOSRoman) ?? fileURL.lastPathComponent
        try insert(path: path, name: name, nameSearch: Self.fold(nameString),
                   commentSearch: Self.fold(commentString), isFolder: isFolder,
                   size: size, timestamp: timestamp, db: db)

        if isFolder, recurse {
            if let identity = Self.directoryIdentityKey(effectiveURL),
               !visitedDirectories.insert(identity).inserted {
                return
            }
            try indexChildren(of: effectiveURL, legacyParent: path, db: db, metadata: metadata,
                              visitedDirectories: &visitedDirectories)
        }
    }

    private func insert(path: Data, name: Data, nameSearch: String, commentSearch: String,
                        isFolder: Bool, size: UInt32, timestamp: UInt32, db: OpaquePointer?) throws {
        var statement: OpaquePointer?
        try prepare(db, """
            INSERT INTO entries(path,name,name_search,comment_search,is_folder,size,timestamp)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                name=excluded.name,
                name_search=excluded.name_search,
                comment_search=excluded.comment_search,
                is_folder=excluded.is_folder,
                size=excluded.size,
                timestamp=excluded.timestamp
            """, &statement)
        defer { sqlite3_finalize(statement) }
        try bindBlob(statement, 1, path)
        try bindBlob(statement, 2, name)
        try bindText(statement, 3, nameSearch)
        try bindText(statement, 4, commentSearch)
        try bindInt64(statement, 5, isFolder ? 1 : 0)
        try bindInt64(statement, 6, Int64(size))
        try bindInt64(statement, 7, Int64(timestamp))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }

        var lookup: OpaquePointer?
        try prepare(db, "SELECT id FROM entries WHERE path=?", &lookup)
        try bindBlob(lookup, 1, path)
        guard sqlite3_step(lookup) == SQLITE_ROW else {
            sqlite3_finalize(lookup)
            throw sqliteError(db)
        }
        let entryID = sqlite3_column_int64(lookup, 0)
        sqlite3_finalize(lookup)

        var delete: OpaquePointer?
        try prepare(db, "DELETE FROM trigrams WHERE entry_id=?", &delete)
        try bindInt64(delete, 1, entryID)
        guard sqlite3_step(delete) == SQLITE_DONE else {
            sqlite3_finalize(delete)
            throw sqliteError(db)
        }
        sqlite3_finalize(delete)

        let grams = Self.trigrams(nameSearch)
        if !grams.isEmpty {
            var gramStatement: OpaquePointer?
            try prepare(db, "INSERT OR IGNORE INTO trigrams(term,entry_id) VALUES(?,?)", &gramStatement)
            defer { sqlite3_finalize(gramStatement) }
            for gram in grams {
                sqlite3_reset(gramStatement); sqlite3_clear_bindings(gramStatement)
                try bindText(gramStatement, 1, gram)
                try bindInt64(gramStatement, 2, entryID)
                guard sqlite3_step(gramStatement) == SQLITE_DONE else { throw sqliteError(db) }
            }
        }
    }

    private func deleteSubtree(path: Data, db: OpaquePointer?) throws {
        if path.isEmpty {
            try execute(db, "DELETE FROM entries")
            return
        }
        var descendantLower = path
        descendantLower.append(LegacyPath.separator)
        var descendantUpper = path
        descendantUpper.append(LegacyPath.separator &+ 1)

        var statement: OpaquePointer?
        try prepare(db, "DELETE FROM entries WHERE path=? OR (path>=? AND path<?)", &statement)
        defer { sqlite3_finalize(statement) }
        try bindBlob(statement, 1, path)
        try bindBlob(statement, 2, descendantLower)
        try bindBlob(statement, 3, descendantUpper)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    private func openDatabase() throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite open error"
            if let db { sqlite3_close(db) }
            throw ServerFileSearchIndexError.sqlite(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        return db
    }

    private func createSchema(_ db: OpaquePointer?) throws {
        try execute(db, "PRAGMA foreign_keys=ON")
        try execute(db, "PRAGMA journal_mode=WAL")
        try execute(db, "PRAGMA synchronous=NORMAL")

        let existingVersion = try pragmaInteger(db, "user_version")
        if existingVersion != Self.schemaVersion {
            // The search database is a disposable cache. Schema v1 repeated a hex-encoded
            // full path in every trigram row and also maintained a redundant identical index,
            // which could inflate large trees into multi-gigabyte databases. Recreate instead
            // of carrying that storage layout forward.
            try execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try execute(db, "DROP TABLE IF EXISTS trigrams")
                try execute(db, "DROP TABLE IF EXISTS entries")
                try execute(db, "DROP TABLE IF EXISTS index_meta")
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
            let pageCount = try pragmaInteger(db, "page_count")
            let freePages = try pragmaInteger(db, "freelist_count")
            if pageCount > 32, freePages * 2 >= pageCount {
                try execute(db, "VACUUM")
            }
        }

        try execute(db, """
            CREATE TABLE IF NOT EXISTS entries(
                id INTEGER PRIMARY KEY,
                path BLOB NOT NULL UNIQUE,
                name BLOB NOT NULL,
                name_search TEXT NOT NULL,
                comment_search TEXT NOT NULL DEFAULT '',
                is_folder INTEGER NOT NULL CHECK(is_folder IN (0,1)),
                size INTEGER NOT NULL,
                timestamp INTEGER NOT NULL
            )
            """)
        try execute(db, """
            CREATE TABLE IF NOT EXISTS trigrams(
                term TEXT NOT NULL,
                entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                PRIMARY KEY(term,entry_id)
            ) WITHOUT ROWID
            """)
        try execute(db, """
            CREATE TABLE IF NOT EXISTS index_meta(
                key TEXT PRIMARY KEY,
                value INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
        try execute(db, "PRAGMA user_version=\(Self.schemaVersion)")
    }

    private func metadataDate(_ db: OpaquePointer?, key: String) throws -> Date? {
        var statement: OpaquePointer?
        try prepare(db, "SELECT value FROM index_meta WHERE key=?", &statement)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, key)
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw sqliteError(db) }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
    }

    private func setMetadataInteger(_ db: OpaquePointer?, key: String, value: Int64) throws {
        var statement: OpaquePointer?
        try prepare(db, """
            INSERT INTO index_meta(key,value) VALUES(?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """, &statement)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, key)
        try bindInt64(statement, 2, value)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    private func compactAfterFullRebuild(_ db: OpaquePointer?) throws {
        let pageCount = try pragmaInteger(db, "page_count")
        let freePages = try pragmaInteger(db, "freelist_count")
        // Reclaim only substantial waste: at least ~1 MiB at the usual 4 KiB page size
        // and at least 25% of the database. This also repairs a previously bloated index.
        if freePages >= 256, pageCount > 0, freePages * 4 >= pageCount {
            try execute(db, "VACUUM")
        }
        // A full rebuild can generate a large reusable WAL even when the final index is small.
        try execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func pragmaInteger(_ db: OpaquePointer?, _ name: String) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(db, "PRAGMA \(name)", &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
        return sqlite3_column_int64(statement, 0)
    }

    private func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError(db) }
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError(db) }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ text: String) throws {
        guard sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw ServerFileSearchIndexError.sqlite("could not bind text")
        }
    }

    private func bindBlob(_ statement: OpaquePointer?, _ index: Int32, _ data: Data) throws {
        let rc = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(data.count), Self.sqliteTransient)
        }
        guard rc == SQLITE_OK else { throw ServerFileSearchIndexError.sqlite("could not bind blob") }
    }

    private func bindInt64(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw ServerFileSearchIndexError.sqlite("could not bind integer")
        }
    }

    private func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        if count == 0 { return Data() }
        guard let ptr = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: ptr, count: count)
    }

    private func sqliteError(_ db: OpaquePointer?) -> ServerFileSearchIndexError {
        .sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error")
    }

    private static func fold(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func trigrams(_ value: String) -> [String] {
        let characters = Array(value)
        guard characters.count >= 3 else { return [] }
        var unique = Set<String>()
        for index in 0...(characters.count - 3) {
            unique.insert(String(characters[index...index + 2]))
        }
        return unique.sorted()
    }

}
