import Foundation

struct LegacyDirectoryEntry: Equatable {
    var name: Data
    var size: UInt32
    var timestamp: UInt32
    var fileType: UInt32
    var creator: UInt32
    var flags: UInt16
    /// Out-of-band modern-client label metadata. Never serialized into the Classic packed record.
    var label: LegacyFileLabel = .none

    func encoded() throws -> Data {
        guard name.count <= Int(UInt16.max) - 20 else {
            throw LegacyProtocolError.invalidLength("directory entry name too long")
        }
        var data = LegacyWire.uint16BE(UInt16(name.count + 20))
        data.append(LegacyWire.uint16BE(UInt16(name.count)))
        data.append(name)
        data.append(LegacyWire.uint32BE(size))
        data.append(LegacyWire.uint32BE(timestamp))
        data.append(LegacyWire.uint32BE(fileType))
        data.append(LegacyWire.uint32BE(creator))
        data.append(LegacyWire.uint16BE(flags))
        return data
    }
}

struct LegacyDirectoryListing: Equatable {
    var currentPath: Data
    var entries: [LegacyDirectoryEntry]

    func encoded() throws -> Data {
        guard entries.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("too many directory entries")
        }
        var data = try LegacyWire.string16(currentPath)
        data.append(LegacyWire.uint16BE(UInt16(entries.count)))
        for entry in entries { data.append(try entry.encoded()) }
        return data
    }

    static func decode(_ data: Data) throws -> LegacyDirectoryListing {
        var cursor = LegacyByteCursor(data)
        let path = try cursor.readString16()
        let count = Int(try cursor.readUInt16BE())
        var entries: [LegacyDirectoryEntry] = []
        entries.reserveCapacity(count)
        for _ in 0 ..< count {
            let recordSize = Int(try cursor.readUInt16BE())
            let start = cursor.offset
            let name = try cursor.readBytes(count: Int(cursor.readUInt16BE()))
            let entry = LegacyDirectoryEntry(
                name: name,
                size: try cursor.readUInt32BE(),
                timestamp: try cursor.readUInt32BE(),
                fileType: try cursor.readUInt32BE(),
                creator: try cursor.readUInt32BE(),
                flags: try cursor.readUInt16BE()
            )
            guard cursor.offset - start == recordSize else {
                throw LegacyProtocolError.invalidRecord("directory record-size mismatch")
            }
            entries.append(entry)
        }
        try cursor.requireEnd()
        return LegacyDirectoryListing(currentPath: path, entries: entries)
    }
}

struct LegacyUserListEntry: Equatable {
    var nickname: Data
    var flags: UInt16
    var userID: UInt32
    var picture: Data
    /// Out-of-band modern-client metadata. This is intentionally not part of the Classic packed record.
    var isLegacyTransport = false

    func encoded() throws -> Data {
        var data = try LegacyWire.string16(nickname)
        data.append(LegacyWire.uint16BE(flags))
        data.append(LegacyWire.uint32BE(userID))
        guard picture.count <= Int(UInt32.max) else { throw LegacyProtocolError.invalidLength("picture too large") }
        data.append(LegacyWire.uint32BE(UInt32(picture.count)))
        data.append(picture)
        return data
    }
}

enum LegacyPackedRecords {
    static func encodeUserList(_ users: [LegacyUserListEntry]) throws -> Data {
        guard users.count <= Int(UInt32.max) else { throw LegacyProtocolError.invalidLength("too many users") }
        var data = LegacyWire.uint32BE(UInt32(users.count))
        for user in users { data.append(try user.encoded()) }
        return data
    }

    static func decodeUserList(_ data: Data) throws -> [LegacyUserListEntry] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        var users: [LegacyUserListEntry] = []
        users.reserveCapacity(count)
        for _ in 0 ..< count {
            let nickname = try cursor.readString16()
            let flags = try cursor.readUInt16BE()
            let userID = try cursor.readUInt32BE()
            let pictureLength = Int(try cursor.readUInt32BE())
            users.append(LegacyUserListEntry(nickname: nickname, flags: flags, userID: userID,
                                             picture: try cursor.readBytes(count: pictureLength)))
        }
        try cursor.requireEnd()
        return users
    }
}

struct LegacyChannelSummary: Equatable {
    /// Classic channel-list bit indicating that joining requires a room password.
    static let passwordProtectedFlag: UInt16 = 0x0001

    var channelID: UInt32
    var memberCount: UInt32
    var flags: UInt16
    var name: Data

    var isPasswordProtected: Bool {
        flags & Self.passwordProtectedFlag != 0
    }

    func encoded() throws -> Data {
        var data = LegacyWire.uint32BE(channelID)
        data.append(LegacyWire.uint32BE(memberCount))
        data.append(LegacyWire.uint16BE(flags))
        data.append(try LegacyWire.string16(name))
        return data
    }
}

struct LegacyChannelMember: Equatable {
    var userID: UInt32
    var mode: UInt8

    func encoded() -> Data {
        var data = LegacyWire.uint32BE(userID)
        data.append(mode)
        return data
    }
}

extension LegacyPackedRecords {
    static func encodeChannelList(_ channels: [LegacyChannelSummary]) throws -> Data {
        var data = LegacyWire.uint32BE(UInt32(channels.count))
        for channel in channels { data.append(try channel.encoded()) }
        return data
    }

    static func decodeChannelList(_ data: Data) throws -> [LegacyChannelSummary] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        var result: [LegacyChannelSummary] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            result.append(LegacyChannelSummary(
                channelID: try cursor.readUInt32BE(),
                memberCount: try cursor.readUInt32BE(),
                flags: try cursor.readUInt16BE(),
                name: try cursor.readString16()
            ))
        }
        try cursor.requireEnd()
        return result
    }

    static func encodeChannelMembers(_ members: [LegacyChannelMember]) -> Data {
        var data = LegacyWire.uint32BE(UInt32(members.count))
        for member in members { data.append(member.encoded()) }
        return data
    }

    static func decodeChannelMembers(_ data: Data) throws -> [LegacyChannelMember] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        var result: [LegacyChannelMember] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            result.append(LegacyChannelMember(userID: try cursor.readUInt32BE(), mode: try cursor.readUInt8()))
        }
        try cursor.requireEnd()
        return result
    }

    static func encodeNewsgroupList(_ names: [Data]) throws -> Data {
        var data = LegacyWire.uint32BE(UInt32(names.count))
        for name in names { data.append(try LegacyWire.string16(name)) }
        return data
    }

    static func decodeNewsgroupList(_ data: Data) throws -> [Data] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        var result: [Data] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count { result.append(try cursor.readString16()) }
        try cursor.requireEnd()
        return result
    }
}

struct LegacyAdminNewsgroup: Equatable {
    var name: Data
    var articleCount: UInt32
    /// Expiration age in seconds; UInt32.max means never expire.
    var expireAfterSeconds: UInt32
    /// Six classic BitTst/BitSet permission bits: read/post for admin, account holder, guest.
    var flags: UInt16

    func encoded() throws -> Data {
        var data = try LegacyWire.string16(name)
        data.append(LegacyWire.uint32BE(articleCount))
        data.append(LegacyWire.uint32BE(expireAfterSeconds))
        data.append(LegacyWire.uint16BE(flags))
        return data
    }
}

extension LegacyPackedRecords {
    static func encodeAdminNewsgroupList(_ groups: [LegacyAdminNewsgroup]) throws -> Data {
        var data = LegacyWire.uint32BE(UInt32(groups.count))
        for group in groups { data.append(try group.encoded()) }
        return data
    }

    static func decodeAdminNewsgroupList(_ data: Data) throws -> [LegacyAdminNewsgroup] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        var result: [LegacyAdminNewsgroup] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            result.append(LegacyAdminNewsgroup(name: try cursor.readString16(),
                                              articleCount: try cursor.readUInt32BE(),
                                              expireAfterSeconds: try cursor.readUInt32BE(),
                                              flags: try cursor.readUInt16BE()))
        }
        try cursor.requireEnd()
        return result
    }
}

// MARK: - Administrative transfer/task monitor records

enum LegacyTransferKind {
    static let download: UInt8 = 1
    static let upload: UInt8 = 2
}

/// Exact value of each TLV type 1 in the administrative command 0xe0 reply.
struct LegacyTransferInfoRecord: Equatable {
    var kind: UInt8
    var userID: UInt32
    var path: Data
    var bytesTransferred: UInt64
    var totalBytes: UInt64
    /// Raw bits of the final eight-byte legacy descriptor field. Server 1.0b13
    /// emits IEEE-754 +0.0 (all-zero bits) for both upload and download records.
    var legacyMetricBits: UInt64 = 0

    func encoded() throws -> Data {
        var data = Data([kind])
        data.append(LegacyWire.uint32BE(userID))
        data.append(try LegacyWire.string16(path))
        data.append(LegacyWire.uint64BE(bytesTransferred))
        data.append(LegacyWire.uint64BE(totalBytes))
        data.append(LegacyWire.uint64BE(legacyMetricBits))
        return data
    }

    static func decode(_ data: Data) throws -> LegacyTransferInfoRecord {
        var cursor = LegacyByteCursor(data)
        let value = LegacyTransferInfoRecord(
            kind: try cursor.readUInt8(),
            userID: try cursor.readUInt32BE(),
            path: try cursor.readString16(),
            bytesTransferred: try cursor.readUInt64BE(),
            totalBytes: try cursor.readUInt64BE(),
            legacyMetricBits: try cursor.readUInt64BE()
        )
        try cursor.requireEnd()
        return value
    }
}


enum LegacyTransferMonitorField {
    /// Repeated classic transfer descriptor. Kept unchanged for old administrative clients.
    static let transferRecord: UInt32 = 1
    /// Server outbound file bandwidth cap in bytes/second. Zero means unlimited.
    static let uploadBandwidthLimit: UInt32 = 2
    /// Current aggregate file-download traffic in bytes/second.
    static let downloadTrafficRate: UInt32 = 3
    /// Additive managed-transfer descriptor used by modern Carracho clients.
    static let managedTransferRecord: UInt32 = 4
    /// Request payload for pause/resume/abort of one managed transfer.
    static let transferControl: UInt32 = 5
}

enum LegacyTransferControlAction: UInt8 {
    case pause = 1
    case resume = 2
    case abort = 3
}

struct LegacyTransferControlRequest: Equatable {
    var transferID: UInt32
    var action: LegacyTransferControlAction

    func encoded() -> Data {
        var data = LegacyWire.uint32BE(transferID)
        data.append(action.rawValue)
        return data
    }

    static func decode(_ data: Data) throws -> LegacyTransferControlRequest {
        var cursor = LegacyByteCursor(data)
        let transferID = try cursor.readUInt32BE()
        guard let action = LegacyTransferControlAction(rawValue: try cursor.readUInt8()) else {
            throw LegacyProtocolError.invalidRecord("unknown transfer-control action")
        }
        try cursor.requireEnd()
        return LegacyTransferControlRequest(transferID: transferID, action: action)
    }
}

struct LegacyManagedTransferRecord: Equatable {
    static let pausedFlag: UInt8 = 1 << 0
    static let abortingFlag: UInt8 = 1 << 1
    /// Modern-only metadata bit. The classic type-1 transfer descriptor remains byte-for-byte unchanged.
    static let directoryFlag: UInt8 = 1 << 2

    var transferID: UInt32
    var kind: UInt8
    var userID: UInt32
    var path: Data
    var bytesTransferred: UInt64
    var totalBytes: UInt64
    var flags: UInt8 = 0

    var isPaused: Bool { flags & Self.pausedFlag != 0 }
    var isAborting: Bool { flags & Self.abortingFlag != 0 }
    var isDirectory: Bool { flags & Self.directoryFlag != 0 }

    func encoded() throws -> Data {
        var data = LegacyWire.uint32BE(transferID)
        data.append(kind)
        data.append(LegacyWire.uint32BE(userID))
        data.append(try LegacyWire.string16(path))
        data.append(LegacyWire.uint64BE(bytesTransferred))
        data.append(LegacyWire.uint64BE(totalBytes))
        data.append(flags)
        return data
    }

    static func decode(_ data: Data) throws -> LegacyManagedTransferRecord {
        var cursor = LegacyByteCursor(data)
        let value = LegacyManagedTransferRecord(
            transferID: try cursor.readUInt32BE(),
            kind: try cursor.readUInt8(),
            userID: try cursor.readUInt32BE(),
            path: try cursor.readString16(),
            bytesTransferred: try cursor.readUInt64BE(),
            totalBytes: try cursor.readUInt64BE(),
            flags: try cursor.readUInt8()
        )
        try cursor.requireEnd()
        return value
    }
}

/// Extended server-wide transfer monitor state carried by command 0xe0.
/// New fields are additive so classic clients that only consume TLV type 1 remain compatible.
struct LegacyTransferMonitorSnapshot: Equatable {
    var transfers: [LegacyTransferInfoRecord]
    var managedTransfers: [LegacyManagedTransferRecord] = []
    var uploadBandwidthLimitBytesPerSecond: UInt64?
    var downloadTrafficBytesPerSecond: UInt64?

    static func decode(fields: [LegacyTLV]) throws -> LegacyTransferMonitorSnapshot {
        let transfers = try fields
            .filter { $0.type == LegacyTransferMonitorField.transferRecord }
            .map { try LegacyTransferInfoRecord.decode($0.value) }
        let managedTransfers = try fields
            .filter { $0.type == LegacyTransferMonitorField.managedTransferRecord }
            .map { try LegacyManagedTransferRecord.decode($0.value) }
        let limit = try decodeUInt64Field(fields.first { $0.type == LegacyTransferMonitorField.uploadBandwidthLimit })
        let rate = try decodeUInt64Field(fields.first { $0.type == LegacyTransferMonitorField.downloadTrafficRate })
        return LegacyTransferMonitorSnapshot(transfers: transfers, managedTransfers: managedTransfers,
                                             uploadBandwidthLimitBytesPerSecond: limit,
                                             downloadTrafficBytesPerSecond: rate)
    }

    private static func decodeUInt64Field(_ field: LegacyTLV?) throws -> UInt64? {
        guard let field else { return nil }
        guard field.value.count == 8 else {
            throw LegacyProtocolError.invalidLength("transfer monitor UInt64 field must be exactly 8 bytes")
        }
        var cursor = LegacyByteCursor(field.value)
        let value = try cursor.readUInt64BE()
        try cursor.requireEnd()
        return value
    }
}

/// Compact per-transfer record inside privileged user-info TLV 0x86.
struct LegacyCompactTaskInfo: Equatable {
    var transferID: UInt32
    var kind: UInt8
    var displayName: Data
    var progressPercent: UInt8

    func encoded() throws -> Data {
        var data = LegacyWire.uint32BE(transferID)
        data.append(kind)
        data.append(try LegacyWire.string16(displayName))
        data.append(progressPercent)
        return data
    }

    static func decode(from cursor: inout LegacyByteCursor) throws -> LegacyCompactTaskInfo {
        LegacyCompactTaskInfo(transferID: try cursor.readUInt32BE(),
                              kind: try cursor.readUInt8(),
                              displayName: try cursor.readString16(),
                              progressPercent: try cursor.readUInt8())
    }
}

extension LegacyPackedRecords {
    static func encodeCompactTaskList(_ tasks: [LegacyCompactTaskInfo]) throws -> Data {
        guard tasks.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("too many compact task records")
        }
        var data = LegacyWire.uint16BE(UInt16(tasks.count))
        for task in tasks { data.append(try task.encoded()) }
        return data
    }

    static func decodeCompactTaskList(_ data: Data) throws -> [LegacyCompactTaskInfo] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt16BE())
        var result: [LegacyCompactTaskInfo] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try LegacyCompactTaskInfo.decode(from: &cursor)) }
        try cursor.requireEnd()
        return result
    }
}


struct LegacyOfflineMessage: Equatable {
    static let maximumMessageLength = 4096
    static let maximumQueuedMessages = 24

    var id: String
    var sentAtUnix: UInt64
    var senderLogin: Data
    var senderNickname: Data
    var message: Data

    func encoded() throws -> Data {
        guard let idData = id.data(using: .utf8), idData.count <= 64,
              senderLogin.count <= 255,
              senderNickname.count <= 255,
              !message.isEmpty, message.count <= Self.maximumMessageLength else {
            throw LegacyProtocolError.invalidLength("offline message record exceeds limits")
        }
        var data = try LegacyWire.string16(idData)
        data.append(LegacyWire.uint64BE(sentAtUnix))
        data.append(try LegacyWire.string16(senderLogin))
        data.append(try LegacyWire.string16(senderNickname))
        data.append(try LegacyWire.string16(message))
        return data
    }

    static func decode(_ data: Data) throws -> LegacyOfflineMessage {
        var cursor = LegacyByteCursor(data)
        let idData = try cursor.readString16()
        guard let id = String(data: idData, encoding: .utf8), !id.isEmpty else {
            throw LegacyProtocolError.invalidRecord("invalid offline message id")
        }
        let value = LegacyOfflineMessage(id: id,
                                         sentAtUnix: try cursor.readUInt64BE(),
                                         senderLogin: try cursor.readString16(),
                                         senderNickname: try cursor.readString16(),
                                         message: try cursor.readString16())
        try cursor.requireEnd()
        return value
    }
}


struct LegacyOfflineMessageRecipient: Equatable {
    var login: Data
    var nickname: Data

    func encoded() throws -> Data {
        guard !login.isEmpty, login.count <= 63, nickname.count <= 255 else {
            throw LegacyProtocolError.invalidLength("offline-message recipient exceeds limits")
        }
        var data = try LegacyWire.string16(login)
        data.append(try LegacyWire.string16(nickname))
        return data
    }

    static func decode(_ data: Data) throws -> LegacyOfflineMessageRecipient {
        var cursor = LegacyByteCursor(data)
        let value = LegacyOfflineMessageRecipient(login: try cursor.readString16(), nickname: try cursor.readString16())
        guard !value.login.isEmpty, value.login.count <= 63, value.nickname.count <= 255 else {
            throw LegacyProtocolError.invalidRecord("invalid offline-message recipient")
        }
        try cursor.requireEnd()
        return value
    }
}

struct LegacyOfflineMessagePayload: Equatable {
    var senderLogin: Data
    var senderNickname: Data
    var message: Data

    func encoded() throws -> Data {
        guard senderLogin.count <= 255, senderNickname.count <= 255,
              !message.isEmpty, message.count <= LegacyOfflineMessage.maximumMessageLength else {
            throw LegacyProtocolError.invalidLength("offline message payload exceeds limits")
        }
        var data = try LegacyWire.string16(senderLogin)
        data.append(try LegacyWire.string16(senderNickname))
        data.append(try LegacyWire.string16(message))
        return data
    }

    static func decode(_ data: Data) throws -> LegacyOfflineMessagePayload {
        var cursor = LegacyByteCursor(data)
        let value = LegacyOfflineMessagePayload(senderLogin: try cursor.readString16(),
                                                senderNickname: try cursor.readString16(),
                                                message: try cursor.readString16())
        try cursor.requireEnd()
        return value
    }
}


struct LegacyNewsThreadSummary: Equatable {
    var threadID: UInt32
    var subject: Data
    var sender: Data
    var date: UInt32
    var replyCount: UInt32
    var latestDate: UInt32

    func encoded() throws -> Data {
        var data = LegacyWire.uint32BE(threadID)
        data.append(try LegacyWire.string16(subject))
        data.append(try LegacyWire.string16(sender))
        data.append(LegacyWire.uint32BE(date))
        data.append(LegacyWire.uint32BE(replyCount))
        data.append(LegacyWire.uint32BE(latestDate))
        return data
    }

    static func decode(from cursor: inout LegacyByteCursor) throws -> LegacyNewsThreadSummary {
        LegacyNewsThreadSummary(threadID: try cursor.readUInt32BE(),
                                subject: try cursor.readString16(),
                                sender: try cursor.readString16(),
                                date: try cursor.readUInt32BE(),
                                replyCount: try cursor.readUInt32BE(),
                                latestDate: try cursor.readUInt32BE())
    }
}

enum LegacyNewsReactionKind: UInt8, CaseIterable {
    case like = 1
    case love = 2
    case laugh = 3
    case celebrate = 4
    case wow = 5
    case sad = 6

    var emoji: String {
        switch self {
        case .like: return "👍"
        case .love: return "❤️"
        case .laugh: return "😂"
        case .celebrate: return "🎉"
        case .wow: return "😮"
        case .sad: return "😢"
        }
    }
}

struct LegacyNewsReactionSummary: Equatable {
    var kind: UInt8
    var count: UInt32
    var reactedByCurrentUser: Bool
    /// Modern-only display names for users who selected this reaction. This is transported
    /// in a separate optional TLV so the historical aggregate record remains compatible.
    var userNames: [String] = []

    func encoded() -> Data {
        var data = Data([kind])
        data.append(LegacyWire.uint32BE(count))
        data.append(reactedByCurrentUser ? 1 : 0)
        return data
    }

    static func decode(from cursor: inout LegacyByteCursor) throws -> LegacyNewsReactionSummary {
        let kind = try cursor.readUInt8()
        guard LegacyNewsReactionKind(rawValue: kind) != nil else {
            throw LegacyProtocolError.invalidRecord("unknown news reaction kind")
        }
        let count = try cursor.readUInt32BE()
        let mine = try cursor.readUInt8()
        guard mine <= 1 else { throw LegacyProtocolError.invalidRecord("invalid news reaction ownership flag") }
        return LegacyNewsReactionSummary(kind: kind, count: count, reactedByCurrentUser: mine == 1)
    }
}

struct LegacyNewsPostCapability: Equatable {
    static let editFlag: UInt8 = 1 << 0
    static let deleteFlag: UInt8 = 1 << 1
    static let deletedFlag: UInt8 = 1 << 2

    var articleID: UInt32
    var canEdit: Bool
    var canDelete: Bool
    var isDeleted: Bool

    func encoded() -> Data {
        var flags: UInt8 = 0
        if canEdit { flags |= Self.editFlag }
        if canDelete { flags |= Self.deleteFlag }
        if isDeleted { flags |= Self.deletedFlag }
        var data = LegacyWire.uint32BE(articleID)
        data.append(flags)
        return data
    }

    static func decode(from cursor: inout LegacyByteCursor) throws -> LegacyNewsPostCapability {
        let articleID = try cursor.readUInt32BE()
        let flags = try cursor.readUInt8()
        guard flags & ~(editFlag | deleteFlag | deletedFlag) == 0 else {
            throw LegacyProtocolError.invalidRecord("invalid news post capability flags")
        }
        return LegacyNewsPostCapability(articleID: articleID,
                                        canEdit: flags & editFlag != 0,
                                        canDelete: flags & deleteFlag != 0,
                                        isDeleted: flags & deletedFlag != 0)
    }
}

struct LegacyNewsThreadPostSummary: Equatable {
    var articleID: UInt32
    var parentArticleID: UInt32
    var sender: Data
    var date: UInt32
    var bodyLength: UInt32

    func encoded() throws -> Data {
        var data = LegacyWire.uint32BE(articleID)
        data.append(LegacyWire.uint32BE(parentArticleID))
        data.append(try LegacyWire.string16(sender))
        data.append(LegacyWire.uint32BE(date))
        data.append(LegacyWire.uint32BE(bodyLength))
        return data
    }

    static func decode(from cursor: inout LegacyByteCursor) throws -> LegacyNewsThreadPostSummary {
        LegacyNewsThreadPostSummary(articleID: try cursor.readUInt32BE(),
                                    parentArticleID: try cursor.readUInt32BE(),
                                    sender: try cursor.readString16(),
                                    date: try cursor.readUInt32BE(),
                                    bodyLength: try cursor.readUInt32BE())
    }
}

extension LegacyPackedRecords {
    static func encodeNewsThreadList(_ threads: [LegacyNewsThreadSummary]) throws -> Data {
        guard threads.count <= Int(UInt32.max) else { throw LegacyProtocolError.invalidLength("too many news threads") }
        var data = LegacyWire.uint32BE(UInt32(threads.count))
        for thread in threads { data.append(try thread.encoded()) }
        return data
    }

    static func decodeNewsThreadList(_ data: Data) throws -> [LegacyNewsThreadSummary] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        var result: [LegacyNewsThreadSummary] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try LegacyNewsThreadSummary.decode(from: &cursor)) }
        try cursor.requireEnd()
        return result
    }

    static func encodeNewsThreadPosts(_ posts: [LegacyNewsThreadPostSummary]) throws -> Data {
        guard posts.count <= Int(UInt32.max) else { throw LegacyProtocolError.invalidLength("too many news thread posts") }
        var data = LegacyWire.uint32BE(UInt32(posts.count))
        for post in posts { data.append(try post.encoded()) }
        return data
    }

    static func decodeNewsThreadPosts(_ data: Data) throws -> [LegacyNewsThreadPostSummary] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        var result: [LegacyNewsThreadPostSummary] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try LegacyNewsThreadPostSummary.decode(from: &cursor)) }
        try cursor.requireEnd()
        return result
    }

    static func encodeNewsPostCapabilities(_ values: [LegacyNewsPostCapability]) throws -> Data {
        guard values.count <= Int(UInt32.max) else { throw LegacyProtocolError.invalidLength("too many news post capabilities") }
        var data = LegacyWire.uint32BE(UInt32(values.count))
        for value in values { data.append(value.encoded()) }
        return data
    }

    static func decodeNewsPostCapabilities(_ data: Data) throws -> [LegacyNewsPostCapability] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        var result: [LegacyNewsPostCapability] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try LegacyNewsPostCapability.decode(from: &cursor)) }
        try cursor.requireEnd()
        return result
    }

    static func encodeNewsReactions(_ reactions: [LegacyNewsReactionSummary]) throws -> Data {
        guard reactions.count <= LegacyNewsReactionKind.allCases.count else {
            throw LegacyProtocolError.invalidLength("too many news reaction records")
        }
        var seen = Set<UInt8>()
        var data = Data([UInt8(reactions.count)])
        for reaction in reactions {
            guard LegacyNewsReactionKind(rawValue: reaction.kind) != nil, seen.insert(reaction.kind).inserted else {
                throw LegacyProtocolError.invalidRecord("invalid or duplicate news reaction kind")
            }
            data.append(reaction.encoded())
        }
        return data
    }

    static func encodeNewsReactionUsers(_ reactions: [LegacyNewsReactionSummary]) throws -> Data {
        let withUsers = reactions.filter { !$0.userNames.isEmpty }
        guard withUsers.count <= LegacyNewsReactionKind.allCases.count else {
            throw LegacyProtocolError.invalidLength("too many news reaction user groups")
        }
        var data = Data([UInt8(withUsers.count)])
        var seen = Set<UInt8>()
        for reaction in withUsers {
            guard LegacyNewsReactionKind(rawValue: reaction.kind) != nil, seen.insert(reaction.kind).inserted,
                  reaction.userNames.count <= Int(UInt16.max) else {
                throw LegacyProtocolError.invalidRecord("invalid news reaction user group")
            }
            data.append(reaction.kind)
            data.append(LegacyWire.uint16BE(UInt16(reaction.userNames.count)))
            for name in reaction.userNames {
                let utf8 = Data(name.utf8)
                guard utf8.count <= Int(UInt16.max) else {
                    throw LegacyProtocolError.invalidLength("news reaction user name too long")
                }
                data.append(try LegacyWire.string16(utf8))
            }
        }
        return data
    }

    static func decodeNewsReactionUsers(_ data: Data) throws -> [UInt8: [String]] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt8())
        guard count <= LegacyNewsReactionKind.allCases.count else {
            throw LegacyProtocolError.invalidLength("too many news reaction user groups")
        }
        var seen = Set<UInt8>(), result: [UInt8: [String]] = [:]
        for _ in 0..<count {
            let kind = try cursor.readUInt8()
            guard LegacyNewsReactionKind(rawValue: kind) != nil, seen.insert(kind).inserted else {
                throw LegacyProtocolError.invalidRecord("invalid or duplicate news reaction user kind")
            }
            let userCount = Int(try cursor.readUInt16BE())
            var names: [String] = []
            names.reserveCapacity(userCount)
            for _ in 0..<userCount {
                let raw = try cursor.readString16()
                guard let name = String(data: raw, encoding: .utf8) else {
                    throw LegacyProtocolError.invalidRecord("invalid UTF-8 news reaction user name")
                }
                names.append(name)
            }
            result[kind] = names
        }
        try cursor.requireEnd()
        return result
    }

    static func decodeNewsReactions(_ data: Data) throws -> [LegacyNewsReactionSummary] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt8())
        guard count <= LegacyNewsReactionKind.allCases.count else {
            throw LegacyProtocolError.invalidLength("too many news reaction records")
        }
        var seen = Set<UInt8>()
        var result: [LegacyNewsReactionSummary] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let value = try LegacyNewsReactionSummary.decode(from: &cursor)
            guard seen.insert(value.kind).inserted else {
                throw LegacyProtocolError.invalidRecord("duplicate news reaction kind")
            }
            result.append(value)
        }
        try cursor.requireEnd()
        return result
    }
}
