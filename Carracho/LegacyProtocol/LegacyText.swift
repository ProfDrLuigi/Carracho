import Foundation

/// Backward-compatible text wrapper for protocol fields that historically carried
/// MacRoman bytes. Plain MacRoman remains byte-for-byte Classic compatible. Text
/// outside that repertoire is tagged with the standard UTF-8 BOM so modern
/// Carracho peers can preserve emoji and the rest of Unicode without changing any
/// surrounding packet or record layout.
enum CarrachoTextWire {
    private static let utf8BOM = Data([0xef, 0xbb, 0xbf])

    static func encode(_ string: String, maximumBytes: Int) throws -> Data {
        if let classic = string.data(using: .macOSRoman), classic.count <= maximumBytes {
            return classic
        }
        var encoded = utf8BOM
        encoded.append(contentsOf: string.utf8)
        guard encoded.count <= maximumBytes else {
            throw LegacyProtocolError.invalidLength("Unicode text exceeds the protocol byte limit")
        }
        return encoded
    }

    static func encodeIfNotEmpty(_ string: String, maximumBytes: Int) throws -> Data {
        guard !string.isEmpty else { return Data() }
        return try encode(string, maximumBytes: maximumBytes)
    }

    static func string(from data: Data) -> String {
        if data.starts(with: utf8BOM) {
            return String(decoding: data.dropFirst(utf8BOM.count), as: UTF8.self)
        }
        return String(data: data, encoding: .macOSRoman) ?? String(decoding: data, as: UTF8.self)
    }

    static func validatedString(from data: Data) -> String? {
        if data.starts(with: utf8BOM) {
            return String(data: Data(data.dropFirst(utf8BOM.count)), encoding: .utf8)
        }
        return String(data: data, encoding: .macOSRoman)
    }

    static func macRomanFilteringUnrepresentable(from data: Data) -> Data? {
        guard isTaggedUTF8(data) else { return data }
        guard let text = validatedString(from: data) else { return nil }
        var result = Data()
        for character in text {
            if let encoded = String(character).data(using: .macOSRoman) {
                result.append(encoded)
            }
        }
        return result
    }


    /// Downgrade a modern broadcast for a Classic peer. Emoji are removed because the Classic
    /// wire has no representation for them; any other non-MacRoman Unicode remains an error
    /// instead of being silently discarded.
    static func macRomanFilteringEmoji(from data: Data) -> Data? {
        guard isTaggedUTF8(data) else { return data }
        guard let text = validatedString(from: data) else { return nil }
        var result = Data()
        for character in text {
            if isEmojiCharacter(character) { continue }
            guard let encoded = String(character).data(using: .macOSRoman) else { return nil }
            result.append(encoded)
        }
        return result
    }

    private static func isEmojiCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || scalar.value == 0xfe0f       // emoji variation selector
                || scalar.value == 0x200d       // zero-width joiner in emoji sequences
                || scalar.value == 0x20e3       // keycap combining mark
                || (0x1f1e6...0x1f1ff).contains(scalar.value) // regional-indicator flags
        }
    }

    static func isTaggedUTF8(_ data: Data) -> Bool {
        data.starts(with: utf8BOM)
    }
}
