import Foundation

enum LegacyFilesRootCapability {
    /// Additive login-success field containing the UTF-8 display name of the session's virtual Files root.
    static let loginFieldType: UInt32 = 0xF000_0201
    static let defaultDisplayName = "Allgemein"
}

enum LegacyMediaCapability {
    static let loginFieldType: UInt32 = 0xF000_0200
    static let attachmentsV1: UInt32 = 1 << 0
    static let youtubeLinksV1: UInt32 = 1 << 1
    static let ownerDeleteV1: UInt32 = 1 << 2
    static let current: UInt32 = attachmentsV1 | youtubeLinksV1 | ownerDeleteV1
}

enum LegacyMediaContext: Equatable {
    case pending
    case channel(UInt32)
    case news(Data)

    var kind: UInt8 {
        switch self {
        case .pending: return 0
        case .channel: return 1
        case .news: return 2
        }
    }

    var scopeWire: Data {
        switch self {
        case .pending: return Data()
        case let .channel(channelID): return LegacyWire.uint32BE(channelID)
        case let .news(group): return group
        }
    }
}

struct LegacyMediaReference: Equatable, Hashable {
    static let prefix = "[[carracho-image:"
    static let suffix = "]]"
    let id: UUID

    var token: String { Self.prefix + id.uuidString.lowercased() + Self.suffix }

    static func token(for id: UUID) -> String { LegacyMediaReference(id: id).token }

    static func references(in text: String) -> [LegacyMediaReference] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[carracho-image:([0-9a-fA-F-]{36})\]\]"#) else { return [] }
        let ns = text as NSString
        var result: [LegacyMediaReference] = []
        var seen = Set<UUID>()
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges == 2 {
            guard let id = UUID(uuidString: ns.substring(with: match.range(at: 1))), seen.insert(id).inserted else { continue }
            result.append(LegacyMediaReference(id: id))
        }
        return result
    }

    static func references(inWire data: Data) -> [LegacyMediaReference] {
        references(in: CarrachoTextWire.string(from: data))
    }

    enum Segment: Equatable {
        case text(String)
        case image(UUID)
        case youtube(LegacyYouTubeReference)
    }

    static func segments(in text: String) -> [Segment] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[(carracho-image|carracho-youtube):([^\]]+)\]\]"#) else { return [.text(text)] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.text(text)] }
        var cursor = 0
        var output: [Segment] = []
        for match in matches where match.numberOfRanges == 3 {
            if match.range.location > cursor {
                output.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            let kind = ns.substring(with: match.range(at: 1))
            let payload = ns.substring(with: match.range(at: 2))
            if kind == "carracho-image", let id = UUID(uuidString: payload) {
                output.append(.image(id))
            } else if kind == "carracho-youtube", let reference = LegacyYouTubeReference(videoID: payload) {
                output.append(.youtube(reference))
            } else {
                output.append(.text(ns.substring(with: match.range)))
            }
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length { output.append(.text(ns.substring(from: cursor))) }
        return output
    }
}


struct LegacyYouTubeReference: Equatable, Hashable {
    static let prefix = "[[carracho-youtube:"
    static let suffix = "]]"
    private static let videoIDPattern = #"^[A-Za-z0-9_-]{11}$"#
    private static let acceptedHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtu.be",
    ]

    let videoID: String

    init?(videoID: String) {
        guard Self.isValidVideoID(videoID) else { return nil }
        self.videoID = videoID
    }

    init?(urlString: String) {
        let candidate = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), Self.acceptedHosts.contains(host),
              let videoID = Self.extractVideoID(components: components, host: host),
              Self.isValidVideoID(videoID) else { return nil }
        self.videoID = videoID
    }

    var token: String { Self.prefix + videoID + Self.suffix }
    var canonicalURLString: String { "https://www.youtube.com/watch?v=\(videoID)" }
    var canonicalURL: URL { URL(string: canonicalURLString)! }

    static func references(in text: String) -> [LegacyYouTubeReference] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[carracho-youtube:([A-Za-z0-9_-]{11})\]\]"#) else { return [] }
        let ns = text as NSString
        var result: [LegacyYouTubeReference] = []
        var seen = Set<String>()
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges == 2 {
            let id = ns.substring(with: match.range(at: 1))
            guard seen.insert(id).inserted, let reference = LegacyYouTubeReference(videoID: id) else { continue }
            result.append(reference)
        }
        return result
    }

    static func references(inWire data: Data) -> [LegacyYouTubeReference] {
        references(in: CarrachoTextWire.string(from: data))
    }

    /// The `carracho-youtube` prefix is reserved. If it appears at all it must be a
    /// complete token with a strict 11-character YouTube video ID. This prevents a
    /// look-alike URL from being smuggled into the rich-content syntax.
    static func hasOnlyValidTokens(in text: String, maximum: Int) -> Bool {
        var cursor = text.startIndex
        var count = 0
        while let range = text.range(of: prefix, range: cursor..<text.endIndex) {
            let payloadStart = range.upperBound
            guard let suffixRange = text.range(of: suffix, range: payloadStart..<text.endIndex) else { return false }
            let payload = String(text[payloadStart..<suffixRange.lowerBound])
            guard isValidVideoID(payload) else { return false }
            count += 1
            guard count <= maximum else { return false }
            cursor = suffixRange.upperBound
        }
        return true
    }

    static func hasOnlyValidTokens(inWire data: Data, maximum: Int) -> Bool {
        hasOnlyValidTokens(in: CarrachoTextWire.string(from: data), maximum: maximum)
    }

    private static func isValidVideoID(_ value: String) -> Bool {
        value.range(of: videoIDPattern, options: .regularExpression) != nil
    }

    private static func extractVideoID(components: URLComponents, host: String) -> String? {
        let pathParts = components.path.split(separator: "/").map(String.init)
        if host == "youtu.be" || host == "www.youtu.be" {
            return pathParts.first
        }
        if components.path == "/watch" || components.path == "/watch/" {
            return components.queryItems?.first(where: { $0.name == "v" })?.value
        }
        guard pathParts.count >= 2,
              ["shorts", "embed", "live"].contains(pathParts[0].lowercased()) else { return nil }
        return pathParts[1]
    }
}

enum LegacyMediaTransfer {
    static let maximumImageBytes = 4 * 1024 * 1024
    static let maximumDimension = 4096
    static let maximumImagesPerChatMessage = 4
    static let maximumImagesPerNewsPost = 10
    static let maximumYouTubeLinksPerChatMessage = 4
    static let maximumYouTubeLinksPerNewsPost = 10
    static let pendingLifetime: TimeInterval = 60 * 60
    static let chatLifetime: TimeInterval = 7 * 24 * 60 * 60
}
