import Foundation

/// Finder-compatible color label numbers. These raw values intentionally match
/// macOS' NSURLLabelNumberKey / Finder label ordering. Classic Carracho never
/// sees these values; they are carried only by modern extension fields.
enum LegacyFileLabel: UInt8, CaseIterable, Codable, Equatable, Hashable {
    case none = 0
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    static func decode(_ data: Data) throws -> LegacyFileLabel {
        guard data.count == 1, let value = data.first, let label = LegacyFileLabel(rawValue: value) else {
            throw LegacyProtocolError.invalidRecord("invalid modern file label")
        }
        return label
    }

    var encoded: Data { Data([rawValue]) }
}

enum LegacyFileLabelField {
    /// Optional modern-only field on Classic file-info/set-file-info packets.
    static let fileInfo: UInt32 = 0xf0000600
    /// Optional modern-only field on directory replies: one label byte per packed entry.
    static let directoryLabels: UInt32 = 0xf0000601
}

struct LegacyFileInfoMetadata: Equatable {
    static let wireSize = 30

    var flags: UInt16
    var size: UInt32
    var created: UInt32
    var modified: UInt32
    var finderInfo: Data

    func encoded() throws -> Data {
        guard finderInfo.count == 16 else {
            throw LegacyProtocolError.invalidLength("Finder metadata must be exactly 16 bytes")
        }
        var data = LegacyWire.uint16BE(flags)
        data.append(LegacyWire.uint32BE(size))
        data.append(LegacyWire.uint32BE(created))
        data.append(LegacyWire.uint32BE(modified))
        data.append(finderInfo)
        return data
    }

    static func decode(_ data: Data) throws -> LegacyFileInfoMetadata {
        guard data.count == wireSize else {
            throw LegacyProtocolError.invalidLength("file-info metadata must be exactly 30 bytes")
        }
        var cursor = LegacyByteCursor(data)
        let value = LegacyFileInfoMetadata(
            flags: try cursor.readUInt16BE(),
            size: try cursor.readUInt32BE(),
            created: try cursor.readUInt32BE(),
            modified: try cursor.readUInt32BE(),
            finderInfo: try cursor.readBytes(count: 16)
        )
        try cursor.requireEnd()
        return value
    }
}

struct LegacyFileInfoReply: Equatable {
    var path: Data
    var name: Data
    var metadata: LegacyFileInfoMetadata
    var comment: Data
    /// Modern-only Finder-style label. Classic peers omit the extension and therefore use `.none`.
    var label: LegacyFileLabel = .none
}
