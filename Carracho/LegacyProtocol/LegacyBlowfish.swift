import Foundation

struct LegacyBlowfish {
    private var p: [UInt32]
    private var s: [[UInt32]]

    init(key: Data) throws {
        guard !key.isEmpty else { throw LegacyProtocolError.invalidLength("Blowfish key is empty") }
        let initial = LegacyBlowfishInitialState.words
        guard initial.count == 1042 else {
            throw LegacyProtocolError.invalidRecord("invalid embedded Blowfish initialization table")
        }
        p = Array(initial[0..<18])
        s = (0..<4).map { box in Array(initial[(18 + box * 256)..<(18 + (box + 1) * 256)]) }

        let keyBytes = Array(key)
        var keyIndex = 0
        for index in p.indices {
            var word: UInt32 = 0
            for _ in 0..<4 {
                word = (word << 8) | UInt32(keyBytes[keyIndex])
                keyIndex = (keyIndex + 1) % keyBytes.count
            }
            p[index] ^= word
        }

        var left: UInt32 = 0
        var right: UInt32 = 0
        for index in stride(from: 0, to: 18, by: 2) {
            (left, right) = encryptWords(left, right)
            p[index] = left
            p[index + 1] = right
        }
        for box in 0..<4 {
            for index in stride(from: 0, to: 256, by: 2) {
                (left, right) = encryptWords(left, right)
                s[box][index] = left
                s[box][index + 1] = right
            }
        }
    }

    private func f(_ value: UInt32) -> UInt32 {
        let a = Int((value >> 24) & 0xff)
        let b = Int((value >> 16) & 0xff)
        let c = Int((value >> 8) & 0xff)
        let d = Int(value & 0xff)
        return ((s[0][a] &+ s[1][b]) ^ s[2][c]) &+ s[3][d]
    }

    func encryptWords(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
        var l = left
        var r = right
        for index in 0..<16 {
            let x = l ^ p[index]
            (l, r) = (r ^ f(x), x)
        }
        return (r ^ p[17], l ^ p[16])
    }

    func decryptWords(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
        var l = left
        var r = right
        for index in stride(from: 17, through: 2, by: -1) {
            let x = l ^ p[index]
            (l, r) = (r ^ f(x), x)
        }
        return (r ^ p[0], l ^ p[1])
    }

    func encryptBlock(_ block: Data) throws -> Data {
        guard block.count == 8 else { throw LegacyProtocolError.invalidLength("Blowfish block must be 8 bytes") }
        var cursor = LegacyByteCursor(block)
        let result = encryptWords(try cursor.readUInt32BE(), try cursor.readUInt32BE())
        var data = LegacyWire.uint32BE(result.0)
        data.append(LegacyWire.uint32BE(result.1))
        return data
    }

    func decryptBlock(_ block: Data) throws -> Data {
        guard block.count == 8 else { throw LegacyProtocolError.invalidLength("Blowfish block must be 8 bytes") }
        var cursor = LegacyByteCursor(block)
        let result = decryptWords(try cursor.readUInt32BE(), try cursor.readUInt32BE())
        var data = LegacyWire.uint32BE(result.0)
        data.append(LegacyWire.uint32BE(result.1))
        return data
    }
}
