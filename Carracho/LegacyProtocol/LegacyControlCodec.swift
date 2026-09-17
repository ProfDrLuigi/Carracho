import Foundation

enum LegacyControlCodec {
    static let maximumCiphertextLength = LegacyPacket.headerSize + LegacyPacket.maximumClassicBodyLength + 8

    static func encode(_ packet: LegacyPacket, key: Data, alignOddValuesToUInt16: Bool = false) throws -> Data {
        try LegacyCryptoFraming.encodeControlFrame(
            plaintext: packet.plaintext(alignOddValuesToUInt16: alignOddValuesToUInt16), key: key
        )
    }

    static func decode(_ frame: Data, key: Data) throws -> LegacyPacket {
        let plaintext = try LegacyCryptoFraming.decodeControlFrame(frame, key: key)
        let decoded = try LegacyPacket.parsePlaintext(plaintext)
        // Classic Server 1.0b13 rounds the encrypted buffer to a Blowfish block using
        // bytes from reused storage. Those trailing bytes are transport padding, not part
        // of the logical packet, and are not guaranteed to be zero. Block-aligned packets
        // may also arrive without an extra padding block. The authenticated packet lengths
        // above remain authoritative, so only the block-padding extent needs validation.
        guard (0...8).contains(decoded.trailing.count) else {
            throw LegacyProtocolError.invalidLength("control frame contains more than one block of transport padding")
        }
        return decoded.packet
    }
}

extension LegacyTLV {
    func uint16BE() throws -> UInt16 {
        guard value.count == 2 else {
            throw LegacyProtocolError.invalidLength("TLV \(type) must contain one UInt16")
        }
        var cursor = LegacyByteCursor(value)
        let result = try cursor.readUInt16BE()
        try cursor.requireEnd()
        return result
    }

    func uint32BE() throws -> UInt32 {
        guard value.count == 4 else {
            throw LegacyProtocolError.invalidLength("TLV \(type) must contain one UInt32")
        }
        var cursor = LegacyByteCursor(value)
        let result = try cursor.readUInt32BE()
        try cursor.requireEnd()
        return result
    }
}

extension LegacyPacket {
    func firstField(type: UInt32) -> LegacyTLV? {
        fields.first { $0.type == type }
    }
}
