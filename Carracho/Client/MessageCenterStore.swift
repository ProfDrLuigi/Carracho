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
    var timestamp: Date
    var outgoing: Bool
    var message: Data
    var edited: Bool = false
    var editable: Bool = false
    var reactable: Bool = false
    var myReaction: UInt8? = nil
    var peerReaction: UInt8? = nil
}

struct MessageCenterStoredConversation: Equatable {
    /// Stable server account identity. Ephemeral session user IDs are deliberately never persisted.
    var accountID: UUID
    var nickname: String
    var picture: Data
    var isLegacyTransport: Bool
    var unreadCount: Int
    var draftText: String
    var lastActivity: Date
    var messages: [MessageCenterStoredPrivateMessage]
}

/// Boot-scoped fallback history for peers whose server has not supplied a stable account UUID.
/// The numeric user ID is only trusted while the exact same server process is still running.
/// The boot ID is resolved separately from server uptime and keeps recycled IDs from crossing a
/// server restart.
struct MessageCenterStoredBootConversation: Equatable {
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

/// Local durable storage for the Message Center.
///
/// Modern private-message history is keyed by the server's stable account UUID. Older database
/// tables keyed only by the transient UInt32 session user ID are intentionally left untouched and
/// never loaded, because a server restart can recycle those IDs for another account.
///
/// When a server does not provide a peer account UUID, including original/Classic servers and
/// older modern builds, fallback history is namespaced by a locally resolved server-boot ID plus
/// the numeric user ID. The boot ID is derived from server uptime, so client restarts can restore
/// history while an actual server restart starts a fresh namespace. Offline messages keep their
/// existing table.
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

            var conversations: [UUID: MessageCenterStoredConversation] = [:]
            let conversationSQL = """
                SELECT peer_account_id, nickname, picture, is_legacy, unread_count, draft_text, last_activity
                FROM conversations_v2
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
                guard let accountID = UUID(uuidString: columnText(conversationStatement!, 0)) else { continue }
                conversations[accountID] = MessageCenterStoredConversation(
                    accountID: accountID,
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
                SELECT id, peer_account_id, sent_at, outgoing, body, edited, editable, reactable, my_reaction, peer_reaction
                FROM private_messages_v2
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
                guard let id = UUID(uuidString: columnText(messageStatement!, 0)),
                      let accountID = UUID(uuidString: columnText(messageStatement!, 1)),
                      var conversation = conversations[accountID] else { continue }
                conversation.messages.append(MessageCenterStoredPrivateMessage(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(messageStatement, 2)),
                    outgoing: sqlite3_column_int(messageStatement, 3) != 0,
                    message: columnBlob(messageStatement!, 4),
                    edited: sqlite3_column_int(messageStatement, 5) != 0,
                    editable: sqlite3_column_int(messageStatement, 6) != 0,
                    reactable: sqlite3_column_int(messageStatement, 7) != 0,
                    myReaction: sqlite3_column_type(messageStatement, 8) == SQLITE_NULL
                        ? nil : UInt8(clamping: sqlite3_column_int(messageStatement, 8)),
                    peerReaction: sqlite3_column_type(messageStatement, 9) == SQLITE_NULL
                        ? nil : UInt8(clamping: sqlite3_column_int(messageStatement, 9))
                ))
                conversations[accountID] = conversation
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
                    return $0.accountID.uuidString < $1.accountID.uuidString
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

    /// Resolves a stable local namespace for the currently running server process.
    /// The wire protocol exposes uptime but no boot UUID. A real server restart therefore gets a
    /// new local boot ID, while restarting only the client reuses the existing one.
    func resolveServerBoot(scope: MessageCenterStoreScope, uptimeTicks: UInt32,
                           observedAt: Date = Date()) throws -> UUID {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }

            let bootStartedAt = observedAt.timeIntervalSince1970 - Double(uptimeTicks) / 60.0
            var candidateID: UUID?
            var candidateBootStartedAt = 0.0
            var candidateLastUptime: UInt64 = 0

            var select: OpaquePointer?
            try prepare(db, """
                SELECT boot_id, boot_started_at, last_uptime_ticks
                FROM server_boots_v1
                WHERE server_host=? AND server_port=? AND account_login=?
                ORDER BY ABS(boot_started_at - ?) ASC
                LIMIT 1
                """, &select)
            defer { sqlite3_finalize(select) }
            try bindScope(scope, to: select!)
            guard sqlite3_bind_double(select, 4, bootStartedAt) == SQLITE_OK else { throw databaseError(db) }
            if sqlite3_step(select) == SQLITE_ROW {
                candidateID = UUID(uuidString: columnText(select!, 0))
                candidateBootStartedAt = sqlite3_column_double(select, 1)
                candidateLastUptime = UInt64(max(0, sqlite3_column_int64(select, 2)))
            }

            // The boot-time estimate includes network/request latency. Fifteen seconds is generous
            // enough for that jitter. Uptime must also have advanced since the last client run;
            // equal or lower uptime is treated conservatively as a new server boot.
            let bootTimeMatches = candidateID != nil && abs(candidateBootStartedAt - bootStartedAt) <= 15.0
            let uptimeAdvanced = UInt64(uptimeTicks) > candidateLastUptime
            let bootID = (bootTimeMatches && uptimeAdvanced) ? candidateID! : UUID()

            var upsert: OpaquePointer?
            try prepare(db, """
                INSERT INTO server_boots_v1
                (server_host, server_port, account_login, boot_id, boot_started_at, last_seen_at, last_uptime_ticks)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(server_host, server_port, account_login, boot_id) DO UPDATE SET
                    last_seen_at=excluded.last_seen_at,
                    last_uptime_ticks=excluded.last_uptime_ticks
                """, &upsert)
            defer { sqlite3_finalize(upsert) }
            try bindScope(scope, to: upsert!)
            try bindText(upsert!, 4, bootID.uuidString.lowercased())
            guard sqlite3_bind_double(upsert, 5, bootStartedAt) == SQLITE_OK,
                  sqlite3_bind_double(upsert, 6, observedAt.timeIntervalSince1970) == SQLITE_OK else {
                throw databaseError(db)
            }
            try bindInt64(upsert!, 7, Int64(uptimeTicks))
            try stepDone(upsert!, db: db)
            return bootID
        }
    }

    func loadBootConversations(scope: MessageCenterStoreScope,
                                 bootID: UUID) throws -> [MessageCenterStoredBootConversation] {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }

            var conversations: [UInt32: MessageCenterStoredBootConversation] = [:]
            var conversationStatement: OpaquePointer?
            try prepare(db, """
                SELECT peer_user_id, nickname, picture, is_legacy, unread_count, draft_text, last_activity
                FROM boot_conversations_v1
                WHERE server_host=? AND server_port=? AND account_login=? AND boot_id=?
                ORDER BY last_activity DESC
                """, &conversationStatement)
            defer { sqlite3_finalize(conversationStatement) }
            try bindScope(scope, to: conversationStatement!)
            try bindText(conversationStatement!, 4, bootID.uuidString.lowercased())
            while true {
                let result = sqlite3_step(conversationStatement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(db) }
                let userID = UInt32(clamping: sqlite3_column_int64(conversationStatement, 0))
                conversations[userID] = MessageCenterStoredBootConversation(
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

            var messageStatement: OpaquePointer?
            try prepare(db, """
                SELECT id, peer_user_id, sent_at, outgoing, body, edited, editable, reactable,
                       my_reaction, peer_reaction
                FROM boot_private_messages_v1
                WHERE server_host=? AND server_port=? AND account_login=? AND boot_id=?
                ORDER BY sent_at ASC, id ASC
                """, &messageStatement)
            defer { sqlite3_finalize(messageStatement) }
            try bindScope(scope, to: messageStatement!)
            try bindText(messageStatement!, 4, bootID.uuidString.lowercased())
            while true {
                let result = sqlite3_step(messageStatement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(db) }
                guard let id = UUID(uuidString: columnText(messageStatement!, 0)) else { continue }
                let userID = UInt32(clamping: sqlite3_column_int64(messageStatement, 1))
                guard var conversation = conversations[userID] else { continue }
                conversation.messages.append(MessageCenterStoredPrivateMessage(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(messageStatement, 2)),
                    outgoing: sqlite3_column_int(messageStatement, 3) != 0,
                    message: columnBlob(messageStatement!, 4),
                    edited: sqlite3_column_int(messageStatement, 5) != 0,
                    editable: sqlite3_column_int(messageStatement, 6) != 0,
                    reactable: sqlite3_column_int(messageStatement, 7) != 0,
                    myReaction: sqlite3_column_type(messageStatement, 8) == SQLITE_NULL
                        ? nil : UInt8(clamping: sqlite3_column_int(messageStatement, 8)),
                    peerReaction: sqlite3_column_type(messageStatement, 9) == SQLITE_NULL
                        ? nil : UInt8(clamping: sqlite3_column_int(messageStatement, 9))
                ))
                conversations[userID] = conversation
            }

            return conversations.values.sorted {
                if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
                return $0.userID < $1.userID
            }
        }
    }

    func saveBootConversation(_ conversation: MessageCenterStoredBootConversation,
                                scope: MessageCenterStoreScope, bootID: UUID) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try upsertBootConversation(conversation, scope: scope, bootID: bootID, db: db)
        }
    }

    func saveBootConversationHistory(_ conversation: MessageCenterStoredBootConversation,
                                       scope: MessageCenterStoreScope, bootID: UUID) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try exec(db, "BEGIN IMMEDIATE")
            do {
                try upsertBootConversation(conversation, scope: scope, bootID: bootID, db: db)
                var deleteStatement: OpaquePointer?
                try prepare(db, """
                    DELETE FROM boot_private_messages_v1
                    WHERE server_host=? AND server_port=? AND account_login=? AND boot_id=? AND peer_user_id=?
                    """, &deleteStatement)
                defer { sqlite3_finalize(deleteStatement) }
                try bindScope(scope, to: deleteStatement!)
                try bindText(deleteStatement!, 4, bootID.uuidString.lowercased())
                try bindInt64(deleteStatement!, 5, Int64(conversation.userID))
                try stepDone(deleteStatement!, db: db)

                if !conversation.messages.isEmpty {
                    var statement: OpaquePointer?
                    try prepare(db, bootMessageInsertSQL, &statement)
                    defer { sqlite3_finalize(statement) }
                    for message in conversation.messages.suffix(500) {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        try bindBootPrivateMessage(message, conversation: conversation, scope: scope,
                                                     bootID: bootID, to: statement!, db: db)
                        try stepDone(statement!, db: db)
                    }
                }
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    func insertBootPrivateMessage(_ message: MessageCenterStoredPrivateMessage,
                                    conversation: MessageCenterStoredBootConversation,
                                    scope: MessageCenterStoreScope, bootID: UUID) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try exec(db, "BEGIN IMMEDIATE")
            do {
                try upsertBootConversation(conversation, scope: scope, bootID: bootID, db: db)
                var statement: OpaquePointer?
                try prepare(db, bootMessageInsertSQL, &statement)
                defer { sqlite3_finalize(statement) }
                try bindBootPrivateMessage(message, conversation: conversation, scope: scope,
                                             bootID: bootID, to: statement!, db: db)
                try stepDone(statement!, db: db)

                var trim: OpaquePointer?
                try prepare(db, """
                    DELETE FROM boot_private_messages_v1
                    WHERE rowid IN (
                        SELECT rowid FROM boot_private_messages_v1
                        WHERE server_host=? AND server_port=? AND account_login=?
                          AND boot_id=? AND peer_user_id=?
                        ORDER BY sent_at DESC, id DESC
                        LIMIT -1 OFFSET 500
                    )
                    """, &trim)
                defer { sqlite3_finalize(trim) }
                try bindScope(scope, to: trim!)
                try bindText(trim!, 4, bootID.uuidString.lowercased())
                try bindInt64(trim!, 5, Int64(conversation.userID))
                try stepDone(trim!, db: db)
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    func clearBootConversation(userID: UInt32, scope: MessageCenterStoreScope, bootID: UUID) throws {
        try deleteBootPrivateMessages(userID: userID, scope: scope, bootID: bootID,
                                        deleteConversation: false)
    }

    func deleteBootConversation(userID: UInt32, scope: MessageCenterStoreScope, bootID: UUID) throws {
        try deleteBootPrivateMessages(userID: userID, scope: scope, bootID: bootID,
                                        deleteConversation: true)
    }

    func markAllBootConversationsRead(scope: MessageCenterStoreScope, bootID: UUID) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            try prepare(db, """
                UPDATE boot_conversations_v1 SET unread_count=0
                WHERE server_host=? AND server_port=? AND account_login=? AND boot_id=?
                """, &statement)
            defer { sqlite3_finalize(statement) }
            try bindScope(scope, to: statement!)
            try bindText(statement!, 4, bootID.uuidString.lowercased())
            try stepDone(statement!, db: db)
        }
    }

    /// Persists a complete durable conversation after a session-only conversation acquires its
    /// stable account identity. The promotion can happen after messages have already accumulated
    /// in memory, so saving only the conversation row would make those messages disappear after
    /// the next application launch.
    func saveConversationHistory(_ conversation: MessageCenterStoredConversation,
                                 scope: MessageCenterStoreScope) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try exec(db, "BEGIN IMMEDIATE")
            do {
                try upsertConversation(conversation, scope: scope, db: db)

                var deleteStatement: OpaquePointer?
                try prepare(db, """
                    DELETE FROM private_messages_v2
                    WHERE server_host=? AND server_port=? AND account_login=? AND peer_account_id=?
                    """, &deleteStatement)
                defer { sqlite3_finalize(deleteStatement) }
                try bindScope(scope, to: deleteStatement!)
                try bindText(deleteStatement!, 4, conversation.accountID.uuidString.lowercased())
                try stepDone(deleteStatement!, db: db)

                let messages = Array(conversation.messages.suffix(500))
                if !messages.isEmpty {
                    let sql = """
                        INSERT OR REPLACE INTO private_messages_v2
                        (id, server_host, server_port, account_login, peer_account_id, sent_at, outgoing, body,
                         edited, editable, reactable, my_reaction, peer_reaction)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """
                    var statement: OpaquePointer?
                    try prepare(db, sql, &statement)
                    defer { sqlite3_finalize(statement) }

                    for message in messages {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        try bindPrivateMessage(message, conversation: conversation, scope: scope,
                                               to: statement!, db: db)
                        try stepDone(statement!, db: db)
                    }
                }
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
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
                    INSERT OR REPLACE INTO private_messages_v2
                    (id, server_host, server_port, account_login, peer_account_id, sent_at, outgoing, body, edited, editable, reactable, my_reaction, peer_reaction)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                var statement: OpaquePointer?
                try prepare(db, sql, &statement)
                defer { sqlite3_finalize(statement) }
                try bindPrivateMessage(message, conversation: conversation, scope: scope,
                                       to: statement!, db: db)
                try stepDone(statement!, db: db)

                var trim: OpaquePointer?
                let trimSQL = """
                    DELETE FROM private_messages_v2
                    WHERE id IN (
                        SELECT id FROM private_messages_v2
                        WHERE server_host=? AND server_port=? AND account_login=? AND peer_account_id=?
                        ORDER BY sent_at DESC, id DESC
                        LIMIT -1 OFFSET 500
                    )
                    """
                try prepare(db, trimSQL, &trim)
                defer { sqlite3_finalize(trim) }
                try bindScope(scope, to: trim!)
                try bindText(trim!, 4, conversation.accountID.uuidString.lowercased())
                try stepDone(trim!, db: db)
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    func clearConversation(accountID: UUID, scope: MessageCenterStoreScope) throws {
        try deletePrivateMessages(accountID: accountID, scope: scope, deleteConversation: false)
    }

    func deleteConversation(accountID: UUID, scope: MessageCenterStoreScope) throws {
        try deletePrivateMessages(accountID: accountID, scope: scope, deleteConversation: true)
    }

    func markAllConversationsRead(scope: MessageCenterStoreScope) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            let sql = "UPDATE conversations_v2 SET unread_count=0 WHERE server_host=? AND server_port=? AND account_login=?"
            var statement: OpaquePointer?
            try prepare(db, sql, &statement)
            defer { sqlite3_finalize(statement) }
            try bindScope(scope, to: statement!)
            try stepDone(statement!, db: db)
        }
    }

    @discardableResult
    func insertOfflineMessages(_ messages: [MessageCenterStoredOfflineMessage],
                               scope: MessageCenterStoreScope) throws -> Set<String> {
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
                    guard sqlite3_bind_int(statement, 9, message.isUnread ? 1 : 0) == SQLITE_OK else {
                        throw databaseError(db)
                    }
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

    private func deletePrivateMessages(accountID: UUID, scope: MessageCenterStoreScope,
                                       deleteConversation: Bool) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try exec(db, "BEGIN IMMEDIATE")
            do {
                var messages: OpaquePointer?
                try prepare(db, "DELETE FROM private_messages_v2 WHERE server_host=? AND server_port=? AND account_login=? AND peer_account_id=?", &messages)
                defer { sqlite3_finalize(messages) }
                try bindScope(scope, to: messages!)
                try bindText(messages!, 4, accountID.uuidString.lowercased())
                try stepDone(messages!, db: db)

                if deleteConversation {
                    var conversation: OpaquePointer?
                    try prepare(db, "DELETE FROM conversations_v2 WHERE server_host=? AND server_port=? AND account_login=? AND peer_account_id=?", &conversation)
                    defer { sqlite3_finalize(conversation) }
                    try bindScope(scope, to: conversation!)
                    try bindText(conversation!, 4, accountID.uuidString.lowercased())
                    try stepDone(conversation!, db: db)
                } else {
                    var conversation: OpaquePointer?
                    try prepare(db, "UPDATE conversations_v2 SET unread_count=0 WHERE server_host=? AND server_port=? AND account_login=? AND peer_account_id=?", &conversation)
                    defer { sqlite3_finalize(conversation) }
                    try bindScope(scope, to: conversation!)
                    try bindText(conversation!, 4, accountID.uuidString.lowercased())
                    try stepDone(conversation!, db: db)
                }
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    private var bootMessageInsertSQL: String {
        """
        INSERT OR REPLACE INTO boot_private_messages_v1
        (id, server_host, server_port, account_login, boot_id, peer_user_id, sent_at, outgoing,
         body, edited, editable, reactable, my_reaction, peer_reaction)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
    }

    private func deleteBootPrivateMessages(userID: UInt32, scope: MessageCenterStoreScope,
                                             bootID: UUID, deleteConversation: Bool) throws {
        try queue.sync {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try exec(db, "BEGIN IMMEDIATE")
            do {
                var messages: OpaquePointer?
                try prepare(db, """
                    DELETE FROM boot_private_messages_v1
                    WHERE server_host=? AND server_port=? AND account_login=? AND boot_id=? AND peer_user_id=?
                    """, &messages)
                defer { sqlite3_finalize(messages) }
                try bindScope(scope, to: messages!)
                try bindText(messages!, 4, bootID.uuidString.lowercased())
                try bindInt64(messages!, 5, Int64(userID))
                try stepDone(messages!, db: db)

                if deleteConversation {
                    var conversation: OpaquePointer?
                    try prepare(db, """
                        DELETE FROM boot_conversations_v1
                        WHERE server_host=? AND server_port=? AND account_login=? AND boot_id=? AND peer_user_id=?
                        """, &conversation)
                    defer { sqlite3_finalize(conversation) }
                    try bindScope(scope, to: conversation!)
                    try bindText(conversation!, 4, bootID.uuidString.lowercased())
                    try bindInt64(conversation!, 5, Int64(userID))
                    try stepDone(conversation!, db: db)
                } else {
                    var conversation: OpaquePointer?
                    try prepare(db, """
                        UPDATE boot_conversations_v1 SET unread_count=0
                        WHERE server_host=? AND server_port=? AND account_login=? AND boot_id=? AND peer_user_id=?
                        """, &conversation)
                    defer { sqlite3_finalize(conversation) }
                    try bindScope(scope, to: conversation!)
                    try bindText(conversation!, 4, bootID.uuidString.lowercased())
                    try bindInt64(conversation!, 5, Int64(userID))
                    try stepDone(conversation!, db: db)
                }
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    private func bindBootPrivateMessage(_ message: MessageCenterStoredPrivateMessage,
                                          conversation: MessageCenterStoredBootConversation,
                                          scope: MessageCenterStoreScope, bootID: UUID,
                                          to statement: OpaquePointer,
                                          db: OpaquePointer) throws {
        try bindText(statement, 1, message.id.uuidString.lowercased())
        try bindScope(scope, to: statement, startIndex: 2)
        try bindText(statement, 5, bootID.uuidString.lowercased())
        try bindInt64(statement, 6, Int64(conversation.userID))
        guard sqlite3_bind_double(statement, 7, message.timestamp.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int(statement, 8, message.outgoing ? 1 : 0) == SQLITE_OK else {
            throw databaseError(db)
        }
        try bindBlob(statement, 9, message.message)
        guard sqlite3_bind_int(statement, 10, message.edited ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_int(statement, 11, message.editable ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_int(statement, 12, message.reactable ? 1 : 0) == SQLITE_OK else {
            throw databaseError(db)
        }
        if let reaction = message.myReaction {
            guard sqlite3_bind_int(statement, 13, Int32(reaction)) == SQLITE_OK else {
                throw databaseError(db)
            }
        } else {
            guard sqlite3_bind_null(statement, 13) == SQLITE_OK else { throw databaseError(db) }
        }
        if let reaction = message.peerReaction {
            guard sqlite3_bind_int(statement, 14, Int32(reaction)) == SQLITE_OK else {
                throw databaseError(db)
            }
        } else {
            guard sqlite3_bind_null(statement, 14) == SQLITE_OK else { throw databaseError(db) }
        }
    }

    private func upsertBootConversation(_ conversation: MessageCenterStoredBootConversation,
                                          scope: MessageCenterStoreScope, bootID: UUID,
                                          db: OpaquePointer) throws {
        var statement: OpaquePointer?
        try prepare(db, """
            INSERT INTO boot_conversations_v1
            (server_host, server_port, account_login, boot_id, peer_user_id, nickname, picture,
             is_legacy, unread_count, draft_text, last_activity)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(server_host, server_port, account_login, boot_id, peer_user_id) DO UPDATE SET
                nickname=excluded.nickname,
                picture=excluded.picture,
                is_legacy=excluded.is_legacy,
                unread_count=excluded.unread_count,
                draft_text=excluded.draft_text,
                last_activity=excluded.last_activity
            """, &statement)
        defer { sqlite3_finalize(statement) }
        try bindScope(scope, to: statement!)
        try bindText(statement!, 4, bootID.uuidString.lowercased())
        try bindInt64(statement!, 5, Int64(conversation.userID))
        try bindText(statement!, 6, conversation.nickname)
        try bindBlob(statement!, 7, conversation.picture)
        guard sqlite3_bind_int(statement, 8, conversation.isLegacyTransport ? 1 : 0) == SQLITE_OK else {
            throw databaseError(db)
        }
        try bindInt64(statement!, 9, Int64(max(0, conversation.unreadCount)))
        try bindText(statement!, 10, conversation.draftText)
        guard sqlite3_bind_double(statement, 11, conversation.lastActivity.timeIntervalSince1970) == SQLITE_OK else {
            throw databaseError(db)
        }
        try stepDone(statement!, db: db)
    }

    private func bindPrivateMessage(_ message: MessageCenterStoredPrivateMessage,
                                    conversation: MessageCenterStoredConversation,
                                    scope: MessageCenterStoreScope,
                                    to statement: OpaquePointer,
                                    db: OpaquePointer) throws {
        try bindText(statement, 1, message.id.uuidString.lowercased())
        try bindScope(scope, to: statement, startIndex: 2)
        try bindText(statement, 5, conversation.accountID.uuidString.lowercased())
        guard sqlite3_bind_double(statement, 6, message.timestamp.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int(statement, 7, message.outgoing ? 1 : 0) == SQLITE_OK else {
            throw databaseError(db)
        }
        try bindBlob(statement, 8, message.message)
        guard sqlite3_bind_int(statement, 9, message.edited ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_int(statement, 10, message.editable ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_int(statement, 11, message.reactable ? 1 : 0) == SQLITE_OK else {
            throw databaseError(db)
        }
        if let reaction = message.myReaction {
            guard sqlite3_bind_int(statement, 12, Int32(reaction)) == SQLITE_OK else {
                throw databaseError(db)
            }
        } else {
            guard sqlite3_bind_null(statement, 12) == SQLITE_OK else { throw databaseError(db) }
        }
        if let reaction = message.peerReaction {
            guard sqlite3_bind_int(statement, 13, Int32(reaction)) == SQLITE_OK else {
                throw databaseError(db)
            }
        } else {
            guard sqlite3_bind_null(statement, 13) == SQLITE_OK else { throw databaseError(db) }
        }
    }

    private func upsertConversation(_ conversation: MessageCenterStoredConversation,
                                    scope: MessageCenterStoreScope,
                                    db: OpaquePointer) throws {
        let sql = """
            INSERT INTO conversations_v2
            (server_host, server_port, account_login, peer_account_id, nickname, picture, is_legacy, unread_count, draft_text, last_activity)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(server_host, server_port, account_login, peer_account_id) DO UPDATE SET
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
        try bindText(statement!, 4, conversation.accountID.uuidString.lowercased())
        try bindText(statement!, 5, conversation.nickname)
        try bindBlob(statement!, 6, conversation.picture)
        guard sqlite3_bind_int(statement, 7, conversation.isLegacyTransport ? 1 : 0) == SQLITE_OK else {
            throw databaseError(db)
        }
        try bindInt64(statement!, 8, Int64(max(0, conversation.unreadCount)))
        try bindText(statement!, 9, conversation.draftText)
        guard sqlite3_bind_double(statement, 10, conversation.lastActivity.timeIntervalSince1970) == SQLITE_OK else {
            throw databaseError(db)
        }
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
                CREATE TABLE IF NOT EXISTS conversations_v2 (
                    server_host TEXT NOT NULL,
                    server_port INTEGER NOT NULL,
                    account_login TEXT NOT NULL,
                    peer_account_id TEXT NOT NULL,
                    nickname TEXT NOT NULL,
                    picture BLOB NOT NULL,
                    is_legacy INTEGER NOT NULL DEFAULT 0,
                    unread_count INTEGER NOT NULL DEFAULT 0,
                    draft_text TEXT NOT NULL DEFAULT '',
                    last_activity REAL NOT NULL,
                    PRIMARY KEY (server_host, server_port, account_login, peer_account_id)
                )
                """)
            var v2Schema: OpaquePointer?
            try prepare(db, "PRAGMA table_info(conversations_v2)", &v2Schema)
            var v2Columns = Set<String>()
            while sqlite3_step(v2Schema) == SQLITE_ROW {
                v2Columns.insert(columnText(v2Schema!, 1))
            }
            sqlite3_finalize(v2Schema)
            if !v2Columns.contains("is_legacy") {
                try exec(db, "ALTER TABLE conversations_v2 ADD COLUMN is_legacy INTEGER NOT NULL DEFAULT 0")
            }

            try exec(db, """
                CREATE TABLE IF NOT EXISTS private_messages_v2 (
                    id TEXT PRIMARY KEY,
                    server_host TEXT NOT NULL,
                    server_port INTEGER NOT NULL,
                    account_login TEXT NOT NULL,
                    peer_account_id TEXT NOT NULL,
                    sent_at REAL NOT NULL,
                    outgoing INTEGER NOT NULL,
                    body BLOB NOT NULL,
                    edited INTEGER NOT NULL DEFAULT 0,
                    editable INTEGER NOT NULL DEFAULT 0,
                    reactable INTEGER NOT NULL DEFAULT 0,
                    my_reaction INTEGER,
                    peer_reaction INTEGER,
                    FOREIGN KEY (server_host, server_port, account_login, peer_account_id)
                        REFERENCES conversations_v2(server_host, server_port, account_login, peer_account_id)
                        ON DELETE CASCADE
                )
                """)
            try exec(db, "CREATE INDEX IF NOT EXISTS private_messages_v2_conversation_idx ON private_messages_v2(server_host, server_port, account_login, peer_account_id, sent_at)")
            try exec(db, """
                CREATE TABLE IF NOT EXISTS server_boots_v1 (
                    server_host TEXT NOT NULL,
                    server_port INTEGER NOT NULL,
                    account_login TEXT NOT NULL,
                    boot_id TEXT NOT NULL,
                    boot_started_at REAL NOT NULL,
                    last_seen_at REAL NOT NULL,
                    last_uptime_ticks INTEGER NOT NULL,
                    PRIMARY KEY (server_host, server_port, account_login, boot_id)
                )
                """)
            try exec(db, "CREATE INDEX IF NOT EXISTS server_boots_v1_time_idx ON server_boots_v1(server_host, server_port, account_login, boot_started_at)")
            try exec(db, """
                CREATE TABLE IF NOT EXISTS boot_conversations_v1 (
                    server_host TEXT NOT NULL,
                    server_port INTEGER NOT NULL,
                    account_login TEXT NOT NULL,
                    boot_id TEXT NOT NULL,
                    peer_user_id INTEGER NOT NULL,
                    nickname TEXT NOT NULL,
                    picture BLOB NOT NULL,
                    is_legacy INTEGER NOT NULL DEFAULT 0,
                    unread_count INTEGER NOT NULL DEFAULT 0,
                    draft_text TEXT NOT NULL DEFAULT '',
                    last_activity REAL NOT NULL,
                    PRIMARY KEY (server_host, server_port, account_login, boot_id, peer_user_id)
                )
                """)
            var bootConversationSchema: OpaquePointer?
            try prepare(db, "PRAGMA table_info(boot_conversations_v1)", &bootConversationSchema)
            var bootConversationColumns = Set<String>()
            while sqlite3_step(bootConversationSchema) == SQLITE_ROW {
                bootConversationColumns.insert(columnText(bootConversationSchema!, 1))
            }
            sqlite3_finalize(bootConversationSchema)
            if !bootConversationColumns.contains("is_legacy") {
                try exec(db, "ALTER TABLE boot_conversations_v1 ADD COLUMN is_legacy INTEGER NOT NULL DEFAULT 0")
            }

            try exec(db, """
                CREATE TABLE IF NOT EXISTS boot_private_messages_v1 (
                    id TEXT NOT NULL,
                    server_host TEXT NOT NULL,
                    server_port INTEGER NOT NULL,
                    account_login TEXT NOT NULL,
                    boot_id TEXT NOT NULL,
                    peer_user_id INTEGER NOT NULL,
                    sent_at REAL NOT NULL,
                    outgoing INTEGER NOT NULL,
                    body BLOB NOT NULL,
                    edited INTEGER NOT NULL DEFAULT 0,
                    editable INTEGER NOT NULL DEFAULT 0,
                    reactable INTEGER NOT NULL DEFAULT 0,
                    my_reaction INTEGER,
                    peer_reaction INTEGER,
                    PRIMARY KEY (id, server_host, server_port, account_login, boot_id, peer_user_id),
                    FOREIGN KEY (server_host, server_port, account_login, boot_id, peer_user_id)
                        REFERENCES boot_conversations_v1(server_host, server_port, account_login, boot_id, peer_user_id)
                        ON DELETE CASCADE
                )
                """)
            try exec(db, "CREATE INDEX IF NOT EXISTS boot_private_messages_v1_conversation_idx ON boot_private_messages_v1(server_host, server_port, account_login, boot_id, peer_user_id, sent_at)")
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

    private func bindScope(_ scope: MessageCenterStoreScope, to statement: OpaquePointer,
                           startIndex: Int32 = 1) throws {
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
