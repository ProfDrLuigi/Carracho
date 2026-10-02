import Foundation

enum CarrachoBuildInfo {
    static let version: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }()

    static let build: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }()

    static var clientSoftwareName: String {
        "Carracho \(version)"
    }

    static var serverSoftwareName: String {
        "Carracho Server \(version)"
    }

    static var botRSSUserAgent: String {
        "Carracho-Bot-RSS/\(version)"
    }
}
