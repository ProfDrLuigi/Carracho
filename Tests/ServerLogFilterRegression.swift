import Foundation

@main
struct ServerLogFilterRegression {
    static func main() {
        let original = [
            "2026-10-08 Connection from 83.106.128.146 closed",
            "2026-10-08 Authenticated control read ended before frame header for user 4174",
            "2026-10-08 User 4174 logged in as Müller from 83.106.128.146",
            "2026-10-08 WARNING: retry scheduled",
            "2026-10-08 Rejected authenticated control tag for user 9000",
            "2026-10-08 regular server status"
        ].joined(separator: "\n")

        let full = ServerLogFilter.apply(to: original, category: .all, query: "")
        precondition(full.total == 6 && full.visibleCount == 6)
        precondition(full.text == original)

        let byIP = ServerLogFilter.apply(to: original, category: .all, query: "83.106.128.146")
        precondition(byIP.total == 6 && byIP.visibleCount == 2)
        precondition(byIP.lines[0].contains("Connection") && byIP.lines[1].contains("Müller"))

        let caseAndDiacritics = ServerLogFilter.apply(to: original, category: .authentication,
                                                     query: "MULLER 4174")
        precondition(caseAndDiacritics.visibleCount == 1)
        precondition(caseAndDiacritics.lines[0].contains("Müller"))

        let errors = ServerLogFilter.apply(to: original, category: .errors, query: "")
        precondition(errors.visibleCount == 2)
        precondition(errors.lines[0].contains("ended before"))
        precondition(errors.lines[1].contains("Rejected"))

        let connections = ServerLogFilter.apply(to: original, category: .connections, query: "closed")
        precondition(connections.visibleCount == 1)

        let warnings = ServerLogFilter.apply(to: original, category: .warnings, query: "RETRY")
        precondition(warnings.visibleCount == 1)

        let noMatches = ServerLogFilter.apply(to: original, category: .all, query: "neverexistent")
        precondition(noMatches.visibleCount == 0 && noMatches.total == 6 && noMatches.text.isEmpty)

        let empty = ServerLogFilter.apply(to: "", category: .errors, query: "test")
        precondition(empty.total == 0 && empty.visibleCount == 0)
        precondition(original.contains("regular server status"), "Source text must remain unchanged")
        print("PASS: all/error/warning/connection/login categories, case/diacritic-insensitive searches")
        print("PASS: AND tokens, matching counts, source retention, no-match and empty-log cases")
    }
}
