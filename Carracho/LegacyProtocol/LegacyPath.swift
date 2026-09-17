import Foundation

enum LegacyDirectoryFlags {
    /// Classic Toolbox BitSet/BitTst index 0 on a big-endian UInt16.
    static let folder: UInt16 = 0x8000
    /// Classic special folder mode bit 1 (upload folder).
    static let uploadFolder: UInt16 = 0x4000
    /// Classic special folder mode bit 2 (drop box).
    static let dropBox: UInt16 = 0x2000
    static let specialFolderModeMask: UInt16 = uploadFolder | dropBox
}

enum LegacyFolderMode: Int, CaseIterable {
    case normal = 0
    case uploadFolder = 1
    case dropBox = 2

    init(flags: UInt16) {
        if flags & LegacyDirectoryFlags.dropBox != 0 { self = .dropBox }
        else if flags & LegacyDirectoryFlags.uploadFolder != 0 { self = .uploadFolder }
        else { self = .normal }
    }

    var flags: UInt16 {
        switch self {
        case .normal: return 0
        case .uploadFolder: return LegacyDirectoryFlags.uploadFolder
        case .dropBox: return LegacyDirectoryFlags.dropBox
        }
    }
}

enum LegacyPath {
    static let separator: UInt8 = 0x01
    static let maximumWireLength = 0x1000

    static func child(parent: Data, name: Data) throws -> Data {
        guard !name.isEmpty, !name.contains(separator) else {
            throw LegacyProtocolError.invalidRecord("legacy path component is empty or contains separator 0x01")
        }
        var result = parent
        if !result.isEmpty { result.append(separator) }
        result.append(name)
        guard result.count <= maximumWireLength else {
            throw LegacyProtocolError.invalidLength("legacy path exceeds 4096-byte limit")
        }
        return result
    }

    /// Returns nil when the supplied path is already the root-level path.
    static func parent(of path: Data) -> Data? {
        guard !path.isEmpty else { return nil }
        guard let separatorIndex = path.lastIndex(of: separator) else { return Data() }
        return path.prefix(upTo: separatorIndex)
    }

    static func displayString(_ path: Data) -> String {
        guard !path.isEmpty else { return "/" }
        let components = path.split(separator: separator, omittingEmptySubsequences: false)
        let names = components.map { CarrachoTextWire.string(from: Data($0)) }
        return "/" + names.joined(separator: "/")
    }

    /// Human-readable final component only. Useful in compact UI such as the transfer monitor,
    /// where exposing the complete remote path adds noise without identifying the transfer better.
    static func displayName(_ path: Data) -> String {
        guard !path.isEmpty else { return "/" }
        guard let leaf = path.split(separator: separator, omittingEmptySubsequences: false).last else { return "/" }
        return CarrachoTextWire.string(from: Data(leaf))
    }
}

extension LegacyDirectoryEntry {
    private static let symbolicLinkType: UInt32 = 0x53594D4C // SYML
    private static let carrachoCreator: UInt32 = 0x43617253 // CarS
    var isFolder: Bool { (flags & LegacyDirectoryFlags.folder) != 0 }
    var isUploadFolder: Bool { isFolder && (flags & LegacyDirectoryFlags.uploadFolder) != 0 }
    var isDropBox: Bool { isFolder && (flags & LegacyDirectoryFlags.dropBox) != 0 }
    var folderMode: LegacyFolderMode { LegacyFolderMode(flags: flags) }
    var isSymbolicLink: Bool { fileType == Self.symbolicLinkType && creator == Self.carrachoCreator }
}
