import Foundation

enum LegacyProtocolError: Error, Equatable, CustomStringConvertible {
    case truncated(expected: Int, remaining: Int)
    case invalidLength(String)
    case trailingBytes(Int)
    case invalidRecord(String)

    var description: String {
        switch self {
        case let .truncated(expected, remaining):
            return "Legacy protocol data truncated (expected \(expected), remaining \(remaining))"
        case let .invalidLength(message):
            return "Invalid legacy protocol length: \(message)"
        case let .trailingBytes(count):
            return "Legacy packed structure has \(count) trailing bytes"
        case let .invalidRecord(message):
            return "Invalid legacy protocol record: \(message)"
        }
    }
}

struct LegacyByteCursor {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.bytes = Array(data)
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { remaining == 0 }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0 else { throw LegacyProtocolError.invalidLength("negative byte count") }
        guard remaining >= count else {
            throw LegacyProtocolError.truncated(expected: count, remaining: remaining)
        }
        defer { offset += count }
        return Data(bytes[offset ..< offset + count])
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw LegacyProtocolError.truncated(expected: 1, remaining: remaining) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16BE() throws -> UInt16 {
        let data = try readBytes(count: 2)
        let b = Array(data)
        return (UInt16(b[0]) << 8) | UInt16(b[1])
    }

    mutating func readUInt32BE() throws -> UInt32 {
        let data = try readBytes(count: 4)
        let b = Array(data)
        return (UInt32(b[0]) << 24) |
               (UInt32(b[1]) << 16) |
               (UInt32(b[2]) << 8) |
               UInt32(b[3])
    }

    mutating func readUInt64BE() throws -> UInt64 {
        let data = try readBytes(count: 8)
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readString16() throws -> Data {
        try readBytes(count: Int(readUInt16BE()))
    }

    func requireEnd() throws {
        if remaining != 0 { throw LegacyProtocolError.trailingBytes(remaining) }
    }
}

enum LegacyWire {
    static let magic = Data("TCPCARRACHO".utf8)
    static let defaultControlPort: UInt16 = 6700

    static func uint16BE(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xff)])
    }

    static func uint32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    static func uint64BE(_ value: UInt64) -> Data {
        Data([
            UInt8((value >> 56) & 0xff), UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff), UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ])
    }

    static func string16(_ value: Data) throws -> Data {
        guard value.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("String16 exceeds 65535 bytes")
        }
        var result = uint16BE(UInt16(value.count))
        result.append(value)
        return result
    }

    static func string16(_ value: String) throws -> Data {
        guard let data = value.data(using: .macOSRoman) else {
            throw LegacyProtocolError.invalidRecord("string is not representable as MacRoman")
        }
        return try string16(data)
    }

    static func fixedCString(_ value: Data, width: Int) throws -> Data {
        guard width > 0 else { throw LegacyProtocolError.invalidLength("fixed string width must be positive") }
        let prefix = value.prefix { $0 != 0 }
        guard prefix.count < width else {
            throw LegacyProtocolError.invalidLength("value does not fit \(width)-byte NUL-terminated field")
        }
        var result = Data(prefix)
        result.append(Data(repeating: 0, count: width - result.count))
        return result
    }

    static func readFixedCString(_ value: Data) -> Data {
        if let zero = value.firstIndex(of: 0) { return value.prefix(upTo: zero) }
        return value
    }

    static func clientHello(version: UInt16 = 1) -> Data {
        var data = magic
        data.append(uint16BE(version))
        return data
    }

    static func serverHello(version: UInt16 = 2) -> Data {
        var data = magic
        data.append(uint16BE(version))
        return data
    }

    static func transferHello(operation: UInt16, userID: UInt32, versionWord: UInt32 = 0x01000000) -> Data {
        var data = uint32BE(versionWord)
        data.append(uint16BE(operation))
        data.append(uint32BE(userID))
        return data
    }
}


enum LegacyTransferOperation {
    static let articleReceiver: UInt16 = 4
    static let newsIndex: UInt16 = 5
    static let bannerUpload: UInt16 = 8
    static let fileSearch: UInt16 = 9
    static let encryptedDownload: UInt16 = 10
    static let encryptedUpload: UInt16 = 11
    static let bannerDownload: UInt16 = 15
    static let mediaUpload: UInt16 = 0xF100
    static let mediaDownload: UInt16 = 0xF101
    static let mediaDelete: UInt16 = 0xF102
}
