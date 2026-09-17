import Foundation
import SQLite3

enum MessageCenterStoreError: Error, LocalizedError {
    case database(String)

    var errorDescription: String? {
        switch self {
        case let .database(message): return message
        }
    }
}

struct MessageCenterStoreScope: Hashable {
    var host: String
    var port: UInt16
    var login: String

    init(host: String, port: UInt16, login: String) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
        self.login = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct MessageCenterStoredPrivateMessage: Equatable {
    var id: UUID
    var userID: UInt32
    var timestamp: Date
    var outgoing: Bool
    var message: Data
}

struct MessageCenterStoredConversation: Equatable {
    var userID: UInt32
    var nickname: String
    var picture: Data
    var isLegacyTransport: Bool
    var unreadCount: Int
    var draftText: String
    var lastActivity: Date
    var messages: [MessageCenterStoredPrivateMessage]
}

struct MessageCenterStoredOfflineMessage: Equatable {
    var id: String
    var sentAtUnix: UInt64
    var senderLogin: Data
    var senderNickname: Data
    var message: Data
    var isUnread: Bool
}

struct MessageCenterStoredSnapshot: Equatable {
    var conversations: [MessageCenterStoredConversation]
    var offlineMessages: [MessageCenterStoredOfflineMessage]
}

/// Local durable storage for the Message Center. The historical Carracho wire protocol is
/// deliberately not involved here: modern chat history is purely a client-side presentation layer.
final class MessageCenterStore {
    private let databaseURL: URL
    private let queue = DispatchQueue(label: "com.carracho.message-center-store")

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    init(databaseURL: URL = MessageCenterStore.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
    }

    static func defaultDatabaseURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        return base.appendingPathComponent("Carracho", isDirectory: true)
            .appendingPathComponent("Client", isDirectory: true)
            .appendingPathComponent("messages.sqlite3", isDirectory: false)
    }

    func load(scope: MessageCenterStoreScope) throws -> MessageCenterStoredSnapshot {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }

            var conversations: [UInt32: MessageCenterStoredConversation] = [:]
            let conversationSQL = """
                SELECT peer_user_id, nickname, picture, is_legacy, unread_count, draft_text, last_activity
                FROM conversations
                WHERE server_host=? AND server_port=? AND account_login=?
                ORDER BY last_activity DESC
                """
            var conversationStatement: OpaquePointer?
            try prepare(db, conversationSQL, &conversationStatement)
            defer { sqlite3_finalize(conversationStatement) }
            try bindScope(scope, to: conversationStatement!)
            while true {
                let result = sqlite3_step(conversationStatement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(db) }
                let userID = UInt32(clamping: sqlite3_column_int64(conversationStatement, 0))
                conversations[userID] = MessageCenterStoredConversation(
                    userID: userID,
                    nickname: columnText(conversationStatement!, 1),
                    picture: columnBlob(conversationStatement!, 2),
                    isLegacyTransport: sqlite3_column_int(conversationStatement, 3) != 0,
                    unreadCount: max(0, Int(sqlite3_column_int64(conversationStatement, 4))),
                    draftText: columnText(conversationStatement!, 5),
                    lastActivity: Date(timeIntervalSince1970: sqlite3_column_double(conversationStatement, 6)),
                    messages: []
                )
            }

            let messageSQL = """
                SELECT id, peer_user_id, sent_at, outgoing, body
                FROM private_messages
                WHERE server_host=? AND server_port=? AND account_login=?
                ORDER BY sent_at ASC, id ASC
                """
            var messageStatement: OpaquePointer?
            try prepare(db, messageSQL, &messageStatement)
            defer { sqlite3_finalize(messageStatement) }
            try bindScope(scope, to: messageStatement!)
            while true {
                let result = sqlite3_step(messageStatement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(db) }
                guard let id = UUID(uuidString: columnText(messageStatement!, 0)) else { continue }
                let userID = UInt32(clamping: sqlite3_column_int64(messageStatement, 1))
                guard var conversation = conversations[userID] else { continue }
                conversation.messages.append(MessageCenterStoredPrivateMessage(
                    id: id,
                    userID: userID,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(messageStatement, 2)),
                    outgoing: sqlite3_column_int(messageStatement, 3) != 0,
                    message: columnBlob(messageStatement!, 4)
                ))
                conversations[userID] = conversation
            }

            let offlineSQL = """
                SELECT remote_id, sent_at_unix, sender_login, sender_nickname, body, is_unread
                FROM offline_messages
                WHERE server_host=? AND server_port=? AND account_login=?
                ORDER BY sent_at_unix ASC, remote_id ASC
                """
            var offlineStatement: OpaquePointer?
            try prepare(db, offlineSQL, &offlineStatement)
            defer { sqlite3_finalize(offlineStatement) }
            try bindScope(scope, to: offlineStatement!)
            var offlineMessages: [MessageCenterStoredOfflineMessage] = []
            while true {
                let result = sqlite3_step(offlineStatement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(db) }
                offlineMessages.append(MessageCenterStoredOfflineMessage(
                    id: columnText(offlineStatement!, 0),
                    sentAtUnix: UInt64(max(0, sqlite3_column_int64(offlineStatement, 1))),
                    senderLogin: columnBlob(offlineStatement!, 2),
                    senderNickname: columnBlob(offlineStatement!, 3),
                    message: columnBlob(offlineStatement!, 4),
                    isUnread: sqlite3_column_int(offlineStatement, 5) != 0
                ))
            }

            return MessageCenterStoredSnapshot(
                conversations: conversations.values.sorted {
                    if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
                    return $0.userID < $1.userID
                },
                offlineMessages: offlineMessages
            )
        }
    }

    func saveConversation(_ conversation: MessageCenterStoredConversation, scope: MessageCenterStoreScope) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try upsertConversation(conversation, scope: scope, db: db)
        }
    }

    func insertPrivateMessage(_ message: MessageCenterStoredPrivateMessage,
                              conversation: MessageCenterStoredConversation,
                              scope: MessageCenterStoreScope) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try exec(db, "BEGIN IMMEDIATE")
            do {
                try upsertConversation(conversation, scope: scope, db: db)
                let sql = """
                    INSERT OR REPLACE INTO private_messages
                    (id, server_host, server_port, account_login, peer_user_id, sent_at, outgoing, body)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """
                var statement: OpaquePointer?
                try prepare(db, sql, &statement)
                defer { sqlite3_finalize(statement) }
                try bindText(statement!, 1, message.id.uuidString.lowercased())
                try bindScope(scope, to: statement!, startIndex: 2)
                try bindInt64(statement!, 5, Int64(message.userID))
                guard sqlite3_bind_double(statement, 6, message.timestamp.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_bind_int(statement, 7, message.outgoing ? 1 : 0) == SQLITE_OK else { throw databaseError(db) }
                try bindBlob(statement!, 8, message.message)
                try stepDone(statement!, db: db)

                // The UI intentionally caps a conversation at 500 rows. Keep disk usage in lock-step.
                var trim: OpaquePointer?
                let trimSQL = """
                    DELETE FROM private_messages
                    WHERE id IN (
                        SELECT id FROM private_messages
                        WHERE server_host=? AND server_port=? AND account_login=? AND peer_user_id=?
                        ORDER BY sent_at DESC, id DESC
                        LIMIT -1 OFFSET 500
                    )
                    """
                try prepare(db, trimSQL, &trim)
                defer { sqlite3_finalize(trim) }
                try bindScope(scope, to: trim!)
                try bindInt64(trim!, 4, Int64(message.userID))
                try stepDone(trim!, db: db)
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    func clearConversation(userID: UInt32, scope: MessageCenterStoreScope) throws {
        try deletePrivateMessages(userID: userID, scope: scope, deleteConversation: false)
    }

    func deleteConversation(userID: UInt32, scope: MessageCenterStoreScope) throws {
        try deletePrivateMessages(userID: userID, scope: scope, deleteConversation: true)
    }

    func markAllConversationsRead(scope: MessageCenterStoreScope) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            let sql = "UPDATE conversations SET unread_count=0 WHERE server_host=? AND server_port=? AND account_login=?"
            var statement: OpaquePointer?
            try prepare(db, sql, &statement)
            defer { sqlite3_finalize(statement) }
            try bindScope(scope, to: statement!)
            try stepDone(statement!, db: db)
        }
    }

    @discardableResult
    func insertOfflineMessages(_ messages: [MessageCenterStoredOfflineMessage], scope: MessageCenterStoreScope) throws -> Set<String> {
        guard !messages.isEmpty else { return [] }
        return try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try exec(db, "BEGIN IMMEDIATE")
            var inserted: Set<String> = []
            do {
                let sql = """
                    INSERT OR IGNORE INTO offline_messages
                    (server_host, server_port, account_login, remote_id, sent_at_unix, sender_login, sender_nickname, body, is_unread)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                var statement: OpaquePointer?
                try prepare(db, sql, &statement)
                defer { sqlite3_finalize(statement) }
                for message in messages {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bindScope(scope, to: statement!)
                    try bindText(statement!, 4, message.id)
                    try bindInt64(statement!, 5, Int64(clamping: message.sentAtUnix))
                    try bindBlob(statement!, 6, message.senderLogin)
                    try bindBlob(statement!, 7, message.senderNickname)
                    try bindBlob(statement!, 8, message.message)
                    guard sqlite3_bind_int(statement, 9, message.isUnread ? 1 : 0) == SQLITE_OK else { throw databaseError(db) }
                    try stepDone(statement!, db: db)
                    if sqlite3_changes(db) > 0 { inserted.insert(message.id) }
                }
                try exec(db, "COMMIT")
                return inserted
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    func markAllOfflineMessagesRead(scope: MessageCenterStoreScope) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            let sql = "UPDATE offline_messages SET is_unread=0 WHERE server_host=? AND server_port=? AND account_login=?"
            var statement: OpaquePointer?
            try prepare(db, sql, &statement)
            defer { sqlite3_finalize(statement) }
            try bindScope(scope, to: statement!)
            try stepDone(statement!, db: db)
        }
    }

    func deleteOfflineMessage(id: String, scope: MessageCenterStoreScope) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            let sql = "DELETE FROM offline_messages WHERE server_host=? AND server_port=? AND account_login=? AND remote_id=?"
            var statement: OpaquePointer?
            try prepare(db, sql, &statement)
            defer { sqlite3_finalize(statement) }
            try bindScope(scope, to: statement!)
            try bindText(statement!, 4, id)
            try stepDone(statement!, db: db)
        }
    }

    private func deletePrivateMessages(userID: UInt32, scope: MessageCenterStoreScope, deleteConversation: Bool) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try exec(db, "BEGIN IMMEDIATE")
            do {
                var messages: OpaquePointer?
                try prepare(db, "DELETE FROM private_messages WHERE server_host=? AND server_port=? AND account_login=? AND peer_user_id=?", &messages)
                defer { sqlite3_finalize(messages) }
                try bindScope(scope, to: messages!)
                try bindInt64(messages!, 4, Int64(userID))
                try stepDone(messages!, db: db)

                if deleteConversation {
                    var conversation: OpaquePointer?
                    try prepare(db, "DELETE FROM conversations WHERE server_host=? AND server_port=? AND account_login=? AND peer_user_id=?", &conversation)
                    defer { sqlite3_finalize(conversation) }
                    try bindScope(scope, to: conversation!)
                    try bindInt64(conversation!, 4, Int64(userID))
                    try stepDone(conversation!, db: db)
                } else {
                    var conversation: OpaquePointer?
                    try prepare(db, "UPDATE conversations SET unread_count=0 WHERE server_host=? AND server_port=? AND account_login=? AND peer_user_id=?", &conversation)
                    defer { sqlite3_finalize(conversation) }
                    try bindScope(scope, to: conversation!)
                    try bindInt64(conversation!, 4, Int64(userID))
                    try stepDone(conversation!, db: db)
                }
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    private func upsertConversation(_ conversation: MessageCenterStoredConversation,
                                    scope: MessageCenterStoreScope,
                                    db: OpaquePointer) throws {
        let sql = """
            INSERT INTO conversations
            (server_host, server_port, account_login, peer_user_id, nickname, picture, is_legacy, unread_count, draft_text, last_activity)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(server_host, server_port, account_login, peer_user_id) DO UPDATE SET
                nickname=excluded.nickname,
                picture=excluded.picture,
                is_legacy=excluded.is_legacy,
                unread_count=excluded.unread_count,
                draft_text=excluded.draft_text,
                last_activity=excluded.last_activity
            """
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        try bindScope(scope, to: statement!)
        try bindInt64(statement!, 4, Int64(conversation.userID))
        try bindText(statement!, 5, conversation.nickname)
        try bindBlob(statement!, 6, conversation.picture)
        guard sqlite3_bind_int(statement, 7, conversation.isLegacyTransport ? 1 : 0) == SQLITE_OK else { throw databaseError(db) }
        try bindInt64(statement!, 8, Int64(max(0, conversation.unreadCount)))
        try bindText(statement!, 9, conversation.draftText)
        guard sqlite3_bind_double(statement, 10, conversation.lastActivity.timeIntervalSince1970) == SQLITE_OK else { throw databaseError(db) }
        try stepDone(statement!, db: db)
    }

    private func openDatabase() throws -> OpaquePointer {
        let manager = FileManager.default
        try manager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open Message Center database."
            if let db { sqlite3_close(db) }
            throw MessageCenterStoreError.database(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        do {
            try exec(db, "PRAGMA foreign_keys=ON")
            try exec(db, "PRAGMA journal_mode=WAL")
            try exec(db, "PRAGMA synchronous=NORMAL")
            try exec(db, """
                CREATE TABLE IF NOT EXISTS conversations (
                    server_host TEXT NOT NULL,
                    server_port INTEGER NOT NULL,
                    account_login TEXT NOT NULL,
                    peer_user_id INTEGER NOT NULL,
                    nickname TEXT NOT NULL,
                    picture BLOB NOT NULL,
                    is_legacy INTEGER NOT NULL DEFAULT 0,
                    unread_count INTEGER NOT NULL DEFAULT 0,
                    draft_text TEXT NOT NULL DEFAULT '',
                    last_activity REAL NOT NULL,
                    PRIMARY KEY (server_host, server_port, account_login, peer_user_id)
                )
                """)
            try exec(db, """
                CREATE TABLE IF NOT EXISTS private_messages (
                    id TEXT PRIMARY KEY,
                    server_host TEXT NOT NULL,
                    server_port INTEGER NOT NULL,
                    account_login TEXT NOT NULL,
                    peer_user_id INTEGER NOT NULL,
                    sent_at REAL NOT NULL,
                    outgoing INTEGER NOT NULL,
                    body BLOB NOT NULL,
                    FOREIGN KEY (server_host, server_port, account_login, peer_user_id)
                        REFERENCES conversations(server_host, server_port, account_login, peer_user_id)
                        ON DELETE CASCADE
                )
                """)
            try exec(db, "CREATE INDEX IF NOT EXISTS private_messages_conversation_idx ON private_messages(server_host, server_port, account_login, peer_user_id, sent_at)")
            try exec(db, """
                CREATE TABLE IF NOT EXISTS offline_messages (
                    server_host TEXT NOT NULL,
                    server_port INTEGER NOT NULL,
                    account_login TEXT NOT NULL,
                    remote_id TEXT NOT NULL,
                    sent_at_unix INTEGER NOT NULL,
                    sender_login BLOB NOT NULL,
                    sender_nickname BLOB NOT NULL,
                    body BLOB NOT NULL,
                    is_unread INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY (server_host, server_port, account_login, remote_id)
                )
                """)
            try exec(db, "CREATE INDEX IF NOT EXISTS offline_messages_date_idx ON offline_messages(server_host, server_port, account_login, sent_at_unix)")
            return db
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    private func bindScope(_ scope: MessageCenterStoreScope, to statement: OpaquePointer, startIndex: Int32 = 1) throws {
        try bindText(statement, startIndex, scope.host)
        try bindInt64(statement, startIndex + 1, Int64(scope.port))
        try bindText(statement, startIndex + 2, scope.login)
    }

    private func prepare(_ db: OpaquePointer, _ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError(db) }
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw MessageCenterStoreError.database("Could not bind text value.")
        }
    }

    private func bindInt64(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw MessageCenterStoreError.database("Could not bind integer value.")
        }
    }

    private func bindBlob(_ statement: OpaquePointer, _ index: Int32, _ value: Data) throws {
        let result = value.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw MessageCenterStoreError.database("Could not bind message data.") }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func stepDone(_ statement: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw MessageCenterStoreError.database(message)
        }
    }

    private func databaseError(_ db: OpaquePointer) -> MessageCenterStoreError {
        .database(String(cString: sqlite3_errmsg(db)))
    }
}
