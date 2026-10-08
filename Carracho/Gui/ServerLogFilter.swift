import Foundation

/// Display-only filtering for unstructured server log lines. All original lines remain intact.
/// Category matches are intentionally keyword-based: Classic and Linux logs may not carry
/// structured severity/category metadata.
struct ServerLogFilter {
    enum Category: Int, CaseIterable {
        case all = 0
        case errors = 1
        case warnings = 2
        case connections = 3
        case authentication = 4

        var localizedKey: String {
            switch self {
            case .all: return "All Log Entries"
            case .errors: return "Errors"
            case .warnings: return "Warnings"
            case .connections: return "Connections"
            case .authentication: return "Authentication"
            }
        }

        var keywords: [String] {
            switch self {
            case .all: return []
            case .errors:
                return ["error", "failed", "failure", "rejected", "denied", "invalid",
                        "timeout", "timed out", "could not", "exception", "crash", "aborted",
                        "ended before", "ended early"]
            case .warnings:
                return ["warning", "warn:", "warn ", "retry", "reconnect", "deprecated",
                        "truncated", "rate limit"]
            case .connections:
                return ["connect", "disconnect", "session", "socket", "tcp", "handshake"]
            case .authentication:
                return ["login", "log in", "logged in", "authenticat", "password",
                        "account", "anonymous", "guest", "credential"]
            }
        }
    }

    struct Result {
        let lines: [String]
        let total: Int
        var visibleCount: Int { lines.count }
        var text: String { lines.joined(separator: "\n") }
    }

    static func apply(to text: String, category: Category, query: String) -> Result {
        let source = text.split(whereSeparator: \.isNewline).map(String.init)
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard category != .all || !tokens.isEmpty else {
            return Result(lines: source, total: source.count)
        }
        let filtered = source.filter { line in
            let hasCategory = category == .all || category.keywords.contains { keyword in
                line.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            guard hasCategory else { return false }
            return tokens.allSatisfy { token in
                line.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return Result(lines: filtered, total: source.count)
    }
}
