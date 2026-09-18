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

    /// Downgrade tagged UTF-8 for a Classic peer while keeping emoji readable.
    ///
    /// Classic Carracho only understands MacRoman. Instead of silently deleting an emoji,
    /// describe common emoji with a compact stable alias, e.g. 😄 becomes *laughing*.
    /// Unknown emoji fall back to their Unicode character names. Non-emoji Unicode that
    /// cannot be represented in MacRoman remains an error so ordinary text is never silently mangled.
    static func macRomanDescribingEmoji(from data: Data, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0 else { return nil }
        guard isTaggedUTF8(data) else {
            return data.count <= maximumBytes ? data : nil
        }
        guard let text = validatedString(from: data) else { return nil }

        var result = Data()
        result.reserveCapacity(min(maximumBytes, text.utf8.count))

        for character in text {
            let replacement: Data
            if let encoded = String(character).data(using: .macOSRoman) {
                replacement = encoded
            } else {
                guard isEmojiCharacter(character),
                      let description = emojiDescription(character),
                      let encoded = description.data(using: .macOSRoman) else {
                    return nil
                }
                replacement = encoded
            }

            guard result.count + replacement.count <= maximumBytes else { return nil }
            result.append(replacement)
        }
        return result
    }

    private static func emojiDescription(_ character: Character) -> String? {
        let raw = String(character)
        if let alias = emojiSequenceShortAliases[raw] {
            return "*" + alias + "*"
        }

        // Skin-tone and presentation modifiers do not need to make the Classic fallback noisy.
        // If the remaining emoji is a single known scalar, use the same stable short alias.
        let meaningfulScalars = character.unicodeScalars.filter { scalar in
            scalar.value != 0xfe0e
                && scalar.value != 0xfe0f
                && !(0x1f3fb...0x1f3ff).contains(scalar.value)
        }
        if meaningfulScalars.count == 1,
           let scalar = meaningfulScalars.first,
           let alias = emojiScalarShortAliases[scalar.value] {
            return "*" + alias + "*"
        }

        var names: [String] = []
        for scalar in character.unicodeScalars {
            switch scalar.value {
            case 0xfe0e, 0xfe0f, 0x200d:
                // Text/emoji variation selectors and the ZWJ glue a sequence together but are
                // not useful to a human reading the Classic fallback.
                continue
            case 0x1f3fb...0x1f3ff:
                // Skin tone is already visible to modern peers and does not need to make the
                // Classic fallback read like a sentence.
                continue
            default:
                if let alias = emojiScalarShortAliases[scalar.value] {
                    names.append(alias)
                } else if let name = scalar.properties.name {
                    names.append(name.lowercased())
                }
            }
        }
        guard !names.isEmpty else { return nil }
        return "*" + names.joined(separator: " + ") + "*"
    }

    /// Stable aliases deliberately stay small and human-readable. These are presentation
    /// names for Classic peers, not protocol identifiers, so changing Unicode's long names
    /// cannot alter what old clients see.
    private static let emojiScalarShortAliases: [UInt32: String] = [
        0x2600: "sun",
        0x2615: "coffee",
        0x263a: "smile",
        0x26a1: "lightning",
        0x2705: "check",
        0x270c: "victory",
        0x274c: "cross",
        0x2764: "heart",
        0x2b50: "star",
        0x1f308: "rainbow",
        0x1f319: "moon",
        0x1f31f: "glowing_star",
        0x1f339: "rose",
        0x1f355: "pizza",
        0x1f37a: "beer",
        0x1f382: "cake",
        0x1f389: "party",
        0x1f3b5: "music",
        0x1f440: "eyes",
        0x1f44a: "fist",
        0x1f44c: "ok",
        0x1f44d: "thumbsup",
        0x1f44e: "thumbsdown",
        0x1f44f: "clap",
        0x1f47b: "ghost",
        0x1f47d: "alien",
        0x1f480: "skull",
        0x1f494: "broken_heart",
        0x1f495: "hearts",
        0x1f496: "sparkling_heart",
        0x1f499: "blue_heart",
        0x1f49a: "green_heart",
        0x1f49b: "yellow_heart",
        0x1f49c: "purple_heart",
        0x1f4a1: "idea",
        0x1f4a9: "poop",
        0x1f4aa: "muscle",
        0x1f4af: "100",
        0x1f4cc: "pin",
        0x1f4e6: "package",
        0x1f525: "fire",
        0x1f5a4: "black_heart",
        0x1f600: "grin",
        0x1f601: "grinning",
        0x1f602: "joy",
        0x1f603: "smiley",
        0x1f604: "laughing",
        0x1f605: "sweat_smile",
        0x1f606: "laugh",
        0x1f607: "angel",
        0x1f608: "devil",
        0x1f609: "wink",
        0x1f60a: "blush",
        0x1f60b: "yum",
        0x1f60d: "heart_eyes",
        0x1f60e: "cool",
        0x1f610: "neutral",
        0x1f612: "unamused",
        0x1f614: "pensive",
        0x1f618: "kiss",
        0x1f61b: "tongue",
        0x1f61c: "wink_tongue",
        0x1f61e: "disappointed",
        0x1f620: "angry",
        0x1f621: "rage",
        0x1f622: "cry",
        0x1f62d: "crying",
        0x1f62e: "surprised",
        0x1f631: "scream",
        0x1f634: "sleep",
        0x1f642: "smile",
        0x1f643: "upside_down",
        0x1f644: "eyeroll",
        0x1f64f: "pray",
        0x1f680: "rocket",
        0x1f90d: "white_heart",
        0x1f90e: "brown_heart",
        0x1f914: "thinking",
        0x1f916: "robot",
        0x1f917: "hug",
        0x1f91d: "handshake",
        0x1f922: "sick",
        0x1f923: "rofl",
        0x1f925: "lying",
        0x1f926: "facepalm",
        0x1f92e: "puke",
        0x1f92f: "mindblown",
        0x1f937: "shrug",
        0x1f973: "partyface",
        0x1f9e1: "orange_heart",
    ]

    private static let emojiSequenceShortAliases: [String: String] = [
        "❤️": "heart",
        "♥️": "heart",
        "👨‍👩‍👧‍👦": "family",
        "👩‍👩‍👧‍👦": "family",
        "👨‍👨‍👧‍👦": "family",
        "🏳️‍🌈": "rainbow_flag",
        "🏳️‍⚧️": "trans_flag",
        "👨‍💻": "coder",
        "👩‍💻": "coder",
        "🤦‍♂️": "facepalm",
        "🤦‍♀️": "facepalm",
        "🤷‍♂️": "shrug",
        "🤷‍♀️": "shrug",
    ]

    private static func isEmojiCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmoji
                || scalar.properties.isEmojiPresentation
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
