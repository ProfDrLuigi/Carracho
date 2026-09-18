import Foundation

struct LegacyTLV: Equatable {
    var type: UInt32
    var value: Data

    func encoded() throws -> Data {
        guard value.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("TLV value exceeds 65535 bytes")
        }
        var data = LegacyWire.uint32BE(type)
        data.append(LegacyWire.uint16BE(UInt16(value.count)))
        data.append(value)
        return data
    }
}

struct LegacyPacket: Equatable {
    static let headerSize = 18
    static let maximumClassicBodyLength = 0x20000

    var command: UInt32
    var transactionID: UInt32
    var reserved: UInt32 = 0
    var fields: [LegacyTLV] = []

    func plaintext(alignOddValuesToUInt16: Bool = false) throws -> Data {
        guard fields.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("too many TLV fields")
        }
        var bodyLength = 0
        for field in fields {
            guard field.value.count <= Int(UInt16.max) else {
                throw LegacyProtocolError.invalidLength("TLV value exceeds 65535 bytes")
            }
            bodyLength += 6 + field.value.count
            if alignOddValuesToUInt16 && field.value.count.isMultiple(of: 2) == false { bodyLength += 1 }
        }
        guard bodyLength <= Self.maximumClassicBodyLength else {
            throw LegacyProtocolError.invalidLength("packet body exceeds classic 0x20000-byte limit")
        }

        var data = LegacyWire.uint32BE(command)
        data.append(LegacyWire.uint32BE(transactionID))
        data.append(LegacyWire.uint32BE(UInt32(bodyLength)))
        data.append(LegacyWire.uint32BE(reserved))
        data.append(LegacyWire.uint16BE(UInt16(fields.count)))
        for field in fields {
            data.append(LegacyWire.uint32BE(field.type))
            data.append(LegacyWire.uint16BE(UInt16(field.value.count)))
            data.append(field.value)
            if alignOddValuesToUInt16 && field.value.count.isMultiple(of: 2) == false { data.append(0) }
        }
        return data
    }

    private static func parseFields(_ body: Data, fieldCount: Int,
                                    alignOddValuesToUInt16: Bool) throws -> [LegacyTLV] {
        var cursor = LegacyByteCursor(body)
        var fields: [LegacyTLV] = []
        fields.reserveCapacity(fieldCount)
        for _ in 0 ..< fieldCount {
            let type = try cursor.readUInt32BE()
            let length = Int(try cursor.readUInt16BE())
            fields.append(LegacyTLV(type: type, value: try cursor.readBytes(count: length)))
            if alignOddValuesToUInt16 && length.isMultiple(of: 2) == false {
                // Server 1.0b13 aligns server-setting values to a 16-bit boundary while the
                // TLV length still describes only the meaningful bytes. The pad byte itself
                // is unspecified and must not leak into the field value.
                _ = try cursor.readUInt8()
            }
        }
        try cursor.requireEnd()
        return fields
    }

    /// Parses one decrypted packet. Any bytes after `18 + bodyLength` are returned
    /// separately because the control transport carries zero padding outside the
    /// logical packet length.
    static func parsePlaintext(_ data: Data) throws -> (packet: LegacyPacket, trailing: Data) {
        guard data.count >= headerSize else {
            throw LegacyProtocolError.truncated(expected: headerSize, remaining: data.count)
        }
        var cursor = LegacyByteCursor(data)
        let command = try cursor.readUInt32BE()
        let transactionID = try cursor.readUInt32BE()
        let bodyLength = Int(try cursor.readUInt32BE())
        let reserved = try cursor.readUInt32BE()
        let fieldCount = Int(try cursor.readUInt16BE())

        guard bodyLength <= maximumClassicBodyLength else {
            throw LegacyProtocolError.invalidLength("declared packet body exceeds classic limit")
        }
        let body = try cursor.readBytes(count: bodyLength)
        let trailing = try cursor.readBytes(count: cursor.remaining)

        let fields: [LegacyTLV]
        do {
            fields = try parseFields(body, fieldCount: fieldCount, alignOddValuesToUInt16: false)
        } catch let standardError {
            // Classic Server 1.0b13 is peculiar only for command 0xc0: odd-sized setting
            // values are followed by one in-body alignment byte. Modern peers use ordinary
            // packed TLVs, so retry the aligned layout only when the canonical parse fails.
            guard command == LegacyCommand.serverSettingsReply else { throw standardError }
            fields = try parseFields(body, fieldCount: fieldCount, alignOddValuesToUInt16: true)
        }
        return (LegacyPacket(command: command, transactionID: transactionID, reserved: reserved, fields: fields), trailing)
    }
}

enum LegacyCommand {
    /// Classic Client 1.0b10r4 periodically sends command -1 with an otherwise empty
    /// packet from TClientThread::DoIdle. It is a transport keepalive/no-op, not user activity.
    static let idleKeepAlive: UInt32 = 0xffffffff
    static let error: UInt32 = 0x00000000
    static let challenge: UInt32 = 0x00000001
    static let login: UInt32 = 0x00000002
    static let loginSuccess: UInt32 = 0x00000003
    static let disconnectUser: UInt32 = 0x00000004
    static let banUser: UInt32 = 0x00000005
    static let privateMessage: UInt32 = 0x00000006
    static let userArrived: UInt32 = 0x00000007
    static let userDisconnected: UInt32 = 0x00000008
    static let channelDeclineInvitation: UInt32 = 0x0000000c
    static let channelUserMode: UInt32 = 0x0000000f
    static let directory: UInt32 = 0x00000009
    static let createFolder: UInt32 = 0x00000010
    static let deleteFile: UInt32 = 0x00000011
    static let fileInfo: UInt32 = 0x00000012
    static let setFileInfo: UInt32 = 0x00000013
    static let moveFile: UInt32 = 0x00000014
    static let emptyTrash: UInt32 = 0x00000015
    static let extendedOwnUserInfo: UInt32 = 0x00000016
    static let userInfo: UInt32 = 0x00000017
    static let userUpdate: UInt32 = 0x00000018
    /// Classic Advanced → Rebuild Index command. File-search queries themselves use transfer operation 9.
    static let rebuildSearchIndex: UInt32 = 0x00000040
    static let channelJoin: UInt32 = 0x00000080
    static let channelLeave: UInt32 = 0x00000081
    static let channelChat: UInt32 = 0x00000082
    static let channelSettings: UInt32 = 0x00000084
    static let channelList: UInt32 = 0x00000086
    static let channelUserJoined: UInt32 = 0x00000087
    static let channelUserLeft: UInt32 = 0x00000088
    static let channelInvite: UInt32 = 0x00000089
    static let newsgroupList: UInt32 = 0x000000a0
    static let newsgroupListReply: UInt32 = 0x000000a1
    static let articleRead: UInt32 = 0x000000a2
    static let newsgroupCreate: UInt32 = 0x000000a5
    static let newsgroupDelete: UInt32 = 0x000000a6
    static let newsgroupModify: UInt32 = 0x000000a7
    static let adminNewsgroupListReply: UInt32 = 0x000000a4
    static let adminNewsgroupList: UInt32 = 0x000000a8
    static let articleDelete: UInt32 = 0x000000a9
    static let newsgroupUpdate: UInt32 = 0x000000aa
    static let serverSettingsReply: UInt32 = 0x000000c0
    static let requestServerSettings: UInt32 = 0x000000c1
    static let setServerSettings: UInt32 = 0x000000c2
    static let serverInfo: UInt32 = 0x000000c3
    static let accountReply: UInt32 = 0x000000ca
    static let accountCreateOrModify: UInt32 = 0x000000cb
    static let getAccount: UInt32 = 0x000000cc
    static let accountList: UInt32 = 0x000000cd
    static let accountUpdate: UInt32 = 0x000000ce
    static let accountDelete: UInt32 = 0x000000cf
    static let broadcastMessage: UInt32 = 0x000000d0
    static let bannerChanged: UInt32 = 0x000000d1
    static let transferInfo: UInt32 = 0x000000e0
    static let flatNewsPost: UInt32 = 0x00fd0000
    static let flatNewsList: UInt32 = 0x00fd0001
    static let flatNewsDelete: UInt32 = 0x00fd0002
    static let flatNewsClear: UInt32 = 0x00fd0003
    static let taskComplete: UInt32 = 0x000000ff
    static let userPresenceState: UInt32 = 0xf0000000
    static let forceDisconnect: UInt32 = 0xf00000a0
    static let offlineMessageSend: UInt32 = 0xf0000100
    static let offlineMessageNotice: UInt32 = 0xf0000101
    static let offlineMessageFetch: UInt32 = 0xf0000102
    static let offlineMessageAcknowledge: UInt32 = 0xf0000103
    static let offlineMessageRecipients: UInt32 = 0xf0000104
    static let offlineMessagePreference: UInt32 = 0xf0000105
    static let forumThreadList: UInt32 = 0xf0000200
    static let forumThreadEntries: UInt32 = 0xf0000201
    static let forumArticleReactions: UInt32 = 0xf0000202
    static let forumArticleReactionSet: UInt32 = 0xf0000203
    static let forumArticleDelete: UInt32 = 0xf0000204
    /// Async modern-client notification that a News article's reactions changed.
    /// Field 1 = group name (MacRoman), field 2 = article ID (UInt32 BE).
    static let forumArticleReactionChanged: UInt32 = 0xf0000205
    /// Authenticated self-service password update. Field 1 contains the new
    /// password as MacRoman bytes (0...64 bytes). No account-management
    /// permission is required because the server only updates the session's
    /// own account.
    static let changeOwnPassword: UInt32 = 0xf0000300
    /// Carracho extension: paginated persistent server-log access for remote administration.
    static let serverLogRequest: UInt32 = 0xf0000400
    static let serverLogReply: UInt32 = 0xf0000401
    static let serverLogClear: UInt32 = 0xf0000402
    /// Carracho extension: persistent user-activity event log, independent of the server log.
    static let eventLogRequest: UInt32 = 0xf0000410
    static let eventLogReply: UInt32 = 0xf0000411
    static let eventLogClear: UInt32 = 0xf0000412
    /// Modern extension broadcast after an owner permanently deletes a media object.
    static let mediaDeleted: UInt32 = 0xf0000500
    /// Modern-only Finder-style file-label mutation. Classic peers never send or receive this command.
    static let fileLabelSet: UInt32 = 0xf0000600
    /// Modern-only asynchronous notification after a visible file label changed on the server.
    static let fileLabelChanged: UInt32 = 0xf0000601
    /// Modern-only remote administration for the local server Bot.
    static let botStatusRequest: UInt32 = 0xf0000700
    static let botStatusReply: UInt32 = 0xf0000701
    static let botSetEnabled: UInt32 = 0xf0000702
    static let botSetGreeting: UInt32 = 0xf0000703
    static let botSetCommandRules: UInt32 = 0xf0000704
    static let botSetRSSFeeds: UInt32 = 0xf0000705
    static let botTestRSSFeed: UInt32 = 0xf0000706
    static let botRSSFeedTestReply: UInt32 = 0xf0000707
    /// Modern-only administrator request to permanently remove a non-Public room.
    static let channelDelete: UInt32 = 0xf0000800
    /// Modern-only asynchronous notification that a room was deleted by an administrator.
    static let channelDeleted: UInt32 = 0xf0000801
}

enum LegacyBotAdminField {
    static let desiredEnabled: UInt32 = 1
    static let connected: UInt32 = 2
    static let login: UInt32 = 3
    static let name: UInt32 = 4
    static let lastError: UInt32 = 5
    static let greetNewUsers: UInt32 = 6
    static let greetingTemplate: UInt32 = 7
    static let commandRules: UInt32 = 8
    static let rssFeeds: UInt32 = 9
    static let rssPreview: UInt32 = 10
}

struct LegacyBotRSSFeed: Equatable, Codable, Identifiable {
    static let maximumCount = 16
    static let maximumNameBytes = 96
    static let maximumURLBytes = 2048
    static let minimumPollMinutes = 5
    static let maximumPollMinutes = 1440
    static let minimumSummaryCharacters = 80
    static let maximumSummaryCharacters = 1000

    var id: UUID
    var enabled: Bool
    var name: String
    var url: String
    var channelID: UInt32
    var pollIntervalMinutes: Int
    var includeImage: Bool
    var summaryCharacters: Int

    func validated() throws -> LegacyBotRSSFeed {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf8.count <= Self.maximumNameBytes,
              !cleanName.contains("\n"), !cleanName.contains("\r"),
              !cleanURL.isEmpty, cleanURL.utf8.count <= Self.maximumURLBytes,
              !cleanURL.contains("\n"), !cleanURL.contains("\r"),
              let components = URLComponents(string: cleanURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil, components.user == nil, components.password == nil,
              channelID > 0,
              (Self.minimumPollMinutes...Self.maximumPollMinutes).contains(pollIntervalMinutes),
              (Self.minimumSummaryCharacters...Self.maximumSummaryCharacters).contains(summaryCharacters) else {
            throw LegacyProtocolError.invalidRecord("invalid Bot RSS feed")
        }
        return LegacyBotRSSFeed(id: id, enabled: enabled, name: cleanName, url: cleanURL, channelID: channelID,
                                pollIntervalMinutes: pollIntervalMinutes, includeImage: includeImage,
                                summaryCharacters: summaryCharacters)
    }

    static func encodeList(_ feeds: [LegacyBotRSSFeed]) throws -> Data {
        guard feeds.count <= maximumCount else { throw LegacyProtocolError.invalidLength("too many Bot RSS feeds") }
        var data = LegacyWire.uint16BE(UInt16(feeds.count))
        for feed in feeds {
            let feed = try feed.validated()
            data.append(feed.enabled ? 1 : 0)
            data.append(feed.includeImage ? 1 : 0)
            data.append(LegacyWire.uint32BE(feed.channelID))
            data.append(LegacyWire.uint16BE(UInt16(feed.pollIntervalMinutes)))
            data.append(LegacyWire.uint16BE(UInt16(feed.summaryCharacters)))
            data.append(try LegacyWire.string16(Data(feed.id.uuidString.lowercased().utf8)))
            data.append(try LegacyWire.string16(Data(feed.name.utf8)))
            data.append(try LegacyWire.string16(Data(feed.url.utf8)))
        }
        return data
    }

    static func decodeList(_ data: Data) throws -> [LegacyBotRSSFeed] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt16BE())
        guard count <= maximumCount else { throw LegacyProtocolError.invalidRecord("too many Bot RSS feeds") }
        var feeds: [LegacyBotRSSFeed] = []
        feeds.reserveCapacity(count)
        for _ in 0..<count {
            let enabled = try cursor.readUInt8(), image = try cursor.readUInt8()
            guard enabled <= 1, image <= 1 else { throw LegacyProtocolError.invalidRecord("invalid Bot RSS flags") }
            let channelID = try cursor.readUInt32BE()
            let poll = Int(try cursor.readUInt16BE())
            let summary = Int(try cursor.readUInt16BE())
            let idData = try cursor.readString16(), nameData = try cursor.readString16(), urlData = try cursor.readString16()
            guard let idString = String(data: idData, encoding: .utf8), let id = UUID(uuidString: idString),
                  let name = String(data: nameData, encoding: .utf8), let url = String(data: urlData, encoding: .utf8) else {
                throw LegacyProtocolError.invalidRecord("invalid Bot RSS text")
            }
            feeds.append(try LegacyBotRSSFeed(id: id, enabled: enabled == 1, name: name, url: url, channelID: channelID,
                                               pollIntervalMinutes: poll, includeImage: image == 1, summaryCharacters: summary).validated())
        }
        try cursor.requireEnd()
        return feeds
    }
}

struct LegacyBotRSSPreview: Equatable {
    var title: String
    var summary: String
    var link: String
    var imageURL: String?

    func encode() throws -> Data {
        var data = Data()
        for value in [title, summary, link, imageURL ?? ""] { data.append(try LegacyWire.string16(Data(value.utf8))) }
        return data
    }

    static func decode(_ data: Data) throws -> LegacyBotRSSPreview {
        var cursor = LegacyByteCursor(data)
        var values: [String] = []
        for _ in 0..<4 {
            let raw = try cursor.readString16()
            guard let text = String(data: raw, encoding: .utf8) else { throw LegacyProtocolError.invalidRecord("invalid Bot RSS preview") }
            values.append(text)
        }
        try cursor.requireEnd()
        return LegacyBotRSSPreview(title: values[0], summary: values[1], link: values[2], imageURL: values[3].isEmpty ? nil : values[3])
    }
}

struct LegacyBotCommandRule: Equatable, Codable {
    static let maximumCount = 64
    static let maximumCommandBytes = 128
    static let maximumResponseBytes = 512

    var enabled: Bool
    var command: String
    var response: String

    func validated() throws -> LegacyBotCommandRule {
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommand.isEmpty, !normalizedResponse.isEmpty,
              normalizedCommand.utf8.count <= Self.maximumCommandBytes,
              normalizedResponse.utf8.count <= Self.maximumResponseBytes,
              !normalizedCommand.contains("\n"), !normalizedCommand.contains("\r"),
              !normalizedResponse.contains("\n"), !normalizedResponse.contains("\r") else {
            throw LegacyProtocolError.invalidRecord("invalid Bot command rule")
        }
        return LegacyBotCommandRule(enabled: enabled, command: normalizedCommand, response: normalizedResponse)
    }

    static func encodeList(_ rules: [LegacyBotCommandRule]) throws -> Data {
        guard rules.count <= maximumCount else {
            throw LegacyProtocolError.invalidLength("too many Bot command rules")
        }
        var data = LegacyWire.uint16BE(UInt16(rules.count))
        for rule in rules {
            let rule = try rule.validated()
            let command = Data(rule.command.utf8)
            let response = Data(rule.response.utf8)
            data.append(rule.enabled ? 1 : 0)
            data.append(try LegacyWire.string16(command))
            data.append(try LegacyWire.string16(response))
        }
        return data
    }

    static func decodeList(_ data: Data) throws -> [LegacyBotCommandRule] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt16BE())
        guard count <= maximumCount else { throw LegacyProtocolError.invalidRecord("too many Bot command rules") }
        var rules: [LegacyBotCommandRule] = []
        rules.reserveCapacity(count)
        for _ in 0..<count {
            let rawEnabled = try cursor.readUInt8()
            guard rawEnabled <= 1 else { throw LegacyProtocolError.invalidRecord("invalid Bot command enabled flag") }
            let commandData = try cursor.readString16()
            let responseData = try cursor.readString16()
            guard commandData.count <= maximumCommandBytes, responseData.count <= maximumResponseBytes,
                  let command = String(data: commandData, encoding: .utf8),
                  let response = String(data: responseData, encoding: .utf8) else {
                throw LegacyProtocolError.invalidRecord("invalid Bot command text")
            }
            rules.append(try LegacyBotCommandRule(enabled: rawEnabled == 1, command: command, response: response).validated())
        }
        try cursor.requireEnd()
        return rules
    }
}

struct LegacyBotAdminStatus: Equatable {
    static let defaultGreetingTemplate = "Welcome, {name}! Nice to have you here."

    var desiredEnabled: Bool
    var connected: Bool
    var login: String
    var name: String
    var lastError: String?
    var greetingSupported: Bool
    var greetNewUsers: Bool
    var greetingTemplate: String
    var commandRulesSupported: Bool
    var commandRules: [LegacyBotCommandRule]
    var rssFeedsSupported: Bool
    var rssFeeds: [LegacyBotRSSFeed]
}

enum LegacyUserInfoField {
    static let maximumPictureLength = Int(UInt16.max)
    static let nickname: UInt32 = 4
    static let name: UInt32 = 0xb0
    static let email: UInt32 = 0xb1
    static let aboutMe: UInt32 = 0xb2
    static let picture: UInt32 = 0xb4
    static let ipAddress: UInt32 = 0x84
    static let loginTime: UInt32 = 0x85
    static let taskList: UInt32 = 0x86
    static let idleTime: UInt32 = 0x87
    static let loginName: UInt32 = 0x88
    /// Carracho extension: public per-session status line (MacRoman, max 255 bytes).
    static let statusMessage: UInt32 = 0xf0000002
    /// Carracho extension: 24-bit RGB color inherited from the account permission group.
    static let groupColorRGB: UInt32 = 0xf0000003
    /// Modern-client-only marker: one byte, 1 when this user session uses Classic/legacy transport.
    static let legacyTransport: UInt32 = 0xf0000004
    /// Modern-only own-session update: current 64-bit permission words after a live account/group change.
    static let permissionWords: UInt32 = 0xf0000005
}

enum LegacyClientMetadataField {
    /// Modern login/user-info extensions. Values are UTF-8 and intentionally optional so
    /// Classic peers and older Carracho builds can ignore them without changing the base protocol.
    static let maximumLength = 128
    static let operatingSystem: UInt32 = 0xf1000000
    static let cpuArchitecture: UInt32 = 0xf1000001
    static let clientVersion: UInt32 = 0xf1000002
    static let clientBuild: UInt32 = 0xf1000003
}

enum LegacyUserTransportCapability {
    /// Modern login-success extension containing a packed sequence of UInt32 legacy user IDs.
    static let loginFieldType: UInt32 = 0xf0000202

    static func encodeLegacyUserIDs(_ ids: [UInt32]) -> Data {
        ids.reduce(into: Data()) { $0.append(LegacyWire.uint32BE($1)) }
    }

    static func decodeLegacyUserIDs(_ data: Data) throws -> Set<UInt32> {
        guard data.count % 4 == 0 else {
            throw LegacyProtocolError.invalidRecord("legacy-user transport list is not UInt32-aligned")
        }
        var cursor = LegacyByteCursor(data)
        var ids = Set<UInt32>()
        while cursor.remaining > 0 { ids.insert(try cursor.readUInt32BE()) }
        return ids
    }
}

/// Exact 12-byte value of login-success TLV type 1.
struct LegacyLoginSessionInfo: Equatable {
    static let wireSize = 12

    var userID: UInt32
    /// First 32-bit word of the classic 64-bit account permission bitset, in wire order.
    var permissionWord0: UInt32
    /// Second 32-bit word of the classic 64-bit account permission bitset, in wire order.
    var permissionWord1: UInt32

    func encoded() -> Data {
        var data = LegacyWire.uint32BE(userID)
        data.append(LegacyWire.uint32BE(permissionWord0))
        data.append(LegacyWire.uint32BE(permissionWord1))
        return data
    }

    static func decode(_ data: Data) throws -> LegacyLoginSessionInfo {
        guard data.count == wireSize else {
            throw LegacyProtocolError.invalidLength("login session info must be exactly 12 bytes")
        }
        var cursor = LegacyByteCursor(data)
        let value = LegacyLoginSessionInfo(userID: try cursor.readUInt32BE(),
                                           permissionWord0: try cursor.readUInt32BE(),
                                           permissionWord1: try cursor.readUInt32BE())
        try cursor.requireEnd()
        return value
    }
}


enum LegacyServerInfoField {
    static let serverName: UInt32 = 2
    static let serverLocation: UInt32 = 6
    static let systemOperator: UInt32 = 7
    static let description: UInt32 = 8
    /// Carracho extension used by the modern clients for the compact server-information card.
    static let softwareVersion: UInt32 = 0xf0000100
    /// Server uptime in Classic 60 Hz ticks, matching server setting 0x36.
    static let uptimeTicks: UInt32 = 0xf0000101
    /// Public transfer-capacity snapshot. These fields deliberately contain counts/limits only,
    /// never filenames or other users' identities, so every authenticated client may schedule
    /// its own queue without receiving administrator-only transfer-monitor data.
    static let maxSimultaneousFileTransfers: UInt32 = 0xf0000102
    static let activeFileTransfers: UInt32 = 0xf0000103
    static let maxFileTransfersPerUser: UInt32 = 0xf0000104
    static let activeFileTransfersForUser: UInt32 = 0xf0000105
}


enum LegacyPresenceStateField {
    static let userID: UInt32 = 1
    static let state: UInt32 = 0xf0000001
}

enum LegacyPresenceState {
    static let awake: UInt8 = 0
    static let sleeping: UInt8 = 1
}


enum LegacyChannelField {
    static let channelID: UInt32 = 0
    static let name: UInt32 = 1
    static let message: UInt32 = 2
    static let chatAttribute: UInt32 = 3
    static let topic: UInt32 = 4
    static let members: UInt32 = 5
    static let settings: UInt32 = 6
    static let userID: UInt32 = 7
    static let userMode: UInt32 = 8
    static let password: UInt32 = 9
}
