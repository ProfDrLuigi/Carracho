import Foundation

enum LegacyServerSettingField {
    static let agreement: UInt32 = 0x04
    static let serverName: UInt32 = 0x05
    static let location: UInt32 = 0x06
    static let serverOperator: UInt32 = 0x07
    static let description: UInt32 = 0x08
    static let controlPort: UInt32 = 0x09
    static let newsExpireTime: UInt32 = 0x0c

    static let maxSimultaneousFileTransfers: UInt32 = 0x20
    static let maxFileTransfersPerUser: UInt32 = 0x21
    static let maxConnections: UInt32 = 0x22
    static let maxConnectionsPerIP: UInt32 = 0x23

    static let statisticHits: UInt32 = 0x24
    static let statisticConnectionPeak: UInt32 = 0x25
    static let statisticIncorrectLogins: UInt32 = 0x26
    static let statisticAdminsConnected: UInt32 = 0x27
    static let statisticAccountHoldersConnected: UInt32 = 0x28
    static let statisticGuestsConnected: UInt32 = 0x29
    static let statisticDownloadsInProgress: UInt32 = 0x2a
    static let statisticTotalDownloads: UInt32 = 0x2b
    static let statisticUploadsInProgress: UInt32 = 0x2c
    static let statisticTotalUploads: UInt32 = 0x2d
    static let statisticCurrentlyConnected: UInt32 = 0x2e

    static let allowDenyIPList: UInt32 = 0x2f
    static let trackerList: UInt32 = 0x30
    static let trackerRegistrationFlags: UInt32 = 0x32
    static let trackerDescription: UInt32 = 0x33
    static let statisticTotalMessages: UInt32 = 0x34
    static let maxFolderDownloadDepth: UInt32 = 0x35
    static let uptimeTicks: UInt32 = 0x36
    /// Carracho extension: glob patterns excluded from the server file-search index.
    static let searchIndexExclusions: UInt32 = 0xf0000003
    /// Modern Carracho extension: defaults for the three fixed Classic-compatible account groups.
    static let accountGroups: UInt32 = 0xf0000004
    /// Carracho extension: optional UTF-8 filesystem root used by Classic/legacy sessions only.
    static let legacyFilesRoot: UInt32 = 0xf0000005
    /// Carracho extension: one-byte authentication mode (0 = Legacy compatible, 1 = Modern only).
    static let authenticationMode: UInt32 = 0xf0000006
    /// Modern Carracho extension: UInt32 hours between automatic full search-index rebuilds; 0 disables.
    static let searchIndexRebuildIntervalHours: UInt32 = 0xf0000007

    static func encodeAuthenticationMode(modernOnly: Bool) -> Data { Data([modernOnly ? 1 : 0]) }

    static func decodeAuthenticationMode(_ data: Data) throws -> Bool {
        guard data.count == 1, let value = data.first, value <= 1 else {
            throw LegacyProtocolError.invalidRecord("authentication mode must be one byte (0 or 1)")
        }
        return value == 1
    }

    static func packNewsExpireTime(hour: UInt8, minute: UInt8) throws -> UInt16 {
        guard hour < 24, minute < 60 else {
            throw LegacyProtocolError.invalidRecord("news expiration time is outside 00:00...23:59")
        }
        return (UInt16(hour) << 8) | UInt16(minute)
    }

    static func unpackNewsExpireTime(_ value: UInt16) -> (hour: UInt8, minute: UInt8) {
        (UInt8(value >> 8), UInt8(value & 0xff))
    }
}

struct LegacyIPRestriction: Equatable {
    static let wireSize = 10

    /// IPv4/network bytes in network byte order, exactly as shown by the classic UI.
    var network: Data
    var mask: Data
    /// Classic record byte 8: 0 = allow, nonzero = deny.
    var deny: Bool
    /// Classic record byte 9. Preserved for byte-perfect roundtrips; no use observed.
    var reserved: UInt8 = 0

    func encoded() throws -> Data {
        guard network.count == 4, mask.count == 4 else {
            throw LegacyProtocolError.invalidLength("IP restriction network and mask must be exactly 4 bytes")
        }
        var data = network
        data.append(mask)
        data.append(deny ? 1 : 0)
        data.append(reserved)
        return data
    }

    static func decode(_ data: Data) throws -> LegacyIPRestriction {
        guard data.count == wireSize else {
            throw LegacyProtocolError.invalidLength("IP restriction must be exactly 10 bytes")
        }
        var cursor = LegacyByteCursor(data)
        return LegacyIPRestriction(network: try cursor.readBytes(count: 4),
                                   mask: try cursor.readBytes(count: 4),
                                   deny: try cursor.readUInt8() != 0,
                                   reserved: try cursor.readUInt8())
    }

    func matches(address: Data) throws -> Bool {
        guard address.count == 4, network.count == 4, mask.count == 4 else {
            throw LegacyProtocolError.invalidLength("IPv4 values must be exactly 4 bytes")
        }
        let a = Array(address)
        let n = Array(network)
        let m = Array(mask)
        for i in 0..<4 where (a[i] & m[i]) != n[i] { return false }
        return true
    }
}

struct LegacyTrackerSettingRecord: Equatable {
    /// Editable as “Name” in Client 1.0b10r4; maximum 32 bytes.
    var name: Data
    /// Editable as “Address” in Client 1.0b10r4; maximum 64 bytes.
    var address: Data
    /// Reserved compatibility String16. Client 1.0b10r4 always writes it empty.
    var reservedString: Data = Data()
    /// Reserved compatibility UInt32. Client 1.0b10r4 always writes zero.
    var reservedValue: UInt32 = 0

    func encoded() throws -> Data {
        guard name.count <= 32 else {
            throw LegacyProtocolError.invalidLength("tracker name exceeds classic 32-byte limit")
        }
        guard address.count <= 64 else {
            throw LegacyProtocolError.invalidLength("tracker address exceeds classic 64-byte limit")
        }
        guard reservedString.count <= 16 else {
            throw LegacyProtocolError.invalidLength("tracker reserved string exceeds classic 16-byte limit")
        }
        var data = try LegacyWire.string16(name)
        data.append(try LegacyWire.string16(address))
        data.append(try LegacyWire.string16(reservedString))
        data.append(LegacyWire.uint32BE(reservedValue))
        return data
    }

    static func decode(from cursor: inout LegacyByteCursor) throws -> LegacyTrackerSettingRecord {
        let name = try cursor.readString16()
        let address = try cursor.readString16()
        let reservedString = try cursor.readString16()
        guard name.count <= 32, address.count <= 64, reservedString.count <= 16 else {
            throw LegacyProtocolError.invalidLength("tracker record exceeds classic string limits")
        }
        return LegacyTrackerSettingRecord(name: name,
                                          address: address,
                                          reservedString: reservedString,
                                          reservedValue: try cursor.readUInt32BE())
    }
}

struct LegacyAccountGroupRecord: Equatable {
    var id: UUID
    var name: String
    var colorRGB: UInt32
    /// Compatibility class: 0 guest, 1 account holder, 2 administrator.
    var legacyMode: UInt8
    var permissionBytes: Data
    /// Informational membership snapshot used by modern account-administration clients.
    /// Servers ignore this list when groups are written; account assignment stays account-owned.
    var memberLogins: [String] = []
    /// Empty means the normal server Files root ("Allgemein"). Non-empty paths are relative.
    var filesRootPath: String = ""
    var filesRootName: String = "Allgemein"

    func encoded(includeFilesRoot: Bool = true) throws -> Data {
        let nameData = Data(name.utf8)
        guard !nameData.isEmpty, nameData.count <= 64 else {
            throw LegacyProtocolError.invalidLength("account-group name must be 1...64 UTF-8 bytes")
        }
        guard colorRGB <= 0x00ff_ffff, legacyMode <= 2, permissionBytes.count == 8 else {
            throw LegacyProtocolError.invalidRecord("invalid account-group record")
        }
        var data = Data(id.uuidString.utf8)
        data = try LegacyWire.string16(data)
        data.append(try LegacyWire.string16(nameData))
        data.append(LegacyWire.uint32BE(colorRGB))
        data.append(legacyMode)
        data.append(permissionBytes)
        guard memberLogins.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("account-group membership list is too large")
        }
        data.append(LegacyWire.uint16BE(UInt16(memberLogins.count)))
        for login in memberLogins {
            let raw = Data(login.utf8)
            guard !raw.isEmpty, raw.count <= 63 else {
                throw LegacyProtocolError.invalidLength("account-group member login exceeds 63 UTF-8 bytes")
            }
            data.append(try LegacyWire.string16(raw))
        }
        if includeFilesRoot {
            let rootPath = Data(filesRootPath.utf8)
            let rootName = Data(filesRootName.utf8)
            guard rootPath.count <= 1024, !rootPath.contains(0),
                  !rootName.isEmpty, rootName.count <= 64, !rootName.contains(0) else {
                throw LegacyProtocolError.invalidLength("account-group Files root exceeds wire limits")
            }
            data.append(try LegacyWire.string16(rootPath))
            data.append(try LegacyWire.string16(rootName))
        }
        return data
    }

    static func decode(from cursor: inout LegacyByteCursor, includesFilesRoot: Bool = true) throws -> LegacyAccountGroupRecord {
        let idData = try cursor.readString16()
        let nameData = try cursor.readString16()
        guard let idString = String(data: idData, encoding: .utf8), let id = UUID(uuidString: idString),
              let name = String(data: nameData, encoding: .utf8), !name.isEmpty, nameData.count <= 64 else {
            throw LegacyProtocolError.invalidRecord("invalid account-group identity/name")
        }
        let color = try cursor.readUInt32BE()
        let mode = try cursor.readUInt8()
        let permissions = try cursor.readBytes(count: 8)
        let memberCount = Int(try cursor.readUInt16BE())
        var members: [String] = []
        members.reserveCapacity(memberCount)
        for _ in 0..<memberCount {
            let raw = try cursor.readString16()
            guard !raw.isEmpty, raw.count <= 63, let login = String(data: raw, encoding: .utf8) else {
                throw LegacyProtocolError.invalidRecord("invalid account-group member login")
            }
            members.append(login)
        }
        guard color <= 0x00ff_ffff, mode <= 2 else {
            throw LegacyProtocolError.invalidRecord("invalid account-group color/mode")
        }
        let rootPath: String
        let rootName: String
        if includesFilesRoot {
            let rawPath = try cursor.readString16()
            let rawName = try cursor.readString16()
            guard rawPath.count <= 1024, rawName.count <= 64, !rawName.isEmpty,
                  let decodedPath = String(data: rawPath, encoding: .utf8),
                  let decodedName = String(data: rawName, encoding: .utf8),
                  !rawPath.contains(0), !rawName.contains(0) else {
                throw LegacyProtocolError.invalidRecord("invalid account-group Files root")
            }
            rootPath = decodedPath
            rootName = decodedName
        } else {
            rootPath = ""
            rootName = "Allgemein"
        }
        return LegacyAccountGroupRecord(id: id, name: name, colorRGB: color, legacyMode: mode,
                                        permissionBytes: permissions, memberLogins: members,
                                        filesRootPath: rootPath, filesRootName: rootName)
    }
}

extension LegacyServerSettingField {
    static func encodeIPRestrictions(_ rules: [LegacyIPRestriction]) throws -> Data {
        guard rules.count <= Int(UInt32.max) else {
            throw LegacyProtocolError.invalidLength("too many IP restrictions")
        }
        var data = LegacyWire.uint32BE(UInt32(rules.count))
        for rule in rules { data.append(try rule.encoded()) }
        return data
    }

    static func decodeIPRestrictions(_ data: Data) throws -> [LegacyIPRestriction] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        guard cursor.remaining == count * LegacyIPRestriction.wireSize else {
            throw LegacyProtocolError.invalidLength("IP restriction list size/count mismatch")
        }
        var result: [LegacyIPRestriction] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try LegacyIPRestriction.decode(
                cursor.readBytes(count: LegacyIPRestriction.wireSize)
            ))
        }
        try cursor.requireEnd()
        return result
    }

    /// Matches UServerUtils::CanAcceptIP: first match wins; no match means allow.
    static func ipRestrictionsAllow(_ rules: [LegacyIPRestriction], address: Data) throws -> Bool {
        for rule in rules where try rule.matches(address: address) {
            return !rule.deny
        }
        return true
    }

    static func encodeTrackerSettings(_ trackers: [LegacyTrackerSettingRecord]) throws -> Data {
        guard trackers.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("too many tracker records")
        }
        var data = LegacyWire.uint16BE(UInt16(trackers.count))
        for tracker in trackers { data.append(try tracker.encoded()) }
        return data
    }

    static func decodeTrackerSettings(_ data: Data) throws -> [LegacyTrackerSettingRecord] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt16BE())
        var result: [LegacyTrackerSettingRecord] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try LegacyTrackerSettingRecord.decode(from: &cursor)) }
        try cursor.requireEnd()
        return result
    }
    static func encodeSearchIndexExclusions(_ patterns: [String]) throws -> Data {
        guard patterns.count <= 256 else {
            throw LegacyProtocolError.invalidLength("search-index exclusion list exceeds 256 patterns")
        }
        var data = LegacyWire.uint16BE(UInt16(patterns.count))
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"),
                  let raw = trimmed.data(using: .macOSRoman), raw.count <= 255 else {
                throw LegacyProtocolError.invalidRecord("search-index exclusion patterns must be non-empty MacRoman filenames/globs of at most 255 bytes and cannot contain path separators")
            }
            data.append(try LegacyWire.string16(raw))
        }
        guard data.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("search-index exclusion list exceeds the server-settings field size")
        }
        return data
    }

    static func decodeSearchIndexExclusions(_ data: Data) throws -> [String] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt16BE())
        guard count <= 256 else {
            throw LegacyProtocolError.invalidLength("search-index exclusion list exceeds 256 patterns")
        }
        var patterns: [String] = []
        patterns.reserveCapacity(count)
        for _ in 0..<count {
            let raw = try cursor.readString16()
            guard !raw.isEmpty, raw.count <= 255, let pattern = String(data: raw, encoding: .macOSRoman),
                  !pattern.contains("/"), !pattern.contains("\\") else {
                throw LegacyProtocolError.invalidRecord("invalid search-index exclusion pattern")
            }
            patterns.append(pattern)
        }
        try cursor.requireEnd()
        return patterns
    }
    static func encodeAccountGroups(_ groups: [LegacyAccountGroupRecord]) throws -> Data {
        guard groups.count <= 256 else {
            throw LegacyProtocolError.invalidLength("account-group list exceeds 256 groups")
        }
        // High bit marks the extended Carracho account-group format. Old unmarked payloads remain
        // readable and default to the global Files root. The low 15 bits keep the group count.
        var data = LegacyWire.uint16BE(UInt16(groups.count) | 0x8000)
        for group in groups { data.append(try group.encoded(includeFilesRoot: true)) }
        guard data.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("account-group list exceeds the server-settings field size")
        }
        return data
    }

    static func decodeAccountGroups(_ data: Data) throws -> [LegacyAccountGroupRecord] {
        var cursor = LegacyByteCursor(data)
        let rawCount = try cursor.readUInt16BE()
        let extended = (rawCount & 0x8000) != 0
        let count = Int(rawCount & 0x7fff)
        guard count <= 256 else { throw LegacyProtocolError.invalidLength("account-group list exceeds 256 groups") }
        var groups: [LegacyAccountGroupRecord] = []
        groups.reserveCapacity(count)
        for _ in 0..<count { groups.append(try LegacyAccountGroupRecord.decode(from: &cursor, includesFilesRoot: extended)) }
        try cursor.requireEnd()
        return groups
    }

}
