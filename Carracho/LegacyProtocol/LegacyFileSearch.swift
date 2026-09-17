import Foundation

/// Classic Carracho file-search query carried over transfer operation 9.
/// Client 1.0b10r4 emits one filename-contains clause: (1, 1, 1, UInt32 length, bytes).
struct LegacyFileSearchQuery: Equatable {
    static let maximumTextLength = 0xff
    var text: Data

    func encoded() throws -> Data {
        guard !text.isEmpty, text.count <= Self.maximumTextLength else {
            throw LegacyProtocolError.invalidLength("file-search text must contain 1...255 bytes")
        }
        var data = LegacyWire.uint16BE(1)
        data.append(1) // field: filename
        data.append(1) // comparator: contains
        data.append(1) // classic auxiliary byte
        data.append(LegacyWire.uint32BE(UInt32(text.count)))
        data.append(text)
        return data
    }

    static func decode(_ data: Data) throws -> LegacyFileSearchQuery {
        var cursor = LegacyByteCursor(data)
        let count = Int(try cursor.readUInt16BE())
        guard count > 0 else { throw LegacyProtocolError.invalidRecord("file-search query has no clauses") }
        var found: Data?
        for _ in 0..<count {
            let field = try cursor.readUInt8()
            let comparator = try cursor.readUInt8()
            _ = try cursor.readUInt8()
            let length = Int(try cursor.readUInt32BE())
            guard length <= Self.maximumTextLength else {
                throw LegacyProtocolError.invalidLength("file-search clause exceeds 255 bytes")
            }
            let value = try cursor.readBytes(count: length)
            if found == nil, field == 1, comparator == 1, !value.isEmpty { found = value }
        }
        try cursor.requireEnd()
        guard let found else {
            throw LegacyProtocolError.invalidRecord("file-search query has no classic filename-contains clause")
        }
        return LegacyFileSearchQuery(text: found)
    }
}

struct LegacyFileSearchResult: Equatable {
    static let maximumNameLength = 0xff

    var name: Data
    var creator: UInt32
    var fileType: UInt32
    var size: UInt32
    var timestamp: UInt32
    var path: Data

    var isFolder: Bool { fileType == 0x464c4452 } // 'FLDR'

    var directoryEntry: LegacyDirectoryEntry {
        LegacyDirectoryEntry(name: name, size: size, timestamp: timestamp,
                             fileType: fileType, creator: creator,
                             flags: isFolder ? LegacyDirectoryFlags.folder : 0)
    }

    func encodedClassicRecord() throws -> Data {
        guard !name.isEmpty, name.count <= Self.maximumNameLength else {
            throw LegacyProtocolError.invalidLength("file-search result name must contain 1...255 bytes")
        }
        guard path.count <= Int(UInt16.max) else {
            throw LegacyProtocolError.invalidLength("file-search result path exceeds 65535 bytes")
        }
        var data = Data([UInt8(name.count)])
        data.append(name)
        data.append(LegacyWire.uint32BE(creator))
        data.append(LegacyWire.uint32BE(fileType))
        data.append(LegacyWire.uint32BE(size))
        data.append(LegacyWire.uint32BE(timestamp))
        data.append(try LegacyWire.string16(path))
        return data
    }
}

enum LegacyFileSearchTransfer {
    /// Classic result frame: signal=1, count=1, reserved=0, then one result record.
    static func resultFrame(_ result: LegacyFileSearchResult) throws -> Data {
        var data = Data([1])
        data.append(LegacyWire.uint32BE(1))
        data.append(LegacyWire.uint32BE(0))
        data.append(try result.encodedClassicRecord())
        return data
    }

    /// Classic completion frame: signal=1 and result count 0.
    static var doneFrame: Data {
        var data = Data([1])
        data.append(LegacyWire.uint32BE(0))
        return data
    }
}
