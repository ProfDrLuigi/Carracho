import Foundation

enum LegacyArticle {
    static let noArticle: UInt32 = .max
}

/// Exact TLV type 1 payload returned by command 0xa1 for a read-article request.
struct LegacyArticleReplyMetadata: Equatable {
    var group: Data
    var articleID: UInt32
    var previousArticleID: UInt32
    var nextArticleID: UInt32
    var subject: Data
    var sender: Data
    var date: UInt32

    func encoded() throws -> Data {
        var data = try LegacyWire.string16(group)
        data.append(LegacyWire.uint32BE(articleID))
        data.append(LegacyWire.uint32BE(previousArticleID))
        data.append(LegacyWire.uint32BE(nextArticleID))
        data.append(try LegacyWire.string16(subject))
        data.append(try LegacyWire.string16(sender))
        data.append(LegacyWire.uint32BE(date))
        return data
    }

    static func decode(_ data: Data) throws -> LegacyArticleReplyMetadata {
        var cursor = LegacyByteCursor(data)
        let value = LegacyArticleReplyMetadata(group: try cursor.readString16(),
                                               articleID: try cursor.readUInt32BE(),
                                               previousArticleID: try cursor.readUInt32BE(),
                                               nextArticleID: try cursor.readUInt32BE(),
                                               subject: try cursor.readString16(),
                                               sender: try cursor.readString16(),
                                               date: try cursor.readUInt32BE())
        try cursor.requireEnd()
        return value
    }
}

struct LegacyArticleIndexEntry: Equatable {
    var articleID: UInt32
    var subject: Data
    var sender: Data
    var date: UInt32
    /// Length field persisted in SArticleIndex and used when the article body is read.
    var bodyLength: UInt32

    func encoded() throws -> Data {
        var data = LegacyWire.uint32BE(articleID)
        data.append(try LegacyWire.string16(subject))
        data.append(try LegacyWire.string16(sender))
        data.append(LegacyWire.uint32BE(date))
        data.append(LegacyWire.uint32BE(bodyLength))
        return data
    }

    static func decode(from cursor: inout LegacyByteCursor) throws -> LegacyArticleIndexEntry {
        LegacyArticleIndexEntry(articleID: try cursor.readUInt32BE(),
                                subject: try cursor.readString16(),
                                sender: try cursor.readString16(),
                                date: try cursor.readUInt32BE(),
                                bodyLength: try cursor.readUInt32BE())
    }
}

struct LegacyArticleIndex: Equatable {
    var group: Data
    var entries: [LegacyArticleIndexEntry]

    func encoded() throws -> Data {
        guard entries.count <= Int(UInt32.max) else {
            throw LegacyProtocolError.invalidLength("too many article index entries")
        }
        var data = try LegacyWire.string16(group)
        data.append(LegacyWire.uint32BE(UInt32(entries.count)))
        for entry in entries { data.append(try entry.encoded()) }
        return data
    }

    static func decode(_ data: Data) throws -> LegacyArticleIndex {
        var cursor = LegacyByteCursor(data)
        let group = try cursor.readString16()
        let count = Int(try cursor.readUInt32BE())
        var entries: [LegacyArticleIndexEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count { entries.append(try LegacyArticleIndexEntry.decode(from: &cursor)) }
        try cursor.requireEnd()
        return LegacyArticleIndex(group: group, entries: entries)
    }
}


struct LegacyArticleReply: Equatable {
    var metadata: LegacyArticleReplyMetadata
    var body: LegacyArticleBodyPayload
}

/// Rich-text body stored by the classic server and returned as article TLV type 2.
/// Client 1.0b10r4 initially sends articleID=0 and reservedWord=0xffffffff; the
/// server overwrites the first word with the assigned article ID before storing it.
struct LegacyArticleBodyPayload: Equatable {
    var articleID: UInt32
    var reservedWord: UInt32
    var text: Data
    var styleData: Data

    func encoded() throws -> Data {
        guard text.count <= Int(UInt32.max), styleData.count <= Int(UInt32.max) else {
            throw LegacyProtocolError.invalidLength("article text/style payload too large")
        }
        var data = LegacyWire.uint32BE(articleID)
        data.append(LegacyWire.uint32BE(reservedWord))
        data.append(LegacyWire.uint32BE(UInt32(text.count)))
        data.append(LegacyWire.uint32BE(UInt32(styleData.count)))
        data.append(text)
        data.append(styleData)
        return data
    }

    static func decode(_ data: Data, allowsTrailingClassicBytes: Bool = false) throws -> LegacyArticleBodyPayload {
        var cursor = LegacyByteCursor(data)
        let articleID = try cursor.readUInt32BE()
        let reservedWord = try cursor.readUInt32BE()
        let textLength = Int(try cursor.readUInt32BE())
        let styleLength = Int(try cursor.readUInt32BE())
        let value = LegacyArticleBodyPayload(articleID: articleID,
                                             reservedWord: reservedWord,
                                             text: try cursor.readBytes(count: textLength),
                                             styleData: try cursor.readBytes(count: styleLength))
        // Carracho Server 1.0b13 can return bytes after the declared text/style
        // payload when reading persisted Classic articles. They are not part of
        // the article contents. Keep modern/persisted decoding strict.
        if !allowsTrailingClassicBytes { try cursor.requireEnd() }
        return value
    }
}


/// Operation-4 payload after its UInt32 BE length prefix.
struct LegacyArticleUploadPayload: Equatable {
    var group: Data
    var subject: Data
    var body: LegacyArticleBodyPayload

    func encoded() throws -> Data {
        var data = try LegacyWire.string16(group)
        data.append(try LegacyWire.string16(subject))
        data.append(try body.encoded())
        return data
    }

    static func decode(_ data: Data) throws -> LegacyArticleUploadPayload {
        var cursor = LegacyByteCursor(data)
        let group = try cursor.readString16()
        let subject = try cursor.readString16()
        let articleID = try cursor.readUInt32BE()
        let reservedWord = try cursor.readUInt32BE()
        let textLength = Int(try cursor.readUInt32BE())
        let styleLength = Int(try cursor.readUInt32BE())
        let body = LegacyArticleBodyPayload(articleID: articleID,
                                            reservedWord: reservedWord,
                                            text: try cursor.readBytes(count: textLength),
                                            styleData: try cursor.readBytes(count: styleLength))
        try cursor.requireEnd()
        return LegacyArticleUploadPayload(group: group, subject: subject, body: body)
    }
}

enum LegacyNewsTransfer {
    static let maximumArticleReceiverPayload = 0x40000
    static let maximumGroupNameLength = 64

    static func encodeArticleReceiverStream(_ value: LegacyArticleUploadPayload) throws -> Data {
        let payload = try value.encoded()
        guard payload.count <= maximumArticleReceiverPayload else {
            throw LegacyProtocolError.invalidLength("article receiver payload exceeds classic 0x40000-byte limit")
        }
        var data = LegacyWire.uint32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func decodeArticleReceiverStream(_ data: Data) throws -> LegacyArticleUploadPayload {
        var cursor = LegacyByteCursor(data)
        let length = Int(try cursor.readUInt32BE())
        guard length <= maximumArticleReceiverPayload else {
            throw LegacyProtocolError.invalidLength("article receiver payload exceeds classic 0x40000-byte limit")
        }
        let value = try LegacyArticleUploadPayload.decode(cursor.readBytes(count: length))
        try cursor.requireEnd()
        return value
    }

    static func encodeIndexRequest(group: Data) throws -> Data {
        guard group.count <= maximumGroupNameLength else {
            throw LegacyProtocolError.invalidLength("newsgroup name exceeds classic 64-byte limit")
        }
        return try LegacyWire.string16(group)
    }

    static func decodeIndexRequest(_ data: Data) throws -> Data {
        var cursor = LegacyByteCursor(data)
        let group = try cursor.readString16()
        guard group.count <= maximumGroupNameLength else {
            throw LegacyProtocolError.invalidLength("newsgroup name exceeds classic 64-byte limit")
        }
        try cursor.requireEnd()
        return group
    }

    static func encodeIndexResponse(_ index: Data?) throws -> Data {
        guard let index else { return LegacyWire.uint32BE(LegacyArticle.noArticle) }
        guard index.count <= Int(UInt32.max) else {
            throw LegacyProtocolError.invalidLength("news index payload too large")
        }
        var data = LegacyWire.uint32BE(UInt32(index.count))
        data.append(index)
        return data
    }

    static func decodeIndexResponse(_ data: Data) throws -> Data? {
        var cursor = LegacyByteCursor(data)
        let length = try cursor.readUInt32BE()
        if length == LegacyArticle.noArticle {
            try cursor.requireEnd()
            return nil
        }
        let value = try cursor.readBytes(count: Int(length))
        try cursor.requireEnd()
        return value
    }
}
