import Foundation

nonisolated enum ServerAccountMode: String, Codable, CaseIterable {
    case guest
    case accountHolder
    case administrator

    var displayName: String {
        switch self {
        case .guest: return "Guest"
        case .accountHolder: return "Account Holder"
        case .administrator: return "Administrator"
        }
    }
}

enum ServerPersonalDirectoryMode: String, Codable, CaseIterable {
    case none
    case nestedInRoot
    case rootDirectory
}

enum ServerAuthenticationMode: String, Codable, CaseIterable {
    case legacyCompatible
    case modernOnly

    var displayName: String {
        switch self {
        case .legacyCompatible: return "Legacy compatible"
        case .modernOnly: return "Modern only"
        }
    }
}

struct ServerAuthenticationSettings: Codable, Equatable {
    var mode: ServerAuthenticationMode = .legacyCompatible
}

/// Runtime settings that are persisted in `server.db` for cross-platform parity.
/// The standalone server's JSON configuration is authoritative for these values at startup.
struct ServerRuntimeSettings: Codable, Equatable {
    var filesRoot: String = ""
    /// Optional alternate Files root used only by Classic/legacy transport sessions.
    /// Empty means legacy sessions use `filesRoot` like modern sessions.
    var legacyFilesRoot: String = ""
    var uploadBandwidthLimitBytesPerSecond: UInt64 = 0
    var searchIndexExclusions: [String] = []

    private enum CodingKeys: String, CodingKey {
        case filesRoot, legacyFilesRoot, uploadBandwidthLimitBytesPerSecond, searchIndexExclusions
    }

    init(filesRoot: String = "", legacyFilesRoot: String = "", uploadBandwidthLimitBytesPerSecond: UInt64 = 0,
         searchIndexExclusions: [String] = []) {
        self.filesRoot = filesRoot
        self.legacyFilesRoot = legacyFilesRoot
        self.uploadBandwidthLimitBytesPerSecond = uploadBandwidthLimitBytesPerSecond
        self.searchIndexExclusions = searchIndexExclusions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filesRoot = try c.decodeIfPresent(String.self, forKey: .filesRoot) ?? ""
        legacyFilesRoot = try c.decodeIfPresent(String.self, forKey: .legacyFilesRoot) ?? ""
        uploadBandwidthLimitBytesPerSecond = try c.decodeIfPresent(UInt64.self, forKey: .uploadBandwidthLimitBytesPerSecond) ?? 0
        searchIndexExclusions = try c.decodeIfPresent([String].self, forKey: .searchIndexExclusions) ?? []
    }
}

nonisolated enum ServerPermission: Int, Codable, CaseIterable, Hashable {
    case download = 0x0a
    case upload = 0x0b
    case uploadAnywhere = 0x0c
    case viewDropboxes = 0x0d
    case changeFolderMode = 0x0e
    case moveFiles = 0x0f
    case deleteFiles = 0x10
    case renameFiles = 0x11
    case commentFiles = 0x12
    case createFolders = 0x13
    case moveFolders = 0x14
    case renameFolders = 0x15
    case deleteFolders = 0x16
    case commentFolders = 0x17
    case disconnectUsers = 0x18
    case extendedUserInfo = 0x19
    case joinChatRooms = 0x1c
    case manageAccounts = 0x21
    case manageNewsgroups = 0x22
    case viewServerLog = 0x23
    case editServerInformation = 0x24
    case editAdvancedSettings = 0x25
    case manageTransfers = 0x26
    case emptyServerTrash = 0x27
    case broadcastMessages = 0x28
    case banUsers = 0x2a
    case editServerAgreement = 0x2c
    case viewStatistics = 0x2d
    case editTrackers = 0x2e
    case searchFiles = 0x2f
    case postFlatNews = 0x30
    /// Carracho extension. Classic has no account-level permission for threaded News posting.
    case postNews = 0x31

    var isClassicPermission: Bool { self != .postNews }
}


nonisolated struct ServerAccountGroup: Codable, Equatable, Identifiable {
    static let defaultFilesRootName = "Allgemein"

    var id: UUID
    var name: String
    /// 0xRRGGBB. Alpha is always treated as fully opaque by the client.
    var colorRGB: UInt32
    /// Compatibility class required by the Classic protocol/news ACL model. The modern server
    /// intentionally keeps exactly the same three classes: Guest, Account Holder and Administrator.
    var legacyMode: ServerAccountMode
    var permissions: Set<ServerPermission>
    /// Virtual Files root assigned to members of this permission group. An empty path means
    /// the configured server Files root (shown to users as "Allgemein"). Non-empty paths are
    /// always relative to that root and are never allowed to escape it.
    var filesRootPath: String
    /// User-visible name for the virtual Files root. For the global root the effective name is
    /// always "Allgemein"; the three fixed account groups can choose their own scoped root name.
    var filesRootName: String

    init(id: UUID = UUID(), name: String, colorRGB: UInt32 = 0x0A84FF,
         legacyMode: ServerAccountMode = .accountHolder,
         permissions: Set<ServerPermission> = [], filesRootPath: String = "",
         filesRootName: String = ServerAccountGroup.defaultFilesRootName) {
        self.id = id
        self.name = name
        self.colorRGB = colorRGB & 0x00ff_ffff
        self.legacyMode = legacyMode
        self.permissions = permissions
        self.filesRootPath = filesRootPath
        self.filesRootName = filesRootName
    }

    var effectiveFilesRootName: String {
        filesRootPath.isEmpty ? Self.defaultFilesRootName : filesRootName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorRGB, legacyMode, permissions, filesRootPath, filesRootName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorRGB = try c.decode(UInt32.self, forKey: .colorRGB)
        legacyMode = try c.decode(ServerAccountMode.self, forKey: .legacyMode)
        permissions = try c.decode(Set<ServerPermission>.self, forKey: .permissions)
        filesRootPath = try c.decodeIfPresent(String.self, forKey: .filesRootPath) ?? ""
        filesRootName = try c.decodeIfPresent(String.self, forKey: .filesRootName) ?? Self.defaultFilesRootName
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(colorRGB, forKey: .colorRGB)
        try c.encode(legacyMode, forKey: .legacyMode)
        try c.encode(permissions, forKey: .permissions)
        try c.encode(filesRootPath, forKey: .filesRootPath)
        try c.encode(effectiveFilesRootName, forKey: .filesRootName)
    }
}

struct ServerAccount: Codable, Equatable, Identifiable {
    var id: UUID
    var login: String
    var name: String
    /// Password-equivalent material required only by the reconstructed legacy challenge/response path.
    /// It is removed from persisted state when authentication mode is `modernOnly`.
    var legacyPassword: String?
    /// Salted, iterated verifier used by the modern authentication path.
    var passwordVerifier: ServerPasswordVerifier?
    var mode: ServerAccountMode
    /// One of the three fixed legacy-compatible account classes.
    var groupID: UUID?
    var personalDirectory: ServerPersonalDirectoryMode
    /// Effective account permissions. Group changes follow members that still match the prior defaults; explicit per-account overrides are preserved.
    var permissions: Set<ServerPermission>
    /// Optional per-account nickname color override. Persisted modern accounts are normalized to a value.
    var colorRGB: UInt32?
    /// Explicit inheritance markers. Missing values are treated as inherited for pre-1.0.2 states,
    /// allowing a later group edit to repair accounts that were stranded on stale copied defaults.
    var permissionsOverrideGroupDefaults: Bool?
    var colorOverridesGroupDefault: Bool?
    var createdAt: Date
    var modifiedAt: Date
    var lastLoginAt: Date?
    var email: String?
    var aboutMe: String?
    var picture: Data?
    /// Internal/server-owned accounts can be fully administered like normal accounts while
    /// remaining impossible to authenticate over a network control connection.
    var localLoginOnly: Bool?
    /// Opt-in for account messages that may be queued while this account is offline.
    /// Optional preserves compatibility with older persisted states; nil means the historical default (enabled).
    var acceptsOfflineMessages: Bool?
    /// Last nickname published by this account, used to present a friendly recipient name even while offline.
    var lastNickname: String?

    init(id: UUID = UUID(), login: String, name: String = "", legacyPassword: String? = nil,
         passwordVerifier: ServerPasswordVerifier? = nil,
         mode: ServerAccountMode = .guest,
         groupID: UUID? = nil,
         personalDirectory: ServerPersonalDirectoryMode = .none,
         permissions: Set<ServerPermission> = [], colorRGB: UInt32? = nil,
         permissionsOverrideGroupDefaults: Bool? = nil, colorOverridesGroupDefault: Bool? = nil,
         createdAt: Date = Date(), modifiedAt: Date = Date(), lastLoginAt: Date? = nil,
         email: String? = nil, aboutMe: String? = nil, picture: Data? = nil,
         localLoginOnly: Bool? = nil, acceptsOfflineMessages: Bool? = true, lastNickname: String? = nil) {
        self.id = id
        self.login = login
        self.name = name
        self.legacyPassword = legacyPassword
        self.passwordVerifier = passwordVerifier
        self.mode = mode
        self.groupID = groupID
        self.personalDirectory = personalDirectory
        self.permissions = permissions
        self.colorRGB = colorRGB.map { $0 & 0x00ff_ffff }
        self.permissionsOverrideGroupDefaults = permissionsOverrideGroupDefaults
        self.colorOverridesGroupDefault = colorOverridesGroupDefault
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastLoginAt = lastLoginAt
        self.email = email
        self.aboutMe = aboutMe
        self.picture = picture
        self.localLoginOnly = localLoginOnly
        self.acceptsOfflineMessages = acceptsOfflineMessages
        self.lastNickname = lastNickname
    }

    var offlineMessagesEnabled: Bool { acceptsOfflineMessages != false }
    var isLocalLoginOnly: Bool { localLoginOnly == true }
}

struct ServerNewsgroupAccess: Codable, Equatable {
    var administratorsRead = true
    var administratorsPost = true
    var accountHoldersRead = true
    var accountHoldersPost = true
    var guestsRead = true
    var guestsPost = false
}

struct ServerNewsgroup: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var articleCount: UInt32
    var expireAfterSeconds: UInt32
    var access: ServerNewsgroupAccess

    init(id: UUID = UUID(), name: String, articleCount: UInt32 = 0,
         expireAfterSeconds: UInt32 = UInt32.max,
         access: ServerNewsgroupAccess = ServerNewsgroupAccess()) {
        self.id = id
        self.name = name
        self.articleCount = articleCount
        self.expireAfterSeconds = expireAfterSeconds
        self.access = access
    }
}

struct ServerIdentity: Codable, Equatable {
    var name = "Carracho Server"
    var operatorName = "unknown"
    var location = "unknown"
    var description = ""
    var bannerURL = ""
    var bannerData: Data? = nil
}

struct ServerTrackerSetting: Codable, Equatable {
    /// Carracho uses one otherwise-reserved Classic tracker bit to persist a
    /// per-tracker disable flag. Zero remains the legacy/default state, so every
    /// existing tracker continues to be active until explicitly disabled.
    private static let disabledFlag: UInt32 = 0x8000_0000

    var name: String
    var address: String
    var reservedString: String = ""
    var reservedValue: UInt32 = 0

    var isRegistrationEnabled: Bool {
        get { (reservedValue & Self.disabledFlag) == 0 }
        set {
            if newValue {
                reservedValue &= ~Self.disabledFlag
            } else {
                reservedValue |= Self.disabledFlag
            }
        }
    }
}

struct ServerIPRestriction: Codable, Equatable {
    var network: Data
    var mask: Data
    var deny: Bool
    var reserved: UInt8 = 0
}

struct ServerAdvancedSettings: Codable, Equatable {
    var controlPort: UInt16 = 6700
    var maxConnections: UInt16 = 100
    var maxConnectionsPerIP: UInt16 = 5
    var maxSimultaneousFileTransfers: UInt16 = 20
    var maxFileTransfersPerUser: UInt16 = 1
    var maxFolderDownloadDepth: UInt16 = 8
    var newsExpirationHour: UInt8 = 0
    var newsExpirationMinute: UInt8 = 0
    var ipRestrictions: [ServerIPRestriction] = []
    var trackers: [ServerTrackerSetting] = []
    var trackerAdvertisementFlags: UInt32 = 0
    var trackerDescription: String = ""

    private enum CodingKeys: String, CodingKey {
        case controlPort, maxConnections, maxConnectionsPerIP, maxSimultaneousFileTransfers
        case maxFileTransfersPerUser, maxFolderDownloadDepth, newsExpirationHour, newsExpirationMinute
        case ipRestrictions, trackers, trackerAdvertisementFlags, trackerDescription
    }

    init(controlPort: UInt16 = 6700, maxConnections: UInt16 = 100, maxConnectionsPerIP: UInt16 = 5,
         maxSimultaneousFileTransfers: UInt16 = 20, maxFileTransfersPerUser: UInt16 = 1,
         maxFolderDownloadDepth: UInt16 = 8, newsExpirationHour: UInt8 = 0, newsExpirationMinute: UInt8 = 0,
         ipRestrictions: [ServerIPRestriction] = [], trackers: [ServerTrackerSetting] = [],
         trackerAdvertisementFlags: UInt32 = 0, trackerDescription: String = "") {
        self.controlPort = controlPort
        self.maxConnections = maxConnections
        self.maxConnectionsPerIP = maxConnectionsPerIP
        self.maxSimultaneousFileTransfers = maxSimultaneousFileTransfers
        self.maxFileTransfersPerUser = maxFileTransfersPerUser
        self.maxFolderDownloadDepth = maxFolderDownloadDepth
        self.newsExpirationHour = newsExpirationHour
        self.newsExpirationMinute = newsExpirationMinute
        self.ipRestrictions = ipRestrictions
        self.trackers = trackers
        self.trackerAdvertisementFlags = trackerAdvertisementFlags
        self.trackerDescription = trackerDescription
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controlPort = try c.decodeIfPresent(UInt16.self, forKey: .controlPort) ?? 6700
        maxConnections = try c.decodeIfPresent(UInt16.self, forKey: .maxConnections) ?? 100
        maxConnectionsPerIP = try c.decodeIfPresent(UInt16.self, forKey: .maxConnectionsPerIP) ?? 5
        maxSimultaneousFileTransfers = try c.decodeIfPresent(UInt16.self, forKey: .maxSimultaneousFileTransfers) ?? 20
        maxFileTransfersPerUser = try c.decodeIfPresent(UInt16.self, forKey: .maxFileTransfersPerUser) ?? 1
        maxFolderDownloadDepth = try c.decodeIfPresent(UInt16.self, forKey: .maxFolderDownloadDepth) ?? 8
        newsExpirationHour = try c.decodeIfPresent(UInt8.self, forKey: .newsExpirationHour) ?? 0
        newsExpirationMinute = try c.decodeIfPresent(UInt8.self, forKey: .newsExpirationMinute) ?? 0
        ipRestrictions = try c.decodeIfPresent([ServerIPRestriction].self, forKey: .ipRestrictions) ?? []
        trackers = try c.decodeIfPresent([ServerTrackerSetting].self, forKey: .trackers) ?? []
        trackerAdvertisementFlags = try c.decodeIfPresent(UInt32.self, forKey: .trackerAdvertisementFlags) ?? 0
        trackerDescription = try c.decodeIfPresent(String.self, forKey: .trackerDescription) ?? ""
    }
}

struct ServerAgreement: Codable, Equatable {
    var enabled = false
    var text = ""
}

struct ServerStatistics: Codable, Equatable {
    var hits: UInt64 = 0
    var connectionPeak: UInt64 = 0
    var incorrectLogins: UInt64 = 0
    var adminsConnected: UInt64 = 0
    var accountHoldersConnected: UInt64 = 0
    var guestsConnected: UInt64 = 0
    var downloadsInProgress: UInt64 = 0
    var totalDownloads: UInt64 = 0
    var uploadsInProgress: UInt64 = 0
    var totalUploads: UInt64 = 0
    var totalMessages: UInt64 = 0
}

struct ServerState: Codable, Equatable {
    static let currentFormatVersion = 4

    var formatVersion: Int
    var authentication: ServerAuthenticationSettings
    var identity: ServerIdentity
    var advanced: ServerAdvancedSettings
    var runtime: ServerRuntimeSettings
    var agreement: ServerAgreement
    var accountGroups: [ServerAccountGroup]
    var accounts: [ServerAccount]
    var newsgroups: [ServerNewsgroup]
    var statistics: ServerStatistics

    init(formatVersion: Int = currentFormatVersion,
         authentication: ServerAuthenticationSettings = ServerAuthenticationSettings(),
         identity: ServerIdentity, advanced: ServerAdvancedSettings,
         runtime: ServerRuntimeSettings = ServerRuntimeSettings(), agreement: ServerAgreement,
         accountGroups: [ServerAccountGroup] = [], accounts: [ServerAccount],
         newsgroups: [ServerNewsgroup], statistics: ServerStatistics) {
        self.formatVersion = formatVersion
        self.authentication = authentication
        self.identity = identity
        self.advanced = advanced
        self.runtime = runtime
        self.agreement = agreement
        self.accountGroups = accountGroups
        self.accounts = accounts
        self.newsgroups = newsgroups
        self.statistics = statistics
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, authentication, identity, advanced, runtime, agreement, accountGroups, accounts, newsgroups, statistics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        authentication = try container.decodeIfPresent(ServerAuthenticationSettings.self, forKey: .authentication)
            ?? ServerAuthenticationSettings(mode: .legacyCompatible)
        identity = try container.decode(ServerIdentity.self, forKey: .identity)
        advanced = try container.decode(ServerAdvancedSettings.self, forKey: .advanced)
        runtime = try container.decodeIfPresent(ServerRuntimeSettings.self, forKey: .runtime) ?? ServerRuntimeSettings()
        agreement = try container.decode(ServerAgreement.self, forKey: .agreement)
        accountGroups = try container.decodeIfPresent([ServerAccountGroup].self, forKey: .accountGroups) ?? []
        accounts = try container.decode([ServerAccount].self, forKey: .accounts)
        newsgroups = try container.decode([ServerNewsgroup].self, forKey: .newsgroups)
        statistics = try container.decode(ServerStatistics.self, forKey: .statistics)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(authentication, forKey: .authentication)
        try container.encode(identity, forKey: .identity)
        try container.encode(advanced, forKey: .advanced)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(agreement, forKey: .agreement)
        try container.encode(accountGroups, forKey: .accountGroups)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(newsgroups, forKey: .newsgroups)
        try container.encode(statistics, forKey: .statistics)
    }

    static let builtInAdministratorGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let builtInMemberGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let builtInGuestGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    /// Stable identity of the built-in localhost-only Bot account. Its login/name/avatar remain editable.
    static let localBotAccountID = UUID(uuidString: "00000000-0000-0000-0000-00000000B070")!

    static var initialAccountGroups: [ServerAccountGroup] {
        [
            ServerAccountGroup(id: builtInAdministratorGroupID, name: "Administrator", colorRGB: 0xFF9F0A,
                               legacyMode: .administrator, permissions: Set(ServerPermission.allCases)),
            ServerAccountGroup(id: builtInMemberGroupID, name: "Account Holder", colorRGB: 0x0A84FF,
                               legacyMode: .accountHolder, permissions: [.download, .upload, .joinChatRooms, .searchFiles, .postNews]),
            ServerAccountGroup(id: builtInGuestGroupID, name: "Guest", colorRGB: 0x8E8E93,
                               legacyMode: .guest, permissions: [.download, .joinChatRooms, .searchFiles]),
        ]
    }

    static func builtInAccountGroupID(for mode: ServerAccountMode) -> UUID {
        switch mode {
        case .administrator: return builtInAdministratorGroupID
        case .accountHolder: return builtInMemberGroupID
        case .guest: return builtInGuestGroupID
        }
    }

    static func builtInAccountGroupName(for mode: ServerAccountMode) -> String {
        switch mode {
        case .administrator: return "Administrator"
        case .accountHolder: return "Account Holder"
        case .guest: return "Guest"
        }
    }

    static let builtInAccountGroupOrder: [UUID] = [
        builtInAdministratorGroupID, builtInMemberGroupID, builtInGuestGroupID,
    ]

    static var initial: ServerState {
        let groups = initialAccountGroups
        return ServerState(
            authentication: ServerAuthenticationSettings(mode: .legacyCompatible),
            identity: ServerIdentity(),
            advanced: ServerAdvancedSettings(),
            runtime: ServerRuntimeSettings(),
            agreement: ServerAgreement(),
            accountGroups: groups,
            accounts: [
                ServerAccount(login: "admin", name: "Administrator", legacyPassword: "", mode: .administrator,
                              groupID: builtInAdministratorGroupID, permissions: Set(ServerPermission.allCases), colorRGB: 0xFF9F0A),
                ServerAccount(login: "anonymous", name: "Guest", legacyPassword: "", mode: .guest,
                              groupID: builtInGuestGroupID, permissions: [.download, .joinChatRooms, .searchFiles], colorRGB: 0x8E8E93)
            ],
            newsgroups: [],
            statistics: ServerStatistics()
        )
    }

    func accountGroup(for account: ServerAccount) -> ServerAccountGroup? {
        account.groupID.flatMap { id in accountGroups.first(where: { $0.id == id }) }
    }

    func accountColorRGB(for account: ServerAccount) -> UInt32? {
        account.colorRGB ?? accountGroup(for: account)?.colorRGB
    }
}
