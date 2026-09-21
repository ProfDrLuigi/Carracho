import Foundation
import CryptoKit
import ImageIO
import SQLite3

struct ServerMediaObject: Equatable {
    var id: UUID
    var ownerAccountID: UUID
    var mimeType: String
    var filename: String
    var byteCount: Int
    var width: Int
    var height: Int
    var sha256: String
    var createdAt: Date
    var expiresAt: Date?
    var data: Data
}

enum ServerMediaReferenceKind: Int32 {
    case chat = 1
    case news = 2
    case privateMessage = 3
}

enum ServerMediaStoreError: Error, LocalizedError {
    case invalidImage(String)
    case database(String)
    case notFound
    case ownership

    var errorDescription: String? {
        switch self {
        case let .invalidImage(message): return "Media image is invalid: \(message)"
        case let .database(message): return "Media database error: \(message)"
        case .notFound: return "Media object was not found."
        case .ownership: return "Media object is not owned by this account."
        }
    }
}

final class ServerMediaStore {
    let databaseURL: URL
    let objectsRoot: URL
    private let queue = DispatchQueue(label: "com.carracho.server-media-store")
    private var database: OpaquePointer?
    private let manager = FileManager.default

    init(databaseURL: URL, objectsRoot: URL) {
        self.databaseURL = databaseURL
        self.objectsRoot = objectsRoot
    }

    deinit {
        queue.sync {
            if let database { sqlite3_close(database) }
            database = nil
        }
    }

    @discardableResult
    func storePending(ownerAccountID: UUID, filename: String, data: Data, now: Date = Date()) throws -> ServerMediaObject {
        try queue.sync {
            guard !data.isEmpty, data.count <= LegacyMediaTransfer.maximumImageBytes else {
                throw ServerMediaStoreError.invalidImage("image must be 1…\(LegacyMediaTransfer.maximumImageBytes) bytes")
            }
            let image = try Self.inspectImage(data)
            let cleanFilename = Self.cleanFilename(filename, mimeType: image.mimeType)
            let id = UUID()
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let relative = "\(id.uuidString.prefix(2).lowercased())/\(id.uuidString.lowercased()).bin"
            let url = objectsRoot.appendingPathComponent(relative)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            let db = try openDatabase()
            do {
                try statement(db, "INSERT INTO media_objects(id,owner_account_id,mime_type,filename,byte_count,width,height,sha256,created_at,expires_at,relative_path) VALUES(?,?,?,?,?,?,?,?,?,?,?)") { stmt in
                    bindText(stmt, 1, id.uuidString.lowercased())
                    bindText(stmt, 2, ownerAccountID.uuidString.lowercased())
                    bindText(stmt, 3, image.mimeType)
                    bindText(stmt, 4, cleanFilename)
                    sqlite3_bind_int64(stmt, 5, Int64(data.count))
                    sqlite3_bind_int(stmt, 6, Int32(image.width))
                    sqlite3_bind_int(stmt, 7, Int32(image.height))
                    bindText(stmt, 8, sha)
                    sqlite3_bind_double(stmt, 9, now.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 10, now.addingTimeInterval(LegacyMediaTransfer.pendingLifetime).timeIntervalSince1970)
                    bindText(stmt, 11, relative)
                    try stepDone(stmt, db: db)
                }
            } catch {
                try? manager.removeItem(at: url)
                throw error
            }
            return ServerMediaObject(id: id, ownerAccountID: ownerAccountID, mimeType: image.mimeType,
                                     filename: cleanFilename, byteCount: data.count, width: image.width, height: image.height,
                                     sha256: sha, createdAt: now,
                                     expiresAt: now.addingTimeInterval(LegacyMediaTransfer.pendingLifetime), data: data)
        }
    }

    func load(id: UUID) throws -> ServerMediaObject {
        try queue.sync { try loadLocked(id: id, db: openDatabase()) }
    }

    func isOwned(id: UUID, by ownerAccountID: UUID) throws -> Bool {
        try queue.sync {
            let db = try openDatabase()
            var result = false
            try statement(db, "SELECT 1 FROM media_objects WHERE id=? AND owner_account_id=? LIMIT 1") { stmt in
                bindText(stmt, 1, id.uuidString.lowercased()); bindText(stmt, 2, ownerAccountID.uuidString.lowercased())
                result = sqlite3_step(stmt) == SQLITE_ROW
            }
            return result
        }
    }

    /// Permanently removes an object owned by the requesting account. The media row is deleted
    /// (cascading every reference) and the object file is removed immediately rather than waiting
    /// for the normal orphan-expiry pass.
    func deleteOwned(id: UUID, by ownerAccountID: UUID) throws {
        try queue.sync {
            let db = try openDatabase()
            var row: (owner: String, relativePath: String)?
            try statement(db, "SELECT owner_account_id,relative_path FROM media_objects WHERE id=? LIMIT 1") { stmt in
                bindText(stmt, 1, id.uuidString.lowercased())
                if sqlite3_step(stmt) == SQLITE_ROW { row = (columnText(stmt, 0), columnText(stmt, 1)) }
            }
            guard let row else { throw ServerMediaStoreError.notFound }
            guard row.owner.caseInsensitiveCompare(ownerAccountID.uuidString) == .orderedSame else {
                throw ServerMediaStoreError.ownership
            }

            let url = objectsRoot.appendingPathComponent(row.relativePath)
            let quarantine = url.deletingLastPathComponent()
                .appendingPathComponent(".delete-\(id.uuidString.lowercased())-\(UUID().uuidString.lowercased())")
            var quarantined = false
            if manager.fileExists(atPath: url.path) {
                try manager.moveItem(at: url, to: quarantine)
                quarantined = true
            }

            do {
                try exec(db, "BEGIN IMMEDIATE;")
                try statement(db, "DELETE FROM media_objects WHERE id=? AND owner_account_id=?") { stmt in
                    bindText(stmt, 1, id.uuidString.lowercased())
                    bindText(stmt, 2, ownerAccountID.uuidString.lowercased())
                    try stepDone(stmt, db: db)
                }
                guard sqlite3_changes(db) == 1 else { throw ServerMediaStoreError.ownership }
                try exec(db, "COMMIT;")
            } catch {
                try? exec(db, "ROLLBACK;")
                if quarantined { try? manager.moveItem(at: quarantine, to: url) }
                throw error
            }
            if quarantined { try manager.removeItem(at: quarantine) }
        }
    }

    func hasReference(id: UUID, kind: ServerMediaReferenceKind, scope: String) throws -> Bool {
        try queue.sync {
            let db = try openDatabase()
            var result = false
            try statement(db, "SELECT 1 FROM media_refs WHERE media_id=? AND kind=? AND scope=? LIMIT 1") { stmt in
                bindText(stmt, 1, id.uuidString.lowercased()); sqlite3_bind_int(stmt, 2, kind.rawValue); bindText(stmt, 3, scope)
                result = sqlite3_step(stmt) == SQLITE_ROW
            }
            return result
        }
    }

    func bind(ids: [UUID], ownerAccountID: UUID, kind: ServerMediaReferenceKind, scope: String,
              messageID: String, expiresAt: Date?) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            let db = try openDatabase()
            try exec(db, "BEGIN IMMEDIATE;")
            do {
                for id in ids {
                    var ownerOK = false
                    try statement(db, "SELECT 1 FROM media_objects WHERE id=? AND owner_account_id=? LIMIT 1") { stmt in
                        bindText(stmt, 1, id.uuidString.lowercased()); bindText(stmt, 2, ownerAccountID.uuidString.lowercased())
                        ownerOK = sqlite3_step(stmt) == SQLITE_ROW
                    }
                    guard ownerOK else { throw ServerMediaStoreError.ownership }
                    try statement(db, "INSERT OR IGNORE INTO media_refs(media_id,kind,scope,message_id,created_at,expires_at) VALUES(?,?,?,?,?,?)") { stmt in
                        bindText(stmt, 1, id.uuidString.lowercased()); sqlite3_bind_int(stmt, 2, kind.rawValue); bindText(stmt, 3, scope)
                        bindText(stmt, 4, messageID); sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
                        if let expiresAt { sqlite3_bind_double(stmt, 6, expiresAt.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 6) }
                        try stepDone(stmt, db: db)
                    }
                    try statement(db, "UPDATE media_objects SET expires_at=NULL WHERE id=?") { stmt in
                        bindText(stmt, 1, id.uuidString.lowercased()); try stepDone(stmt, db: db)
                    }
                }
                try exec(db, "COMMIT;")
            } catch {
                try? exec(db, "ROLLBACK;")
                throw error
            }
        }
    }

    func removeReferences(kind: ServerMediaReferenceKind, scope: String, messageIDs: Set<String>? = nil) throws {
        try queue.sync {
            let db = try openDatabase()
            if let messageIDs {
                for message in messageIDs {
                    try statement(db, "DELETE FROM media_refs WHERE kind=? AND scope=? AND message_id=?") { stmt in
                        sqlite3_bind_int(stmt, 1, kind.rawValue); bindText(stmt, 2, scope); bindText(stmt, 3, message); try stepDone(stmt, db: db)
                    }
                }
            } else {
                try statement(db, "DELETE FROM media_refs WHERE kind=? AND scope=?") { stmt in
                    sqlite3_bind_int(stmt, 1, kind.rawValue); bindText(stmt, 2, scope); try stepDone(stmt, db: db)
                }
            }
            try deleteUnreferencedLocked(db: db, now: Date())
        }
    }

    /// Removes one concrete reference while keeping other posts that may reuse the same media intact.
    /// Returns true when this was the object's last reference and the pool object/file was deleted.
    @discardableResult
    func removeReference(id: UUID, kind: ServerMediaReferenceKind, scope: String, messageID: String) throws -> Bool {
        try queue.sync {
            let db = try openDatabase()
            var existed = false
            try statement(db, "SELECT 1 FROM media_objects WHERE id=? LIMIT 1") { stmt in
                bindText(stmt, 1, id.uuidString.lowercased())
                existed = sqlite3_step(stmt) == SQLITE_ROW
            }
            try statement(db, "DELETE FROM media_refs WHERE media_id=? AND kind=? AND scope=? AND message_id=?") { stmt in
                bindText(stmt, 1, id.uuidString.lowercased())
                sqlite3_bind_int(stmt, 2, kind.rawValue)
                bindText(stmt, 3, scope)
                bindText(stmt, 4, messageID)
                try stepDone(stmt, db: db)
            }
            try deleteUnreferencedLocked(db: db, now: Date())
            guard existed else { return false }
            var remains = false
            try statement(db, "SELECT 1 FROM media_objects WHERE id=? LIMIT 1") { stmt in
                bindText(stmt, 1, id.uuidString.lowercased())
                remains = sqlite3_step(stmt) == SQLITE_ROW
            }
            return !remains
        }
    }

    func pruneNewsReferences(newsDatabaseURL: URL) throws {
        try queue.sync {
            let db = try openDatabase()
            var newsDB: OpaquePointer?
            guard sqlite3_open_v2(newsDatabaseURL.path, &newsDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let newsDB else { return }
            defer { sqlite3_close(newsDB) }
            var refs: [(String, String, String)] = []
            try statement(db, "SELECT media_id,scope,message_id FROM media_refs WHERE kind=?") { stmt in
                sqlite3_bind_int(stmt, 1, ServerMediaReferenceKind.news.rawValue)
                while sqlite3_step(stmt) == SQLITE_ROW { refs.append((columnText(stmt, 0), columnText(stmt, 1), columnText(stmt, 2))) }
            }
            var check: OpaquePointer?
            guard sqlite3_prepare_v2(newsDB, "SELECT 1 FROM news_articles WHERE group_id=? AND article_id=? LIMIT 1", -1, &check, nil) == SQLITE_OK, let check else { return }
            defer { sqlite3_finalize(check) }
            for (mediaID, scope, messageID) in refs {
                sqlite3_reset(check); sqlite3_clear_bindings(check)
                sqlite3_bind_text(check, 1, scope, -1, carrachoSQLiteTransient)
                sqlite3_bind_int64(check, 2, Int64(messageID) ?? -1)
                if sqlite3_step(check) != SQLITE_ROW {
                    try statement(db, "DELETE FROM media_refs WHERE media_id=? AND kind=? AND scope=? AND message_id=?") { stmt in
                        bindText(stmt, 1, mediaID); sqlite3_bind_int(stmt, 2, ServerMediaReferenceKind.news.rawValue); bindText(stmt, 3, scope); bindText(stmt, 4, messageID); try stepDone(stmt, db: db)
                    }
                }
            }
            try deleteUnreferencedLocked(db: db, now: Date())
        }
    }

    func cleanup(now: Date = Date()) throws {
        try queue.sync {
            let db = try openDatabase()
            try statement(db, "DELETE FROM media_refs WHERE expires_at IS NOT NULL AND expires_at<=?") { stmt in
                sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970); try stepDone(stmt, db: db)
            }
            try deleteUnreferencedLocked(db: db, now: now)
        }
    }

    private func deleteUnreferencedLocked(db: OpaquePointer, now: Date) throws {
        try statement(db, "UPDATE media_objects SET expires_at=? WHERE expires_at IS NULL AND NOT EXISTS(SELECT 1 FROM media_refs r WHERE r.media_id=media_objects.id)") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970); try stepDone(stmt, db: db)
        }
        var doomed: [(String, String)] = []
        try statement(db, "SELECT o.id,o.relative_path FROM media_objects o LEFT JOIN media_refs r ON r.media_id=o.id WHERE r.media_id IS NULL AND o.expires_at IS NOT NULL AND o.expires_at<=?") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            while sqlite3_step(stmt) == SQLITE_ROW {
                doomed.append((columnText(stmt, 0), columnText(stmt, 1)))
            }
        }
        for (id, relative) in doomed {
            try statement(db, "DELETE FROM media_objects WHERE id=?") { stmt in bindText(stmt, 1, id); try stepDone(stmt, db: db) }
            try? manager.removeItem(at: objectsRoot.appendingPathComponent(relative))
        }
    }

    private func loadLocked(id: UUID, db: OpaquePointer) throws -> ServerMediaObject {
        var row: (UUID, UUID, String, String, Int, Int, Int, String, Date, Date?, String)?
        try statement(db, "SELECT id,owner_account_id,mime_type,filename,byte_count,width,height,sha256,created_at,expires_at,relative_path FROM media_objects WHERE id=?") { stmt in
            bindText(stmt, 1, id.uuidString.lowercased())
            if sqlite3_step(stmt) == SQLITE_ROW,
               let mediaID = UUID(uuidString: columnText(stmt, 0)),
               let ownerID = UUID(uuidString: columnText(stmt, 1)) {
                let exp = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
                row = (mediaID, ownerID, columnText(stmt, 2), columnText(stmt, 3), Int(sqlite3_column_int64(stmt, 4)),
                       Int(sqlite3_column_int(stmt, 5)), Int(sqlite3_column_int(stmt, 6)), columnText(stmt, 7),
                       Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)), exp, columnText(stmt, 10))
            }
        }
        guard let row else { throw ServerMediaStoreError.notFound }
        let data = try Data(contentsOf: objectsRoot.appendingPathComponent(row.10), options: [.mappedIfSafe])
        guard data.count == row.4 else { throw ServerMediaStoreError.invalidImage("stored object length mismatch") }
        return ServerMediaObject(id: row.0, ownerAccountID: row.1, mimeType: row.2, filename: row.3,
                                 byteCount: row.4, width: row.5, height: row.6, sha256: row.7,
                                 createdAt: row.8, expiresAt: row.9, data: data)
    }

    private func openDatabase() throws -> OpaquePointer {
        if let database { return database }
        try manager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: objectsRoot, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { throw ServerMediaStoreError.database("could not open \(databaseURL.path)") }
        database = db
        sqlite3_busy_timeout(db, 5_000)
        do {
            try exec(db, "PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;PRAGMA foreign_keys=ON;")
            try exec(db, """
            CREATE TABLE IF NOT EXISTS media_objects(
                id TEXT PRIMARY KEY,
                owner_account_id TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                filename TEXT NOT NULL,
                byte_count INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL,
                relative_path TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS media_refs(
                media_id TEXT NOT NULL,
                kind INTEGER NOT NULL,
                scope TEXT NOT NULL,
                message_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL,
                PRIMARY KEY(media_id,kind,scope,message_id),
                FOREIGN KEY(media_id) REFERENCES media_objects(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS media_refs_scope_idx ON media_refs(kind,scope);
            """)
            return db
        } catch {
            sqlite3_close(db); database = nil; throw error
        }
    }

    private static func inspectImage(_ data: Data) throws -> (mimeType: String, width: Int, height: Int) {
        let mime: String
        if data.count >= 8, Array(data.prefix(8)) == [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a] { mime = "image/png" }
        else if data.count >= 3, data[data.startIndex] == 0xff, data[data.startIndex + 1] == 0xd8, data[data.startIndex + 2] == 0xff { mime = "image/jpeg" }
        else { throw ServerMediaStoreError.invalidImage("only PNG and JPEG are supported") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= LegacyMediaTransfer.maximumDimension, height <= LegacyMediaTransfer.maximumDimension else {
            throw ServerMediaStoreError.invalidImage("invalid dimensions or larger than \(LegacyMediaTransfer.maximumDimension)×\(LegacyMediaTransfer.maximumDimension)")
        }
        return (mime, width, height)
    }

    private static func cleanFilename(_ raw: String, mimeType: String) -> String {
        let leaf = URL(fileURLWithPath: raw).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = mimeType == "image/png" ? "image.png" : "image.jpg"
        guard !leaf.isEmpty else { return fallback }
        return String(leaf.prefix(255))
    }

    private func statement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw ServerMediaStoreError.database(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }
    private func stepDone(_ stmt: OpaquePointer, db: OpaquePointer) throws { guard sqlite3_step(stmt) == SQLITE_DONE else { throw ServerMediaStoreError.database(String(cString: sqlite3_errmsg(db))) } }
    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) { sqlite3_bind_text(stmt, index, value, -1, carrachoSQLiteTransient) }
    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String { sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? "" }
    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        guard rc == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db)); sqlite3_free(message)
            throw ServerMediaStoreError.database(text)
        }
    }
}
