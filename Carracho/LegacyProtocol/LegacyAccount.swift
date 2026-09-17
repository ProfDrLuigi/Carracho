import Foundation


enum LegacyAccountField {
    /// Modern Carracho extension: UTF-8 UUID string naming one of the three fixed account groups.
    static let groupID: UInt32 = 0xf0000010
    /// Modern Carracho extension: per-account 24-bit nickname color (big-endian UInt32).
    static let colorRGB: UInt32 = 0xf0000011
    /// Modern Carracho extension: persisted PNG/avatar bytes for account administration.
    static let picture: UInt32 = 0xf0000012
    /// Modern Carracho extension: read-only marker for accounts that can only be activated locally.
    static let localLoginOnly: UInt32 = 0xf0000013
    /// Modern Carracho extension: parallel per-account transfer counters for account-list replies.
    static let transferStatistics: UInt32 = 0xf0000014
}

struct LegacyAccountDetails: Equatable {
    var record: LegacyAccountRecord
    var groupID: UUID?
    var colorRGB: UInt32? = nil
    var picture: Data? = nil
    var localLoginOnly: Bool = false
}

struct LegacyAccountRecord: Equatable {
    static let wireSize = 0xD6

    var login: Data
    var name: Data
    var password: Data
    var created: UInt32
    var modified: UInt32
    var lastLogin: UInt32
    /// Exact 8 bytes used by the classic Mac Toolbox BitSet/BitTst calls.
    /// Kept opaque at the wire layer so bit-numbering policy is not guessed here.
    var permissionBytes: Data

    init(login: Data, name: Data, password: Data, created: UInt32 = 0,
         modified: UInt32 = 0, lastLogin: UInt32 = 0,
         permissionBytes: Data = Data(repeating: 0, count: 8)) {
        self.login = login
        self.name = name
        self.password = password
        self.created = created
        self.modified = modified
        self.lastLogin = lastLogin
        self.permissionBytes = permissionBytes
    }

    func encoded() throws -> Data {
        guard permissionBytes.count == 8 else {
            throw LegacyProtocolError.invalidLength("account permission bitset must be exactly 8 bytes")
        }
        var data = try LegacyWire.fixedCString(login, width: 64)
        data.append(try LegacyWire.fixedCString(name, width: 65))
        data.append(try LegacyWire.fixedCString(password, width: 65))
        data.append(LegacyWire.uint32BE(created))
        data.append(LegacyWire.uint32BE(modified))
        data.append(LegacyWire.uint32BE(lastLogin))
        data.append(permissionBytes)
        guard data.count == Self.wireSize else {
            throw LegacyProtocolError.invalidRecord("full account record is not 214 bytes")
        }
        return data
    }

    static func decode(_ data: Data) throws -> LegacyAccountRecord {
        guard data.count == wireSize else {
            throw LegacyProtocolError.invalidLength("full account record must be exactly 214 bytes")
        }
        var cursor = LegacyByteCursor(data)
        let login = LegacyWire.readFixedCString(try cursor.readBytes(count: 64))
        let name = LegacyWire.readFixedCString(try cursor.readBytes(count: 65))
        let password = LegacyWire.readFixedCString(try cursor.readBytes(count: 65))
        let created = try cursor.readUInt32BE()
        let modified = try cursor.readUInt32BE()
        let lastLogin = try cursor.readUInt32BE()
        let permissions = try cursor.readBytes(count: 8)
        try cursor.requireEnd()
        return LegacyAccountRecord(login: login, name: name, password: password,
                                   created: created, modified: modified, lastLogin: lastLogin,
                                   permissionBytes: permissions)
    }
}


struct LegacyAccountTransferStatistics: Equatable {
    static let wireSize = 32

    var downloadCount: UInt64
    var downloadBytes: UInt64
    var uploadCount: UInt64
    var uploadBytes: UInt64

    func encoded() -> Data {
        var data = LegacyWire.uint64BE(downloadCount)
        data.append(LegacyWire.uint64BE(downloadBytes))
        data.append(LegacyWire.uint64BE(uploadCount))
        data.append(LegacyWire.uint64BE(uploadBytes))
        return data
    }

    static func decode(from cursor: inout LegacyByteCursor) throws -> LegacyAccountTransferStatistics {
        LegacyAccountTransferStatistics(downloadCount: try cursor.readUInt64BE(),
                                        downloadBytes: try cursor.readUInt64BE(),
                                        uploadCount: try cursor.readUInt64BE(),
                                        uploadBytes: try cursor.readUInt64BE())
    }
}

struct LegacyCompactAccountSummary: Equatable {
    static let wireSize = 0x88

    enum UserMode: UInt8 {
        case guest = 0
        case accountHolder = 1
        case administrator = 2
    }

    var login: Data
    var name: Data
    var lastLogin: UInt32
    var userMode: UInt8
    /// Byte 0x87 is serializer stack padding in the classic server; emit zero for deterministic modern output.
    var legacyPadding: UInt8
    /// Modern-only account-list metadata carried in a separate TLV, never inside the 136-byte classic record.
    var transferStatistics: LegacyAccountTransferStatistics? = nil

    func encoded() throws -> Data {
        var data = try LegacyWire.fixedCString(login, width: 64)
        data.append(try LegacyWire.fixedCString(name, width: 66))
        data.append(LegacyWire.uint32BE(lastLogin))
        data.append(userMode)
        data.append(legacyPadding)
        guard data.count == Self.wireSize else {
            throw LegacyProtocolError.invalidRecord("compact account record is not 136 bytes")
        }
        return data
    }

    static func decode(_ data: Data) throws -> LegacyCompactAccountSummary {
        guard data.count == wireSize else {
            throw LegacyProtocolError.invalidLength("compact account summary must be exactly 136 bytes")
        }
        var cursor = LegacyByteCursor(data)
        let login = LegacyWire.readFixedCString(try cursor.readBytes(count: 64))
        let name = LegacyWire.readFixedCString(try cursor.readBytes(count: 66))
        let lastLogin = try cursor.readUInt32BE()
        let mode = try cursor.readUInt8()
        let legacyPadding = try cursor.readUInt8()
        try cursor.requireEnd()
        return LegacyCompactAccountSummary(login: login, name: name, lastLogin: lastLogin,
                                           userMode: mode, legacyPadding: legacyPadding)
    }
}

extension LegacyPackedRecords {
    static func encodeCompactAccountList(_ accounts: [LegacyCompactAccountSummary]) throws -> Data {
        var data = LegacyWire.uint32BE(UInt32(accounts.count))
        for account in accounts { data.append(try account.encoded()) }
        return data
    }

    static func decodeCompactAccountList(_ data: Data) throws -> [LegacyCompactAccountSummary] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        var result: [LegacyCompactAccountSummary] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            result.append(try LegacyCompactAccountSummary.decode(
                cursor.readBytes(count: LegacyCompactAccountSummary.wireSize)
            ))
        }
        try cursor.requireEnd()
        return result
    }

    static func encodeAccountTransferStatistics(_ statistics: [LegacyAccountTransferStatistics]) throws -> Data {
        guard statistics.count <= Int(UInt32.max) else {
            throw LegacyProtocolError.invalidLength("too many account transfer statistics")
        }
        var data = LegacyWire.uint32BE(UInt32(statistics.count))
        for value in statistics { data.append(value.encoded()) }
        guard data.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("account transfer statistics exceed one TLV")
        }
        return data
    }

    static func decodeAccountTransferStatistics(_ data: Data, expectedCount: Int) throws -> [LegacyAccountTransferStatistics] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        guard count == expectedCount else {
            throw LegacyProtocolError.invalidRecord("account transfer statistics count does not match account list")
        }
        guard data.count == 4 + count * LegacyAccountTransferStatistics.wireSize else {
            throw LegacyProtocolError.invalidLength("account transfer statistics payload has invalid length")
        }
        var result: [LegacyAccountTransferStatistics] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try LegacyAccountTransferStatistics.decode(from: &cursor)) }
        try cursor.requireEnd()
        return result
    }
}

nonisolated enum LegacyAccountPermissionBit {
    static let administrator = 0x00
    static let accountHolder = 0x01
    static let personalDirectoryNestedInRoot = 0x03
    static let personalDirectoryIsRoot = 0x04
    static let download = 0x0a
    static let upload = 0x0b
    static let uploadAnywhere = 0x0c
    static let viewDropboxes = 0x0d
    static let changeFolderMode = 0x0e
    static let moveFiles = 0x0f
    static let deleteFiles = 0x10
    static let renameFiles = 0x11
    static let commentFiles = 0x12
    static let createFolders = 0x13
    static let moveFolders = 0x14
    static let renameFolders = 0x15
    static let deleteFolders = 0x16
    static let commentFolders = 0x17
    static let disconnectUsers = 0x18
    static let extendedUserInfo = 0x19
    static let joinChatRooms = 0x1c
    static let manageAccounts = 0x21
    static let manageNewsgroups = 0x22
    static let viewServerLog = 0x23
    static let editServerInformation = 0x24
    static let editAdvancedSettings = 0x25
    static let manageTransfers = 0x26
    static let emptyServerTrash = 0x27
    static let broadcastMessages = 0x28
    static let banUsers = 0x2a
    static let editServerAgreement = 0x2c
    static let viewStatistics = 0x2d
    static let editTrackers = 0x2e
    static let searchFiles = 0x2f
    static let postFlatNews = 0x30
}
