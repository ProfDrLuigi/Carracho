import Foundation

/// Rich-text agreement content. This exact blob is used as login-success TLV 4.
struct LegacyAgreementContent: Equatable {
    var text: Data
    var styleData: Data

    func encoded() throws -> Data {
        guard text.count <= Int(UInt32.max), styleData.count <= Int(UInt32.max) else {
            throw LegacyProtocolError.invalidLength("agreement text/style payload too large")
        }
        var data = LegacyWire.uint32BE(UInt32(text.count))
        data.append(text)
        data.append(LegacyWire.uint32BE(UInt32(styleData.count)))
        data.append(styleData)
        return data
    }

    static func decode(_ data: Data) throws -> LegacyAgreementContent {
        var cursor = LegacyByteCursor(data)
        let textLength = Int(try cursor.readUInt32BE())
        let text = try cursor.readBytes(count: textLength)
        let styleLength = Int(try cursor.readUInt32BE())
        let styleData = try cursor.readBytes(count: styleLength)
        try cursor.requireEnd()
        return LegacyAgreementContent(text: text, styleData: styleData)
    }
}

/// Server-setting field 0x04. Unlike login TLV 4 this has a leading enabled byte.
struct LegacyAgreementSetting: Equatable {
    static let maximumClassicWireLength = 0xFC00

    var enabled: Bool
    var content: LegacyAgreementContent

    func encoded() throws -> Data {
        var data = Data([enabled ? 1 : 0])
        data.append(try content.encoded())
        guard data.count <= Self.maximumClassicWireLength else {
            throw LegacyProtocolError.invalidLength("agreement setting exceeds classic 0xfc00-byte limit")
        }
        return data
    }

    static func decode(_ data: Data) throws -> LegacyAgreementSetting {
        guard !data.isEmpty else {
            throw LegacyProtocolError.invalidLength("agreement setting requires enabled byte")
        }
        guard data.count <= maximumClassicWireLength else {
            throw LegacyProtocolError.invalidLength("agreement setting exceeds classic 0xfc00-byte limit")
        }
        var cursor = LegacyByteCursor(data)
        let enabled = try cursor.readUInt8() != 0
        let contentData = try cursor.readBytes(count: cursor.remaining)
        let content: LegacyAgreementContent
        if contentData.isEmpty {
            content = LegacyAgreementContent(text: Data(), styleData: Data())
        } else {
            content = try LegacyAgreementContent.decode(contentData)
        }
        return LegacyAgreementSetting(enabled: enabled, content: content)
    }
}
