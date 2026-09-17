import Foundation

enum LegacyTrackerProtocol {
    static let port: UInt16 = 6702
    static let queryMagic = Data([0x43, 0x54, 0x51, 0x01]) // CTQ\x01
    static let listQuery = Data([0x51, 0x4c, 0x49])          // QLI
    static let registrationMagic = Data([0x43, 0x54, 0x54, 0x01]) // CTT\x01

    static let registeredFlag: UInt32 = 0x0080_0000
    static let privateFlag: UInt32 = 0x0040_0000

    /// Classic Carracho Server `MENU` 134 ("Server Speed"). The protocol stores the
    /// selected menu-item number in the high byte of the tracker advertisement word.
    /// Separator items therefore leave intentional gaps in the numeric codes.
    static let bandwidthOptions: [(code: UInt8, title: String)] = [
        (1, "28.8K - Modem"),
        (2, "33.6K - Modem"),
        (3, "56K - Modem"),
        (5, "56K - ISDN"),
        (6, "64K - ISDN"),
        (7, "112K - 2 x ISDN"),
        (8, "128K - 2 x ISDN"),
        (10, "T1"),
        (11, "T3"),
        (13, "Other Speed"),
    ]

    static func bandwidthTitle(for code: UInt8) -> String? {
        bandwidthOptions.first(where: { $0.code == code })?.title
    }

    static func advertisementFlags(preserving flags: UInt32,
                                   bandwidthCode: UInt8,
                                   registered: Bool,
                                   isPrivate: Bool? = nil) -> UInt32 {
        var value = (flags & 0x00ff_ffff) | (UInt32(bandwidthCode) << 24)
        if registered { value |= registeredFlag }
        else { value &= ~registeredFlag }
        if let isPrivate {
            if isPrivate { value |= privateFlag }
            else { value &= ~privateFlag }
        }
        return value
    }

    static func listRequest() -> Data {
        var data = queryMagic
        data.append(listQuery)
        return data
    }

    static func string8(_ value: Data) throws -> Data {
        guard value.count <= Int(UInt8.max) else {
            throw LegacyProtocolError.invalidLength("Tracker String8 exceeds 255 bytes")
        }
        var data = Data([UInt8(value.count)])
        data.append(value)
        return data
    }

    static func readString8(from cursor: inout LegacyByteCursor) throws -> Data {
        try cursor.readBytes(count: Int(cursor.readUInt8()))
    }

    static func encodeListResponse(_ entries: [LegacyTrackerServerEntry]) throws -> Data {
        guard entries.count <= Int(UInt32.max) else {
            throw LegacyProtocolError.invalidLength("too many tracker server entries")
        }
        var data = LegacyWire.uint32BE(UInt32(entries.count))
        for entry in entries { data.append(try entry.encodedListRecord()) }
        return data
    }

    static func decodeListResponse(_ data: Data) throws -> [LegacyTrackerServerEntry] {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt32BE())
        var entries: [LegacyTrackerServerEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let recordLength = Int(try cursor.readUInt8())
            entries.append(try LegacyTrackerServerEntry.decodePayload(
                cursor.readBytes(count: recordLength)
            ))
        }
        try cursor.requireEnd()
        return entries
    }
}

struct LegacyTrackerServerEntry: Equatable {
    var ipv4: Data
    var port: UInt16
    var serverName: Data
    var description: Data
    var users: UInt16
    /// Same 32-bit advertisement word supplied by server setting 0x32.
    var flags: UInt32

    var isPrivate: Bool { (flags & LegacyTrackerProtocol.privateFlag) != 0 }
    var bandwidthCode: UInt8 { UInt8((flags >> 24) & 0xff) }

    func payload() throws -> Data {
        guard ipv4.count == 4 else {
            throw LegacyProtocolError.invalidLength("tracker IPv4 must be exactly 4 bytes")
        }
        var data = ipv4
        data.append(LegacyWire.uint16BE(port))
        data.append(try LegacyTrackerProtocol.string8(serverName))
        data.append(try LegacyTrackerProtocol.string8(description))
        data.append(LegacyWire.uint16BE(users))
        data.append(LegacyWire.uint32BE(flags))
        return data
    }

    func encodedListRecord() throws -> Data {
        let payload = try payload()
        guard payload.count <= Int(UInt8.max) else {
            throw LegacyProtocolError.invalidLength("tracker list record exceeds one-byte record length")
        }
        var data = Data([UInt8(payload.count)])
        data.append(payload)
        return data
    }

    static func decodePayload(_ data: Data) throws -> LegacyTrackerServerEntry {
        var cursor = LegacyByteCursor(data)
        let ipv4 = try cursor.readBytes(count: 4)
        let port = try cursor.readUInt16BE()
        let name = try LegacyTrackerProtocol.readString8(from: &cursor)
        let description = try LegacyTrackerProtocol.readString8(from: &cursor)
        let users = try cursor.readUInt16BE()
        let flags = try cursor.readUInt32BE()
        try cursor.requireEnd()
        return LegacyTrackerServerEntry(ipv4: ipv4, port: port, serverName: name,
                                        description: description, users: users, flags: flags)
    }
}

struct LegacyTrackerRegistration: Equatable {
    var ipv4: Data
    var port: UInt16
    var serverName: Data
    var description: Data
    var users: UInt16
    var flags: UInt32

    func encoded() throws -> Data {
        guard ipv4.count == 4 else {
            throw LegacyProtocolError.invalidLength("tracker registration IPv4 must be exactly 4 bytes")
        }
        var data = LegacyTrackerProtocol.registrationMagic
        data.append(ipv4)
        data.append(LegacyWire.uint16BE(port))
        data.append(try LegacyTrackerProtocol.string8(serverName))
        data.append(try LegacyTrackerProtocol.string8(description))
        data.append(LegacyWire.uint16BE(users))
        data.append(LegacyWire.uint32BE(flags))
        return data
    }

    static func decode(_ data: Data) throws -> LegacyTrackerRegistration {
        var cursor = LegacyByteCursor(data)
        guard try cursor.readBytes(count: 4) == LegacyTrackerProtocol.registrationMagic else {
            throw LegacyProtocolError.invalidRecord("invalid tracker registration magic/version")
        }
        let value = LegacyTrackerRegistration(
            ipv4: try cursor.readBytes(count: 4),
            port: try cursor.readUInt16BE(),
            serverName: try LegacyTrackerProtocol.readString8(from: &cursor),
            description: try LegacyTrackerProtocol.readString8(from: &cursor),
            users: try cursor.readUInt16BE(),
            flags: try cursor.readUInt32BE()
        )
        try cursor.requireEnd()
        return value
    }
}
