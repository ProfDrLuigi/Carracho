import CryptoKit
import Foundation

enum LocalAvatarState: Equatable {
    case unconfigured
    case none
    case avatar(Data)
}

struct LocalAvatarIdentity: Hashable {
    var host: String
    var port: UInt16
    var login: String

    var canonicalValue: String {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let l = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(h):\(port)|\(l)"
    }
}

enum LocalAvatarStoreError: LocalizedError {
    case invalidPNG
    case avatarTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPNG: return L("The local avatar is not a PNG image.")
        case let .avatarTooLarge(bytes): return LF("The local avatar is too large for the Carracho protocol (%@ bytes).", String(bytes))
        }
    }
}

struct LocalAvatarStore {
    private static let pngSignature = Data([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A])
    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let manager = FileManager.default
            let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? manager.temporaryDirectory
            self.directoryURL = base
                .appendingPathComponent("Carracho", isDirectory: true)
                .appendingPathComponent("Client", isDirectory: true)
                .appendingPathComponent("Avatars", isDirectory: true)
        }
    }

    func state(for identity: LocalAvatarIdentity) throws -> LocalAvatarState {
        let p = paths(for: identity)
        let fm = FileManager.default
        if fm.fileExists(atPath: p.png.path) {
            let data = try Data(contentsOf: p.png)
            try validatePNG(data)
            return .avatar(data)
        }
        if fm.fileExists(atPath: p.none.path) { return .none }
        return .unconfigured
    }

    func save(_ data: Data, for identity: LocalAvatarIdentity) throws {
        try ensureDirectory()
        let p = paths(for: identity)
        let fm = FileManager.default
        if data.isEmpty {
            try? fm.removeItem(at: p.png)
            try Data().write(to: p.none, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p.none.path)
            return
        }
        try validatePNG(data)
        try data.write(to: p.png, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p.png.path)
        try? fm.removeItem(at: p.none)
    }

    func removeLocalState(for identity: LocalAvatarIdentity) throws {
        let p = paths(for: identity)
        let fm = FileManager.default
        if fm.fileExists(atPath: p.png.path) { try fm.removeItem(at: p.png) }
        if fm.fileExists(atPath: p.none.path) { try fm.removeItem(at: p.none) }
    }

    func avatarFileURL(for identity: LocalAvatarIdentity) -> URL { paths(for: identity).png }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func validatePNG(_ data: Data) throws {
        guard data.count <= Int(UInt16.max) else { throw LocalAvatarStoreError.avatarTooLarge(data.count) }
        guard data.count >= Self.pngSignature.count,
              data.prefix(Self.pngSignature.count) == Self.pngSignature else { throw LocalAvatarStoreError.invalidPNG }
    }

    private func paths(for identity: LocalAvatarIdentity) -> (png: URL, none: URL) {
        let digest = SHA256.hash(data: Data(identity.canonicalValue.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return (directoryURL.appendingPathComponent(key).appendingPathExtension("png"),
                directoryURL.appendingPathComponent(key).appendingPathExtension("none"))
    }
}
