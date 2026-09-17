import Foundation

enum LegacyCryptoFraming {
    static let controlXORLeft: UInt32 = 0x10576419
    static let controlXORRight: UInt32 = 0x58022919
    static let transferXORLeft: UInt32 = 0x10576419
    static let transferXORRight: UInt32 = 0x58022919

    private static func cryptControlBlocks(_ data: Data, key: Data, decrypt: Bool) throws -> Data {
        guard data.count.isMultiple(of: 8) else {
            throw LegacyProtocolError.invalidLength("control ciphertext is not block aligned")
        }
        let cipher = try LegacyBlowfish(key: key)
        var cursor = LegacyByteCursor(data)
        var output = Data()
        output.reserveCapacity(data.count)
        while !cursor.isAtEnd {
            var left = try cursor.readUInt32BE()
            var right = try cursor.readUInt32BE()
            if decrypt {
                left ^= controlXORLeft
                (left, right) = cipher.decryptWords(left, right)
                right ^= controlXORRight
            } else {
                right ^= controlXORRight
                (left, right) = cipher.encryptWords(left, right)
                left ^= controlXORLeft
            }
            output.append(LegacyWire.uint32BE(left))
            output.append(LegacyWire.uint32BE(right))
        }
        return output
    }

    static func encodeControlFrame(plaintext: Data, key: Data) throws -> Data {
        let padding = 8 - (plaintext.count % 8) // aligned packets get a full zero block
        var padded = plaintext
        padded.append(Data(repeating: 0, count: padding))
        let encrypted = try cryptControlBlocks(padded, key: key, decrypt: false)
        var frame = LegacyWire.uint32BE(UInt32(encrypted.count))
        frame.append(encrypted)
        return frame
    }

    static func decodeControlFrame(_ frame: Data, key: Data) throws -> Data {
        var cursor = LegacyByteCursor(frame)
        let encryptedLength = Int(try cursor.readUInt32BE())
        guard encryptedLength.isMultiple(of: 8), encryptedLength == cursor.remaining else {
            throw LegacyProtocolError.invalidLength("invalid control frame length")
        }
        return try cryptControlBlocks(cursor.readBytes(count: encryptedLength), key: key, decrypt: true)
    }

    private static func cryptTransferBlocks(_ data: Data, key: Data, decrypt: Bool) throws -> Data {
        guard data.count.isMultiple(of: 8) else {
            throw LegacyProtocolError.invalidLength("transfer ciphertext is not block aligned")
        }
        let cipher = try LegacyBlowfish(key: key)
        var cursor = LegacyByteCursor(data)
        var output = Data()
        output.reserveCapacity(data.count)
        while !cursor.isAtEnd {
            var left = try cursor.readUInt32BE()
            var right = try cursor.readUInt32BE()
            if decrypt {
                right ^= transferXORRight
                (left, right) = cipher.decryptWords(left, right)
                left ^= transferXORLeft
            } else {
                left ^= transferXORLeft
                (left, right) = cipher.encryptWords(left, right)
                right ^= transferXORRight
            }
            output.append(LegacyWire.uint32BE(left))
            output.append(LegacyWire.uint32BE(right))
        }
        return output
    }

    static func encodeTransferBlock(payload: Data, key: Data) throws -> Data {
        let padding = (8 - (payload.count % 8)) % 8 // aligned payloads get no padding
        var padded = payload
        padded.append(Data(repeating: 0, count: padding))
        let encrypted = try cryptTransferBlocks(padded, key: key, decrypt: false)
        var frame = LegacyWire.uint32BE(UInt32(encrypted.count))
        frame.append(LegacyWire.uint32BE(0))
        frame.append(UInt8(padding))
        frame.append(encrypted)
        return frame
    }

    static func decodeTransferBlock(_ frame: Data, key: Data) throws -> Data {
        var cursor = LegacyByteCursor(frame)
        let encryptedLength = Int(try cursor.readUInt32BE())
        let reserved = try cursor.readUInt32BE()
        let padding = Int(try cursor.readUInt8())
        guard reserved == 0 else { throw LegacyProtocolError.invalidRecord("transfer reserved word is nonzero") }
        guard padding <= 7, encryptedLength.isMultiple(of: 8), encryptedLength == cursor.remaining else {
            throw LegacyProtocolError.invalidLength("invalid transfer frame")
        }
        let plain = try cryptTransferBlocks(cursor.readBytes(count: encryptedLength), key: key, decrypt: true)
        guard padding <= plain.count else { throw LegacyProtocolError.invalidLength("transfer padding exceeds payload") }
        return plain.prefix(plain.count - padding)
    }
}
