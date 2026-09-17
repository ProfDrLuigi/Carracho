import Foundation
import Dispatch
import SQLite3

enum ServerNewsStoreError: LocalizedError, Equatable {
    case unsupportedFormat(Int)
    case invalidArticle(String)
    case articleNotFound(UInt32)
    case articleIDExhausted
    case database(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(version): return "Unsupported news-store format version \(version)."
        case let .invalidArticle(message): return message
        case let .articleNotFound(id): return "Article \(id) was not found."
        case .articleIDExhausted: return "The news category has exhausted its article-ID space."
        case let .database(message): return "News database error: \(message)"
        }
    }
}

struct ServerStoredArticle: Equatable {
    var articleID: UInt32
    var subject: Data
    var sender: Data
    var date: UInt32
    var createdAt: Date
    var parentArticleID: UInt32 = LegacyArticle.noArticle
    var threadID: UInt32 = LegacyArticle.noArticle
    var ownerAccountID: String?
    var isDeleted: Bool = false
    var body: LegacyArticleBodyPayload
}

let carrachoSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ServerNewsDatabaseSchema {
    static let version = 2

    static func configure(_ db: OpaquePointer) throws {
        try exec(db, "PRAGMA journal_mode=WAL;")
        try exec(db, "PRAGMA synchronous=NORMAL;")
        try exec(db, "PRAGMA foreign_keys=ON;")
        sqlite3_busy_timeout(db, 5_000)
        try exec(db, """
        CREATE TABLE IF NOT EXISTS news_meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS news_group_sequences(
            group_id TEXT PRIMARY KEY,
            next_article_id INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS news_articles(
            group_id TEXT NOT NULL,
            article_id INTEGER NOT NULL,
            subject BLOB NOT NULL,
            sender BLOB NOT NULL,
            legacy_date INTEGER NOT NULL,
            created_at REAL NOT NULL,
            body BLOB NOT NULL,
            parent_article_id INTEGER NOT NULL,
            thread_id INTEGER NOT NULL,
            owner_account_id TEXT,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(group_id, article_id)
        );
        CREATE INDEX IF NOT EXISTS news_articles_thread_idx
            ON news_articles(group_id, thread_id, article_id);
        CREATE INDEX IF NOT EXISTS news_articles_created_idx
            ON news_articles(group_id, created_at);
        CREATE TABLE IF NOT EXISTS news_reactions(
            group_id TEXT NOT NULL,
            article_id INTEGER NOT NULL,
            account_id TEXT NOT NULL,
            reaction INTEGER NOT NULL,
            PRIMARY KEY(group_id, article_id, account_id),
            FOREIGN KEY(group_id, article_id)
                REFERENCES news_articles(group_id, article_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS news_reactions_article_idx
            ON news_reactions(group_id, article_id, reaction);
        CREATE TABLE IF NOT EXISTS flat_news(
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            entry BLOB NOT NULL
        );
        """)
        let existing = try scalarText(db, "SELECT value FROM news_meta WHERE key='schema_version'")
        if existing == nil {
            try exec(db, "INSERT INTO news_meta(key,value) VALUES('schema_version','\(version)');")
        } else if existing == "1" {
            try exec(db, "ALTER TABLE news_articles ADD COLUMN owner_account_id TEXT;")
            try exec(db, "ALTER TABLE news_articles ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;")
            try exec(db, "UPDATE news_meta SET value='2' WHERE key='schema_version';")
        } else if let existing, Int(existing) != version {
            throw ServerNewsStoreError.database("unsupported news.db schema version \(existing)")
        }
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        guard rc == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw ServerNewsStoreError.database(text)
        }
    }

    static func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ServerNewsStoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw ServerNewsStoreError.database(String(cString: sqlite3_errmsg(db))) }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}

/// Persistent threaded-news storage backed by the dedicated `news.db` SQLite
/// database. Older manifest/body files under `News/` are imported once into the
/// database and removed only after the transaction commits successfully.
final class ServerNewsStore {
    private struct LegacyManifest: Codable {
        static let currentFormatVersion = 3
        var formatVersion: Int = currentFormatVersion
        var nextArticleID: UInt32 = 1
        var entries: [LegacyEntry] = []
    }

    private struct LegacyEntry: Codable {
        var articleID: UInt32
        var subject: Data
        var sender: Data
        var date: UInt32
        var createdAt: Date
        var bodyLength: UInt32
        var parentArticleID: UInt32?
        var threadID: UInt32?
        var reactions: [String: UInt8]?

        var effectiveParentArticleID: UInt32 { parentArticleID ?? LegacyArticle.noArticle }
        var effectiveThreadID: UInt32 { threadID ?? articleID }
        var effectiveReactions: [String: UInt8] { reactions ?? [:] }
    }

    private struct ArticleRow {
        var articleID: UInt32
        var subject: Data
        var sender: Data
        var date: UInt32
        var createdAt: Date
        var body: Data
        var parentArticleID: UInt32
        var threadID: UInt32
        var ownerAccountID: String?
        var isDeleted: Bool
    }

    let databaseURL: URL
    let legacyRootURL: URL?
    private let queue = DispatchQueue(label: "com.carracho.server-news-store")
    private let manager = FileManager.default
    private var database: OpaquePointer?
    private var initialized = false

    /// Compatibility initializer used by store unit tests and older callers. The
    /// supplied directory becomes the legacy root and contains its own `news.db`.
    convenience init(rootURL: URL) {
        self.init(databaseURL: rootURL.appendingPathComponent("news.db"), legacyRootURL: rootURL)
    }

    init(databaseURL: URL, legacyRootURL: URL? = nil) {
        self.databaseURL = databaseURL
        self.legacyRootURL = legacyRootURL
    }

    deinit {
        queue.sync {
            if let database { sqlite3_close(database) }
            database = nil
        }
    }

    func count(groupID: UUID) throws -> UInt32 {
        try queue.sync {
            let db = try db()
            return try count(groupKey: key(groupID), db: db)
        }
    }

    func post(groupID: UUID,
              subject: Data,
              sender: Data,
              date: UInt32,
              body sourceBody: LegacyArticleBodyPayload,
              parentArticleID requestedParent: UInt32? = nil,
              ownerAccountID: UUID? = nil,
              createdAt: Date = Date()) throws -> ServerStoredArticle {
        try queue.sync {
            guard !subject.isEmpty, subject.count <= Int(UInt16.max) else {
                throw ServerNewsStoreError.invalidArticle("Article subject must be 1…65535 bytes.")
            }
            guard !sender.isEmpty, sender.count <= Int(UInt16.max) else {
                throw ServerNewsStoreError.invalidArticle("Article sender must be 1…65535 bytes.")
            }
            guard sourceBody.text.count <= LegacyNewsTransfer.maximumArticleReceiverPayload,
                  sourceBody.styleData.count <= LegacyNewsTransfer.maximumArticleReceiverPayload else {
                throw ServerNewsStoreError.invalidArticle("Article body exceeds the supported legacy size.")
            }

            let db = try db()
            let group = key(groupID)
            var insertedArticleID: UInt32 = 0
            try transaction(db) {
                let articleID = try allocateArticleID(group: group, db: db)
                insertedArticleID = articleID
                let parent = requestedParent.flatMap { $0 == LegacyArticle.noArticle ? nil : $0 }
                let threadID: UInt32
                if let parent {
                    guard parent != 0, parent != articleID,
                          let parentRow = try row(group: group, articleID: parent, db: db) else {
                        throw ServerNewsStoreError.invalidArticle("The parent post does not exist in this category.")
                    }
                    threadID = parentRow.threadID
                    guard let root = try row(group: group, articleID: threadID, db: db),
                          root.parentArticleID == LegacyArticle.noArticle else {
                        throw ServerNewsStoreError.invalidArticle("The parent post belongs to an invalid thread.")
                    }
                } else {
                    threadID = articleID
                }

                let parentWire = parent ?? LegacyArticle.noArticle
                let body = LegacyArticleBodyPayload(articleID: articleID, reservedWord: parentWire,
                                                    text: sourceBody.text, styleData: sourceBody.styleData)
                let encoded = try body.encoded()
                guard encoded.count <= Int(UInt32.max) else {
                    throw ServerNewsStoreError.invalidArticle("Encoded article body is too large.")
                }
                try insertArticle(db: db, group: group, articleID: articleID, subject: subject, sender: sender,
                                  date: date, createdAt: createdAt, body: encoded,
                                  parentArticleID: parentWire, threadID: threadID,
                                  ownerAccountID: ownerAccountID?.uuidString.lowercased())
                let next = articleID == UInt32.max - 1 ? 1 : articleID + 1
                try setSequence(group: group, next: next, db: db)
            }
            guard let stored = try articleUnlocked(groupID: groupID, articleID: insertedArticleID) else {
                throw ServerNewsStoreError.database("inserted article could not be reloaded")
            }
            return stored
        }
    }

    func article(groupID: UUID, articleID: UInt32) throws -> ServerStoredArticle? {
        try queue.sync { try articleUnlocked(groupID: groupID, articleID: articleID) }
    }

    private func articleUnlocked(groupID: UUID, articleID: UInt32) throws -> ServerStoredArticle? {
        let db = try db()
        guard let row = try row(group: key(groupID), articleID: articleID, db: db) else { return nil }
        var body = try LegacyArticleBodyPayload.decode(row.body)
        guard body.articleID == articleID else {
            throw ServerNewsStoreError.invalidArticle("Stored article \(articleID) contains a mismatched body ID.")
        }
        body.reservedWord = row.parentArticleID
        return ServerStoredArticle(articleID: articleID, subject: row.subject, sender: row.sender,
                                   date: row.date, createdAt: row.createdAt,
                                   parentArticleID: row.parentArticleID, threadID: row.threadID,
                                   ownerAccountID: row.ownerAccountID, isDeleted: row.isDeleted, body: body)
    }

    func legacyIndex(groupID: UUID, groupName: Data) throws -> LegacyArticleIndex {
        try queue.sync {
            let rows = try rows(group: key(groupID), db: try db())
            return LegacyArticleIndex(group: groupName, entries: rows.map {
                LegacyArticleIndexEntry(articleID: $0.articleID, subject: $0.subject, sender: $0.sender,
                                        date: $0.date, bodyLength: UInt32($0.body.count))
            })
        }
    }

    func threadSummaries(groupID: UUID) throws -> [LegacyNewsThreadSummary] {
        try queue.sync {
            let rows = try rows(group: key(groupID), db: try db())
            return rows.filter { $0.parentArticleID == LegacyArticle.noArticle }.map { root in
                let members = rows.filter { $0.threadID == root.articleID }
                return LegacyNewsThreadSummary(threadID: root.articleID, subject: root.subject, sender: root.sender,
                                               date: root.date,
                                               replyCount: UInt32(max(0, members.count - 1)),
                                               latestDate: members.map(\.date).max() ?? root.date)
            }.sorted {
                if $0.latestDate != $1.latestDate { return $0.latestDate > $1.latestDate }
                return $0.threadID > $1.threadID
            }
        }
    }

    func threadPosts(groupID: UUID, threadID: UInt32) throws -> [LegacyNewsThreadPostSummary] {
        try queue.sync {
            let all = try rows(group: key(groupID), db: try db())
            guard all.contains(where: { $0.articleID == threadID && $0.parentArticleID == LegacyArticle.noArticle }) else {
                throw ServerNewsStoreError.articleNotFound(threadID)
            }
            return all.filter { $0.threadID == threadID }.map {
                LegacyNewsThreadPostSummary(articleID: $0.articleID, parentArticleID: $0.parentArticleID,
                                            sender: $0.sender, date: $0.date, bodyLength: UInt32($0.body.count))
            }
        }
    }

    func threadPostCapabilities(groupID: UUID, threadID: UInt32, accountID: UUID,
                                canModerate: Bool) throws -> [LegacyNewsPostCapability] {
        try queue.sync {
            let all = try rows(group: key(groupID), db: try db())
            let owner = accountID.uuidString.lowercased()
            return all.filter { $0.threadID == threadID }.map { row in
                let mine = row.ownerAccountID?.caseInsensitiveCompare(owner) == .orderedSame
                return LegacyNewsPostCapability(articleID: row.articleID,
                                                canEdit: (mine || canModerate) && !row.isDeleted,
                                                canDelete: (mine || canModerate) && !row.isDeleted,
                                                isDeleted: row.isDeleted)
            }
        }
    }

    @discardableResult
    func updateOwned(groupID: UUID, articleID: UInt32, ownerAccountID: UUID, canModerate: Bool = false,
                     subject: Data, body sourceBody: LegacyArticleBodyPayload) throws -> ServerStoredArticle {
        try queue.sync {
            guard !subject.isEmpty, subject.count <= Int(UInt16.max),
                  sourceBody.text.count <= LegacyNewsTransfer.maximumArticleReceiverPayload,
                  sourceBody.styleData.count <= LegacyNewsTransfer.maximumArticleReceiverPayload else {
                throw ServerNewsStoreError.invalidArticle("Edited article exceeds the supported size.")
            }
            let db = try db(), group = key(groupID)
            guard let row = try row(group: group, articleID: articleID, db: db), !row.isDeleted else {
                throw ServerNewsStoreError.articleNotFound(articleID)
            }
            let owner = ownerAccountID.uuidString.lowercased()
            let mine = row.ownerAccountID?.caseInsensitiveCompare(owner) == .orderedSame
            guard mine || canModerate else {
                throw ServerNewsStoreError.invalidArticle("Only the post owner or a News administrator can edit this article.")
            }
            let body = LegacyArticleBodyPayload(articleID: articleID, reservedWord: row.parentArticleID,
                                                text: sourceBody.text, styleData: sourceBody.styleData)
            let encoded = try body.encoded()
            try statement(db, "UPDATE news_articles SET subject=?,body=? WHERE group_id=? AND article_id=?") { stmt in
                bindBlob(stmt, 1, subject); bindBlob(stmt, 2, encoded); bindText(stmt, 3, group); bindInt64(stmt, 4, Int64(articleID)); try stepDone(stmt, db: db)
            }
            guard let updated = try articleUnlocked(groupID: groupID, articleID: articleID) else {
                throw ServerNewsStoreError.articleNotFound(articleID)
            }
            return updated
        }
    }

    @discardableResult
    func softDelete(groupID: UUID, articleID: UInt32, requesterAccountID: UUID,
                    canModerate: Bool) throws -> Bool {
        try queue.sync {
            let db = try db(), group = key(groupID)
            guard let row = try row(group: group, articleID: articleID, db: db), !row.isDeleted else { return false }
            let requester = requesterAccountID.uuidString.lowercased()
            let mine = row.ownerAccountID?.caseInsensitiveCompare(requester) == .orderedSame
            guard mine || canModerate else {
                throw ServerNewsStoreError.invalidArticle("Only the post owner can delete this article.")
            }
            let placeholder = try CarrachoTextWire.encode("[Post deleted]", maximumBytes: LegacyNewsTransfer.maximumArticleReceiverPayload)
            let body = LegacyArticleBodyPayload(articleID: articleID, reservedWord: row.parentArticleID,
                                                text: placeholder, styleData: Data())
            let encoded = try body.encoded()
            try transaction(db) {
                try statement(db, "UPDATE news_articles SET body=?,is_deleted=1 WHERE group_id=? AND article_id=?") { stmt in
                    bindBlob(stmt, 1, encoded); bindText(stmt, 2, group); bindInt64(stmt, 3, Int64(articleID)); try stepDone(stmt, db: db)
                }
                try statement(db, "DELETE FROM news_reactions WHERE group_id=? AND article_id=?") { stmt in
                    bindText(stmt, 1, group); bindInt64(stmt, 2, Int64(articleID)); try stepDone(stmt, db: db)
                }
            }
            return true
        }
    }

    func reactionSummary(groupID: UUID, articleID: UInt32, accountID: String) throws -> [LegacyNewsReactionSummary] {
        try queue.sync {
            let db = try db()
            guard let article = try row(group: key(groupID), articleID: articleID, db: db) else {
                throw ServerNewsStoreError.articleNotFound(articleID)
            }
            guard !article.isDeleted else { return [] }
            return try reactionSummary(group: key(groupID), articleID: articleID, accountID: accountID, db: db)
        }
    }

    func reactionAccountIDs(groupID: UUID, articleID: UInt32) throws -> [UInt8: [String]] {
        try queue.sync {
            let db = try db(), group = key(groupID)
            guard let article = try row(group: group, articleID: articleID, db: db) else {
                throw ServerNewsStoreError.articleNotFound(articleID)
            }
            guard !article.isDeleted else { return [:] }
            var result: [UInt8: [String]] = [:]
            try statement(db, "SELECT account_id,reaction FROM news_reactions WHERE group_id=? AND article_id=? ORDER BY reaction,account_id") { stmt in
                bindText(stmt, 1, group); bindInt64(stmt, 2, Int64(articleID))
                while true {
                    let rc = sqlite3_step(stmt); if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW else { throw ServerNewsStoreError.database(String(cString: sqlite3_errmsg(db))) }
                    let account = String(cString: sqlite3_column_text(stmt, 0))
                    let reaction = UInt8(sqlite3_column_int(stmt, 1))
                    if LegacyNewsReactionKind(rawValue: reaction) != nil { result[reaction, default: []].append(account) }
                }
            }
            return result
        }
    }

    func setReaction(groupID: UUID, articleID: UInt32, accountID: String, reaction: UInt8?) throws -> [LegacyNewsReactionSummary] {
        try queue.sync {
            guard !accountID.isEmpty, accountID.utf8.count <= 128 else {
                throw ServerNewsStoreError.invalidArticle("Invalid reaction account identifier.")
            }
            if let reaction, LegacyNewsReactionKind(rawValue: reaction) == nil {
                throw ServerNewsStoreError.invalidArticle("Unknown news reaction.")
            }
            let db = try db(), group = key(groupID)
            guard let article = try row(group: group, articleID: articleID, db: db), !article.isDeleted else {
                throw ServerNewsStoreError.articleNotFound(articleID)
            }
            if let reaction {
                try statement(db, "INSERT INTO news_reactions(group_id,article_id,account_id,reaction) VALUES(?,?,?,?) ON CONFLICT(group_id,article_id,account_id) DO UPDATE SET reaction=excluded.reaction") { stmt in
                    bindText(stmt, 1, group); bindInt64(stmt, 2, Int64(articleID)); bindText(stmt, 3, accountID); bindInt64(stmt, 4, Int64(reaction))
                    try stepDone(stmt, db: db)
                }
            } else {
                try statement(db, "DELETE FROM news_reactions WHERE group_id=? AND article_id=? AND account_id=?") { stmt in
                    bindText(stmt, 1, group); bindInt64(stmt, 2, Int64(articleID)); bindText(stmt, 3, accountID)
                    try stepDone(stmt, db: db)
                }
            }
            return try reactionSummary(group: group, articleID: articleID, accountID: accountID, db: db)
        }
    }

    func legacyReply(groupID: UUID, groupName: Data, articleID: UInt32) throws -> LegacyArticleReply? {
        try queue.sync {
            let db = try db(), group = key(groupID)
            guard let row = try row(group: group, articleID: articleID, db: db) else { return nil }
            let all = try rows(group: group, db: db)
            guard let index = all.firstIndex(where: { $0.articleID == articleID }) else { return nil }
            var body = try LegacyArticleBodyPayload.decode(row.body)
            body.reservedWord = row.parentArticleID
            let previous = index > 0 ? all[index - 1].articleID : LegacyArticle.noArticle
            let next = index + 1 < all.count ? all[index + 1].articleID : LegacyArticle.noArticle
            let metadata = LegacyArticleReplyMetadata(group: groupName, articleID: articleID,
                                                      previousArticleID: previous, nextArticleID: next,
                                                      subject: row.subject, sender: row.sender, date: row.date)
            return LegacyArticleReply(metadata: metadata, body: body)
        }
    }

    @discardableResult
    func delete(groupID: UUID, articleID: UInt32) throws -> Bool {
        try queue.sync {
            let db = try db(), group = key(groupID)
            let all = try rows(group: group, db: db)
            guard let target = all.first(where: { $0.articleID == articleID }) else { return false }
            var ids: Set<UInt32>
            if target.parentArticleID == LegacyArticle.noArticle {
                ids = Set(all.filter { $0.threadID == articleID }.map(\.articleID))
            } else {
                ids = [articleID]
                var changed = true
                while changed {
                    changed = false
                    for row in all where !ids.contains(row.articleID) && ids.contains(row.parentArticleID) {
                        ids.insert(row.articleID); changed = true
                    }
                }
            }
            try delete(group: group, articleIDs: ids, db: db)
            return true
        }
    }

    @discardableResult
    func expire(groupID: UUID, expireAfterSeconds: UInt32, now: Date = Date()) throws -> [UInt32] {
        guard expireAfterSeconds != UInt32.max else { return [] }
        return try queue.sync {
            let db = try db(), group = key(groupID), all = try rows(group: key(groupID), db: db)
            let threshold = TimeInterval(expireAfterSeconds)
            let initiallyExpired = Set(all.filter { max(0, now.timeIntervalSince($0.createdAt)) >= threshold }.map(\.articleID))
            guard !initiallyExpired.isEmpty else { return [] }
            var ids = initiallyExpired
            for root in all where initiallyExpired.contains(root.articleID) && root.parentArticleID == LegacyArticle.noArticle {
                ids.formUnion(all.filter { $0.threadID == root.articleID }.map(\.articleID))
            }
            var changed = true
            while changed {
                changed = false
                for row in all where !ids.contains(row.articleID) && ids.contains(row.parentArticleID) {
                    ids.insert(row.articleID); changed = true
                }
            }
            try delete(group: group, articleIDs: ids, db: db)
            return ids.sorted()
        }
    }

    func prune(validGroupIDs: Set<UUID>) throws {
        try queue.sync {
            let db = try db()
            let valid = Set(validGroupIDs.map(key))
            var groups: [String] = []
            try statement(db, "SELECT DISTINCT group_id FROM news_articles UNION SELECT group_id FROM news_group_sequences") { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let text = sqlite3_column_text(stmt, 0) { groups.append(String(cString: text)) }
                }
            }
            for group in groups where !valid.contains(group) {
                try statement(db, "DELETE FROM news_articles WHERE group_id=?") { stmt in bindText(stmt, 1, group); try stepDone(stmt, db: db) }
                try statement(db, "DELETE FROM news_group_sequences WHERE group_id=?") { stmt in bindText(stmt, 1, group); try stepDone(stmt, db: db) }
            }
        }
    }

    private func db() throws -> OpaquePointer {
        if let database, initialized { return database }
        try manager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(databaseURL.path)"
            if let handle { sqlite3_close(handle) }
            throw ServerNewsStoreError.database(message)
        }
        database = handle
        do {
            try ServerNewsDatabaseSchema.configure(handle)
            try migrateLegacyIfNeeded(db: handle)
            initialized = true
            return handle
        } catch {
            sqlite3_close(handle); database = nil; initialized = false
            throw error
        }
    }

    private func migrateLegacyIfNeeded(db: OpaquePointer) throws {
        let marker = try ServerNewsDatabaseSchema.scalarText(db, "SELECT value FROM news_meta WHERE key='threaded_legacy_migrated_v1'")
        guard marker == nil else { return }
        guard let legacyRootURL, manager.fileExists(atPath: legacyRootURL.path) else {
            try ServerNewsDatabaseSchema.exec(db, "INSERT OR REPLACE INTO news_meta(key,value) VALUES('threaded_legacy_migrated_v1','1');")
            return
        }

        let children = try manager.contentsOfDirectory(at: legacyRootURL, includingPropertiesForKeys: [.isDirectoryKey])
        try transaction(db) {
            for directory in children {
                guard let groupID = UUID(uuidString: directory.lastPathComponent) else { continue }
                let manifestURL = directory.appendingPathComponent("manifest.json")
                guard manager.fileExists(atPath: manifestURL.path) else { continue }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                var manifest = try decoder.decode(LegacyManifest.self, from: Data(contentsOf: manifestURL))
                guard (1...LegacyManifest.currentFormatVersion).contains(manifest.formatVersion) else {
                    throw ServerNewsStoreError.unsupportedFormat(manifest.formatVersion)
                }
                if manifest.formatVersion == 1 {
                    for i in manifest.entries.indices {
                        manifest.entries[i].parentArticleID = LegacyArticle.noArticle
                        manifest.entries[i].threadID = manifest.entries[i].articleID
                    }
                }
                let ids = Set(manifest.entries.map(\.articleID))
                guard ids.count == manifest.entries.count else { throw ServerNewsStoreError.invalidArticle("Legacy News manifest has duplicate IDs.") }
                let group = key(groupID)
                for entry in manifest.entries {
                    let parent = entry.effectiveParentArticleID, thread = entry.effectiveThreadID
                    guard entry.articleID != 0, entry.articleID != LegacyArticle.noArticle,
                          ids.contains(thread), parent == LegacyArticle.noArticle || ids.contains(parent) else {
                        throw ServerNewsStoreError.invalidArticle("Legacy News manifest contains an invalid thread relationship.")
                    }
                    let bodyURL = directory.appendingPathComponent("article-\(entry.articleID).bin")
                    let body = try Data(contentsOf: bodyURL)
                    guard body.count == Int(entry.bodyLength) else {
                        throw ServerNewsStoreError.invalidArticle("Legacy article \(entry.articleID) body length mismatch.")
                    }
                    _ = try LegacyArticleBodyPayload.decode(body)
                    try insertArticle(db: db, group: group, articleID: entry.articleID, subject: entry.subject,
                                      sender: entry.sender, date: entry.date, createdAt: entry.createdAt,
                                      body: body, parentArticleID: parent, threadID: thread, orIgnore: true)
                    for (account, reaction) in entry.effectiveReactions where LegacyNewsReactionKind(rawValue: reaction) != nil {
                        try statement(db, "INSERT OR IGNORE INTO news_reactions(group_id,article_id,account_id,reaction) VALUES(?,?,?,?)") { stmt in
                            bindText(stmt, 1, group); bindInt64(stmt, 2, Int64(entry.articleID)); bindText(stmt, 3, account); bindInt64(stmt, 4, Int64(reaction)); try stepDone(stmt, db: db)
                        }
                    }
                }
                let next = manifest.nextArticleID == 0 || manifest.nextArticleID == LegacyArticle.noArticle ? 1 : manifest.nextArticleID
                try setSequence(group: group, next: next, db: db)
            }
            try ServerNewsDatabaseSchema.exec(db, "INSERT OR REPLACE INTO news_meta(key,value) VALUES('threaded_legacy_migrated_v1','1');")
        }
        // Data is durable in news.db now. Old manifests/bodies are no longer live state.
        for directory in children where UUID(uuidString: directory.lastPathComponent) != nil { try? manager.removeItem(at: directory) }
        if (try? manager.contentsOfDirectory(atPath: legacyRootURL.path).isEmpty) == true { try? manager.removeItem(at: legacyRootURL) }
    }

    private func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func count(groupKey: String, db: OpaquePointer) throws -> UInt32 {
        var value: UInt32 = 0
        try statement(db, "SELECT COUNT(*) FROM news_articles WHERE group_id=?") { stmt in
            bindText(stmt, 1, groupKey)
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw ServerNewsStoreError.database(String(cString: sqlite3_errmsg(db))) }
            value = UInt32(clamping: sqlite3_column_int64(stmt, 0))
        }
        return value
    }

    private func allocateArticleID(group: String, db: OpaquePointer) throws -> UInt32 {
        var next: UInt32 = 1
        try statement(db, "SELECT next_article_id FROM news_group_sequences WHERE group_id=?") { stmt in
            bindText(stmt, 1, group)
            if sqlite3_step(stmt) == SQLITE_ROW { next = UInt32(sqlite3_column_int64(stmt, 0)) }
        }
        if next == 0 || next == LegacyArticle.noArticle { next = 1 }
        let start = next
        repeat {
            if try row(group: group, articleID: next, db: db) == nil { return next }
            next = next == UInt32.max - 1 ? 1 : next + 1
        } while next != start
        throw ServerNewsStoreError.articleIDExhausted
    }

    private func setSequence(group: String, next: UInt32, db: OpaquePointer) throws {
        try statement(db, "INSERT INTO news_group_sequences(group_id,next_article_id) VALUES(?,?) ON CONFLICT(group_id) DO UPDATE SET next_article_id=excluded.next_article_id") { stmt in
            bindText(stmt, 1, group); bindInt64(stmt, 2, Int64(next)); try stepDone(stmt, db: db)
        }
    }

    private func insertArticle(db: OpaquePointer, group: String, articleID: UInt32, subject: Data, sender: Data,
                               date: UInt32, createdAt: Date, body: Data, parentArticleID: UInt32,
                               threadID: UInt32, ownerAccountID: String? = nil, isDeleted: Bool = false,
                               orIgnore: Bool = false) throws {
        let verb = orIgnore ? "INSERT OR IGNORE" : "INSERT"
        try statement(db, "\(verb) INTO news_articles(group_id,article_id,subject,sender,legacy_date,created_at,body,parent_article_id,thread_id,owner_account_id,is_deleted) VALUES(?,?,?,?,?,?,?,?,?,?,?)") { stmt in
            bindText(stmt, 1, group); bindInt64(stmt, 2, Int64(articleID)); bindBlob(stmt, 3, subject); bindBlob(stmt, 4, sender)
            bindInt64(stmt, 5, Int64(date)); sqlite3_bind_double(stmt, 6, createdAt.timeIntervalSince1970); bindBlob(stmt, 7, body)
            bindInt64(stmt, 8, Int64(parentArticleID)); bindInt64(stmt, 9, Int64(threadID))
            if let ownerAccountID { bindText(stmt, 10, ownerAccountID) } else { sqlite3_bind_null(stmt, 10) }
            sqlite3_bind_int(stmt, 11, isDeleted ? 1 : 0); try stepDone(stmt, db: db)
        }
    }

    private func row(group: String, articleID: UInt32, db: OpaquePointer) throws -> ArticleRow? {
        var result: ArticleRow?
        try statement(db, "SELECT article_id,subject,sender,legacy_date,created_at,body,parent_article_id,thread_id,owner_account_id,is_deleted FROM news_articles WHERE group_id=? AND article_id=?") { stmt in
            bindText(stmt, 1, group); bindInt64(stmt, 2, Int64(articleID))
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { result = readRow(stmt) }
            else if rc != SQLITE_DONE { throw ServerNewsStoreError.database(String(cString: sqlite3_errmsg(db))) }
        }
        return result
    }

    private func rows(group: String, db: OpaquePointer) throws -> [ArticleRow] {
        var result: [ArticleRow] = []
        try statement(db, "SELECT article_id,subject,sender,legacy_date,created_at,body,parent_article_id,thread_id,owner_account_id,is_deleted FROM news_articles WHERE group_id=? ORDER BY article_id") { stmt in
            bindText(stmt, 1, group)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw ServerNewsStoreError.database(String(cString: sqlite3_errmsg(db))) }
                result.append(readRow(stmt))
            }
        }
        return result
    }

    private func readRow(_ stmt: OpaquePointer) -> ArticleRow {
        ArticleRow(articleID: UInt32(sqlite3_column_int64(stmt, 0)),
                   subject: blob(stmt, 1), sender: blob(stmt, 2), date: UInt32(sqlite3_column_int64(stmt, 3)),
                   createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)), body: blob(stmt, 5),
                   parentArticleID: UInt32(sqlite3_column_int64(stmt, 6)), threadID: UInt32(sqlite3_column_int64(stmt, 7)),
                   ownerAccountID: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 8)),
                   isDeleted: sqlite3_column_int(stmt, 9) != 0)
    }

    private func reactionSummary(group: String, articleID: UInt32, accountID: String, db: OpaquePointer) throws -> [LegacyNewsReactionSummary] {
        var counts: [UInt8: UInt32] = [:], mine: UInt8?
        try statement(db, "SELECT account_id,reaction FROM news_reactions WHERE group_id=? AND article_id=?") { stmt in
            bindText(stmt, 1, group); bindInt64(stmt, 2, Int64(articleID))
            while true {
                let rc = sqlite3_step(stmt); if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw ServerNewsStoreError.database(String(cString: sqlite3_errmsg(db))) }
                let account = String(cString: sqlite3_column_text(stmt, 0)), reaction = UInt8(sqlite3_column_int(stmt, 1))
                if LegacyNewsReactionKind(rawValue: reaction) != nil { counts[reaction, default: 0] &+= 1; if account == accountID { mine = reaction } }
            }
        }
        return LegacyNewsReactionKind.allCases.compactMap { kind in
            let count = counts[kind.rawValue, default: 0]
            return count == 0 ? nil : LegacyNewsReactionSummary(kind: kind.rawValue, count: count, reactedByCurrentUser: mine == kind.rawValue)
        }
    }

    private func delete(group: String, articleIDs: Set<UInt32>, db: OpaquePointer) throws {
        guard !articleIDs.isEmpty else { return }
        try transaction(db) {
            for id in articleIDs {
                try statement(db, "DELETE FROM news_articles WHERE group_id=? AND article_id=?") { stmt in
                    bindText(stmt, 1, group); bindInt64(stmt, 2, Int64(id)); try stepDone(stmt, db: db)
                }
            }
        }
    }

    private func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try ServerNewsDatabaseSchema.exec(db, "BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try ServerNewsDatabaseSchema.exec(db, "COMMIT;")
            return value
        } catch {
            try? ServerNewsDatabaseSchema.exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func statement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ServerNewsStoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func stepDone(_ stmt: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ServerNewsStoreError.database(String(cString: sqlite3_errmsg(db))) }
    }
    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) { sqlite3_bind_text(stmt, index, value, -1, carrachoSQLiteTransient) }
    private func bindInt64(_ stmt: OpaquePointer, _ index: Int32, _ value: Int64) { sqlite3_bind_int64(stmt, index, value) }
    private func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ value: Data) {
        _ = value.withUnsafeBytes { raw in sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), carrachoSQLiteTransient) }
    }
    private func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, index)); guard count > 0, let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
