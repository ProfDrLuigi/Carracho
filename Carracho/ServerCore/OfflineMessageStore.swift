import Foundation
import CryptoKit
import SQLite3

struct ServerStoredOfflineMessage: Equatable {
    var id: String
    var createdAtUnix: UInt64
    var plaintext: Data
}

enum ServerOfflineMessageStoreError: LocalizedError {
    case database(String)
    case key(String)
    case crypto(String)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case let .database(message): return "Offline-message database error: \(message)"
        case let .key(message): return "Offline-message encryption-key error: \(message)"
        case let .crypto(message): return "Offline-message encryption error: \(message)"
        case let .corrupt(message): return "Offline-message data is corrupt: \(message)"
        }
    }
}

extension ServerStateStore {
    private static var offlineSQLiteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private var offlineMessageKeyURL: URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("server-message.key")
    }

    private func offlineOpenDatabase() throws -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw ServerOfflineMessageStoreError.database(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        try offlineExec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
        try offlineCreateSchema(db)
        return db
    }

    private func offlineCreateSchema(_ db: OpaquePointer?) throws {
        try offlineExec(db, """
        CREATE TABLE IF NOT EXISTS offline_messages (
            id TEXT PRIMARY KEY,
            recipient_account_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL,
            tag BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS offline_messages_recipient_idx
            ON offline_messages(recipient_account_id, created_at, id);
        """)
    }

    private func offlineEncryptionKey() throws -> SymmetricKey {
        let manager = FileManager.default
        let directory = offlineMessageKeyURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if manager.fileExists(atPath: offlineMessageKeyURL.path) {
            let data = try Data(contentsOf: offlineMessageKeyURL)
            guard data.count == 32 else { throw ServerOfflineMessageStoreError.key("server-message.key must contain exactly 32 bytes") }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do {
            try data.write(to: offlineMessageKeyURL, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: offlineMessageKeyURL.path)
        } catch CocoaError.fileWriteFileExists {
            let existing = try Data(contentsOf: offlineMessageKeyURL)
            guard existing.count == 32 else { throw ServerOfflineMessageStoreError.key("concurrent key creation produced an invalid key") }
            return SymmetricKey(data: existing)
        }
        return key
    }

    private func offlineAAD(id: String, recipientAccountID: UUID) -> Data {
        Data("CarrachoOfflineMessage/v1|\(id)|\(recipientAccountID.uuidString.lowercased())".utf8)
    }

    @discardableResult
    func enqueueOfflineMessage(recipientAccountID: UUID, plaintext: Data, createdAtUnix: UInt64 = UInt64(Date().timeIntervalSince1970)) throws -> String {
        guard !plaintext.isEmpty, plaintext.count <= 0x10000 else {
            throw ServerOfflineMessageStoreError.corrupt("plaintext length out of range")
        }
        let id = UUID().uuidString.lowercased()
        let key = try offlineEncryptionKey()
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key, authenticating: offlineAAD(id: id, recipientAccountID: recipientAccountID))
        } catch {
            throw ServerOfflineMessageStoreError.crypto(error.localizedDescription)
        }
        let nonce = Data(sealed.nonce)
        let ciphertext = sealed.ciphertext
        let tag = sealed.tag
        let db = try offlineOpenDatabase()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "INSERT INTO offline_messages(id,recipient_account_id,created_at,nonce,ciphertext,tag) VALUES(?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ServerOfflineMessageStoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, id, -1, Self.offlineSQLiteTransient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, recipientAccountID.uuidString.lowercased(), -1, Self.offlineSQLiteTransient) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, sqlite3_int64(min(createdAtUnix, UInt64(Int64.max)))) == SQLITE_OK,
              bindOfflineBlob(statement, index: 4, data: nonce),
              bindOfflineBlob(statement, index: 5, data: ciphertext),
              bindOfflineBlob(statement, index: 6, data: tag),
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ServerOfflineMessageStoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        return id
    }

    func offlineMessageCount(recipientAccountID: UUID) throws -> Int {
        let db = try offlineOpenDatabase()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM offline_messages WHERE recipient_account_id=?", -1, &statement, nil) == SQLITE_OK else {
            throw ServerOfflineMessageStoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, recipientAccountID.uuidString.lowercased(), -1, Self.offlineSQLiteTransient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw ServerOfflineMessageStoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func loadOfflineMessages(recipientAccountID: UUID) throws -> [ServerStoredOfflineMessage] {
        let key = try offlineEncryptionKey()
        let db = try offlineOpenDatabase()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT id,created_at,nonce,ciphertext,tag FROM offline_messages WHERE recipient_account_id=? ORDER BY created_at,id"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ServerOfflineMessageStoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, recipientAccountID.uuidString.lowercased(), -1, Self.offlineSQLiteTransient) == SQLITE_OK else {
            throw ServerOfflineMessageStoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        var result: [ServerStoredOfflineMessage] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let idPointer = sqlite3_column_text(statement, 0) else {
                throw ServerOfflineMessageStoreError.database(String(cString: sqlite3_errmsg(db)))
            }
            let id = String(cString: idPointer)
            let created = UInt64(max(0, sqlite3_column_int64(statement, 1)))
            let nonceData = offlineColumnBlob(statement, column: 2)
            let ciphertext = offlineColumnBlob(statement, column: 3)
            let tag = offlineColumnBlob(statement, column: 4)
            do {
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                let plaintext = try AES.GCM.open(box, using: key, authenticating: offlineAAD(id: id, recipientAccountID: recipientAccountID))
                result.append(.init(id: id, createdAtUnix: created, plaintext: plaintext))
            } catch {
                throw ServerOfflineMessageStoreError.crypto("message \(id) could not be authenticated/decrypted")
            }
        }
        return result
    }

    func acknowledgeOfflineMessages(recipientAccountID: UUID, ids: [String]) throws {
        let cleanIDs = Array(Set(ids.filter { UUID(uuidString: $0) != nil }))
        guard !cleanIDs.isEmpty else { return }
        let db = try offlineOpenDatabase()
        defer { sqlite3_close(db) }
        try offlineExec(db, "BEGIN IMMEDIATE TRANSACTION")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM offline_messages WHERE recipient_account_id=? AND id=?", -1, &statement, nil) == SQLITE_OK else {
                throw ServerOfflineMessageStoreError.database(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            for id in cleanIDs {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                guard sqlite3_bind_text(statement, 1, recipientAccountID.uuidString.lowercased(), -1, Self.offlineSQLiteTransient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, id.lowercased(), -1, Self.offlineSQLiteTransient) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else {
                    throw ServerOfflineMessageStoreError.database(String(cString: sqlite3_errmsg(db)))
                }
            }
            try offlineExec(db, "COMMIT")
        } catch {
            try? offlineExec(db, "ROLLBACK")
            throw error
        }
    }

    private func bindOfflineBlob(_ statement: OpaquePointer?, index: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), Self.offlineSQLiteTransient) == SQLITE_OK
        }
    }

    private func offlineColumnBlob(_ statement: OpaquePointer?, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func offlineExec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error"
            if let error { sqlite3_free(error) }
            throw ServerOfflineMessageStoreError.database(message)
        }
    }
}
