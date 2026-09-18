import Cocoa
import QuickLookUI

final class ServerBookmarkEditorWindowController: NSWindowController, NSWindowDelegate {
    private let nameField = NSTextField(string: "")
    private let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "")
    private let loginField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let nicknameField = NSTextField(string: "")
    private let statusField = NSTextField(string: "")
    private let autoReconnect = NSButton(checkboxWithTitle: L("Auto reconnect after connection loss"), target: nil, action: nil)
    private let connectAtLaunch = NSButton(checkboxWithTitle: L("Connect at app launch"), target: nil, action: nil)
    private let acceptsOfflineMessages = NSButton(checkboxWithTitle: L("Allow offline messages"), target: nil, action: nil)
    private let isNew: Bool
    private var didFinish = false

    var onSave: ((ViewController.ServerBookmarkDraft) -> Void)?
    var onDelete: (() -> Void)?
    var onChangePassword: (() -> Void)?
    var onFinish: (() -> Void)?

    init(draft: ViewController.ServerBookmarkDraft,
         isNew: Bool,
         globalNicknameHint: String,
         globalStatusHint: String,
         canChangeAccountPassword: Bool) {
        self.isNew = isNew
        let rowCount = canChangeAccountPassword ? 8 : 7
        let formHeight = CGFloat(rowCount * 30 + max(0, rowCount - 1) * 8)
        let windowHeight = 22 + 28 + 18 + formHeight + 16 + 76 + 18 + 32 + 18
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = isNew ? L("Add Server Bookmark") : L("Edit Server Bookmark")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        nameField.stringValue = draft.name
        hostField.stringValue = draft.host
        portField.stringValue = draft.port
        loginField.stringValue = draft.login
        passwordField.stringValue = draft.password
        nicknameField.stringValue = draft.nickname
        statusField.stringValue = draft.statusMessage
        autoReconnect.state = draft.autoReconnect ? .on : .off
        connectAtLaunch.state = draft.connectAtLaunch ? .on : .off
        acceptsOfflineMessages.state = draft.acceptsOfflineMessages ? .on : .off

        buildInterface(in: window,
                       globalNicknameHint: globalNicknameHint,
                       globalStatusHint: globalStatusHint,
                       canChangeAccountPassword: canChangeAccountPassword)
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface(in window: NSWindow,
                                globalNicknameHint: String,
                                globalStatusHint: String,
                                canChangeAccountPassword: Bool) {
        let root = CarrachoBackgroundView()
        root.fillColor = CarrachoTheme.canvas
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = NSTextField(labelWithString: isNew ? L("Add Server Bookmark") : L("Edit Server Bookmark"))
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.alignment = .center

        nameField.placeholderString = L("My Carracho Server")
        hostField.placeholderString = "server.example.com"
        passwordField.placeholderString = L("Stored securely in Keychain")
        nicknameField.placeholderString = LF("General: %@", globalNicknameHint)
        statusField.placeholderString = globalStatusHint.isEmpty ? L("General status (empty)") : LF("General: %@", globalStatusHint)
        nicknameField.toolTip = L("Leave empty to use the nickname from Carracho Settings. A value here overrides it only for this server.")
        statusField.toolTip = L("Leave empty to use the status from Carracho Settings. A value here overrides it only for this server.")
        acceptsOfflineMessages.toolTip = L("When disabled, this account is hidden from other users’ offline-message recipient lists on this server.")

        for field in [nameField, hostField, portField, loginField, passwordField, nicknameField, statusField] {
            field.controlSize = .regular
            field.font = .systemFont(ofSize: 13)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }

        var rows: [NSView] = [
            formRow(L("Name"), control: nameField),
            formRow(L("Server"), control: hostField),
            formRow(L("Port"), control: portField),
            formRow(L("Login"), control: loginField),
            formRow(isNew ? L("Password") : L("Saved Password"), control: passwordField),
        ]
        if canChangeAccountPassword {
            let change = NSButton(title: L("Change Account Password…"), target: self, action: #selector(changePasswordPressed(_:)))
            change.bezelStyle = .rounded
            change.controlSize = .regular
            change.setContentHuggingPriority(.defaultLow, for: .horizontal)
            change.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rows.append(formRow(L("Account Password"), control: change))
        }
        rows += [
            formRow(L("Nickname Override"), control: nicknameField),
            formRow(L("Status Override"), control: statusField),
        ]

        let form = NSStackView(views: rows)
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false
        for row in rows { row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }

        for option in [autoReconnect, connectAtLaunch, acceptsOfflineMessages] {
            option.font = .systemFont(ofSize: 13)
            option.translatesAutoresizingMaskIntoConstraints = false
        }
        let options = NSStackView(views: [autoReconnect, connectAtLaunch, acceptsOfflineMessages])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 5
        options.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: isNew ? L("Add") : L("Save"), target: self, action: #selector(savePressed(_:)))
        CarrachoTheme.applyPrimaryButtonStyle(save)
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelPressed(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        var buttonViews: [NSView] = []
        if !isNew {
            let delete = NSButton(title: L("Delete"), target: self, action: #selector(deletePressed(_:)))
            delete.bezelStyle = .rounded
            delete.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
            buttonViews.append(delete)
        }
        for button in [cancel, save] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
            buttonViews.append(button)
        }
        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for child in [title, form, options, buttons] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),

            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            form.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),

            options.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            options.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            options.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 16),
            options.heightAnchor.constraint(equalToConstant: 76),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 18),
            buttons.heightAnchor.constraint(equalToConstant: 32),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
    }

    private func formRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 146).isActive = true

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -(146 + 12)).isActive = true
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return row
    }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self.nameField)
            self.nameField.selectText(nil)
        }
    }

    @objc private func savePressed(_ sender: Any?) {
        let draft = ViewController.ServerBookmarkDraft(
            name: nameField.stringValue,
            host: hostField.stringValue,
            port: portField.stringValue,
            login: loginField.stringValue,
            password: passwordField.stringValue,
            nickname: nicknameField.stringValue,
            statusMessage: statusField.stringValue,
            autoReconnect: autoReconnect.state == .on,
            connectAtLaunch: connectAtLaunch.state == .on,
            acceptsOfflineMessages: acceptsOfflineMessages.state == .on
        )
        dismiss()
        onSave?(draft)
    }

    @objc private func deletePressed(_ sender: Any?) {
        dismiss()
        onDelete?()
    }

    @objc private func cancelPressed(_ sender: Any?) { dismiss() }
    @objc private func changePasswordPressed(_ sender: Any?) { onChangePassword?() }

    private func dismiss() {
        guard !didFinish else { return }
        didFinish = true
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        else { window?.orderOut(nil) }
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?()
    }
}

final class ViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSFilePromiseProviderDelegate, NSWindowDelegate, NSMenuDelegate {
    enum Workspace: Int, CaseIterable {
        case overview, conferences, files, transfers, news, messageCenter
        case accounts, bot, newsgroups, serverInfo, trackers, serverLog, events, advanced, agreement, statistics
        case trackerBrowser

        var title: String {
            switch self {
            case .overview: return L("Overview")
            case .conferences: return L("Conferences")
            case .files: return L("Files")
            case .transfers: return L("Transfers")
            case .news: return L("News")
            case .messageCenter: return L("Message Center")
            case .accounts: return L("Accounts")
            case .bot: return L("Bot")
            case .newsgroups: return L("News Categories")
            case .serverInfo: return L("Server Info")
            case .trackers: return L("Trackers")
            case .serverLog: return L("Server Log")
            case .events: return L("Events")
            case .advanced: return L("Advanced")
            case .agreement: return L("Agreement")
            case .statistics: return L("Statistics")
            case .trackerBrowser: return L("Tracker")
            }
        }

        var deckIdentifier: String {
            switch self {
            case .overview: return "overview"
            case .conferences: return "conferences"
            case .files: return "files"
            case .transfers: return "transfers"
            case .news: return "news"
            case .messageCenter: return "messageCenter"
            case .accounts: return "accounts"
            case .bot: return "bot"
            case .newsgroups: return "newsgroups"
            case .serverInfo: return "serverInfo"
            case .trackers: return "trackers"
            case .serverLog: return "serverLog"
            case .events: return "events"
            case .advanced: return "advanced"
            case .agreement: return "agreement"
            case .statistics: return "statistics"
            case .trackerBrowser: return "trackerBrowser"
            }
        }
    }

    struct ServerBookmarkDraft {
        var name: String
        var host: String
        var port: String
        var login: String
        var password: String
        var nickname: String
        var statusMessage: String
        var autoReconnect: Bool
        var connectAtLaunch: Bool
        var acceptsOfflineMessages: Bool

        init(bookmark: ServerBookmark?, password: String = "") {
            name = bookmark?.name ?? ""
            host = bookmark?.host ?? ""
            port = bookmark.map { String($0.port) } ?? String(LegacyWire.defaultControlPort)
            login = bookmark?.login ?? "anonymous"
            self.password = password
            nickname = bookmark?.nickname ?? ""
            statusMessage = bookmark?.statusMessage ?? ""
            autoReconnect = bookmark?.autoReconnect ?? false
            connectAtLaunch = bookmark?.connectAtLaunch ?? false
            acceptsOfflineMessages = bookmark?.acceptsOfflineMessages ?? true
        }

        init(name: String, host: String, port: String, login: String, password: String, nickname: String,
             statusMessage: String, autoReconnect: Bool, connectAtLaunch: Bool, acceptsOfflineMessages: Bool) {
            self.name = name
            self.host = host
            self.port = port
            self.login = login
            self.password = password
            self.nickname = nickname
            self.statusMessage = statusMessage
            self.autoReconnect = autoReconnect
            self.connectAtLaunch = connectAtLaunch
            self.acceptsOfflineMessages = acceptsOfflineMessages
        }
    }

    struct ChannelTranscriptEntry {
        enum Kind {
            case message(senderUserID: UInt32, message: Data, attribute: UInt8)
            case system(String)
        }
        var timestamp: Date
        var kind: Kind
    }

    struct JoinedChannelSession {
        var state: LegacyChannelState
        var members: [UInt32: UInt8]
        var transcript: [ChannelTranscriptEntry]
        var unreadCount: Int
        var draftText: String = ""
        var draftAttachmentTokens: [String] = []
        var transcriptScrollY: CGFloat = 0
    }

    /// Local conversation state layered on top of the historical one-shot Private Message wire command.
    /// Nothing here changes the protocol: Classic peers still receive every outgoing row as one normal PM.
    struct PrivateMessageEntry {
        var id: UUID = UUID()
        var timestamp: Date
        var outgoing: Bool
        var message: Data
    }

    struct PrivateMessageConversation {
        var userID: UInt32
        var nickname: String
        var picture: Data
        var isLegacyTransport: Bool
        var entries: [PrivateMessageEntry] = []
        var unreadCount: Int = 0
        var draftText: String = ""
        var lastActivity: Date = Date()
    }

    enum MessageCenterListRow {
        case offlineMessages
        case conversation(PrivateMessageConversation)
    }

    struct ClientTransferMonitorItem {
        let id: UUID
        let kind: UInt8
        let userID: UInt32?
        let userNickname: String
        let userPicture: Data
        let serverName: String
        var name: String
        var detail: String
        var finderURL: URL?
        var completedBytes: UInt64
        var totalBytes: UInt64
        var state: String
        var active: Bool
        var queued: Bool
        var paused: Bool
        var resumable: Bool
        var resumed: Bool
        var resumeOnStart: Bool
        var attemptGeneration: UInt64
        let startedAt: Date
        var rateBytesPerSecond: UInt64? = nil
        var lastProgressSampleDate: Date? = nil
        var lastProgressBytes: UInt64 = 0
        var errorMessage: String? = nil
    }

    enum TransferMonitorRow {
        case local(ClientTransferMonitorItem)
        case managed(LegacyManagedTransferRecord)
        case legacyServer(LegacyTransferInfoRecord)
    }

    enum TransferMonitorScope: Int {
        case mine = 0
        case serverWide = 1
    }

    enum TransferMonitorFilter: Int, CaseIterable {
        case all = 0
        case active
        case waiting
        case paused
        case finished
    }

    enum TransferMonitorStatusCategory {
        case active
        case waiting
        case paused
        case interrupted
        case failed
        case cancelled
        case completed
    }

    enum TransferMonitorRowKey: Hashable {
        case local(UUID)
        case managed(UInt32)
        case legacy(kind: UInt8, userID: UInt32, path: Data)
    }

    /// One visible row in the Files table. Directory children are fetched lazily when
    /// their disclosure triangle is opened, so browsing a large server tree does not
    /// turn one innocent click into a recursive network crawl.
    struct VisibleFileRow {
        var entry: LegacyDirectoryEntry
        var path: Data
        var depth: Int
    }

    static let remoteFileMovePasteboardType = NSPasteboard.PasteboardType("com.carracho.remote-file-path")

    final class RemoteFilePromiseInfo: NSObject {
        let remotePath: Data
        let displayName: String
        let isFolder: Bool
        let transferClient: LegacyFileTransferClient

        init(remotePath: Data, displayName: String, isFolder: Bool, transferClient: LegacyFileTransferClient) {
            self.remotePath = remotePath
            self.displayName = displayName
            self.isFolder = isFolder
            self.transferClient = transferClient
        }
    }

    enum ClientTransferOperation {
        case download(remotePath: Data, destination: URL)
        case downloadDirectory(remotePath: Data, parentDirectory: URL)
        case upload(localFile: URL, parentPath: Data, overwrite: Bool)
    }

    struct PersistedTransferMonitorDocument: Codable {
        var version: Int = 1
        var sessions: [String: PersistedTransferMonitorSession] = [:]
    }

    struct PersistedTransferMonitorSession: Codable {
        var host: String
        var port: UInt16
        var login: String
        var items: [PersistedTransferMonitorItem]
        var selectedTransferID: UUID?
    }

    struct PersistedTransferMonitorItem: Codable {
        var id: UUID
        var kind: UInt8
        var userID: UInt32?
        var userNickname: String
        var userPicture: Data
        var serverName: String
        var name: String
        var detail: String
        var finderURL: URL?
        var completedBytes: UInt64
        var totalBytes: UInt64
        var state: String
        var active: Bool
        var queued: Bool
        var paused: Bool
        var resumable: Bool
        var resumed: Bool
        var resumeOnStart: Bool
        var attemptGeneration: UInt64
        var startedAt: Date
        var errorMessage: String?
        var operation: PersistedTransferOperation?
    }

    struct PersistedTransferOperation: Codable {
        enum Kind: String, Codable { case download, downloadDirectory, upload }
        var kind: Kind
        var remotePath: Data?
        var localURL: URL?
        var parentPath: Data?
        var overwrite: Bool?
    }

    /// Complete per-bookmark presentation/session state. A bookmark keeps its own
    /// control connection alive while another bookmark is selected; this snapshot is
    /// swapped into the shared AppKit views when the user activates that bookmark.
    struct BookmarkSessionSnapshot {
        var workspace: Workspace
        var lastLoginResult: LegacyLoginResult?
        var lastServerInfo: LegacyServerInfo?
        var remoteServerUptimeSeconds: TimeInterval?
        var remoteServerUptimeObservedAt: Date?
        var lastDirectory: LegacyDirectoryListing?
        var fileTransferClient: LegacyFileTransferClient?
        var fileSearchClient: LegacyFileSearchClient?
        var bannerClient: LegacyBannerClient?
        var currentBanner: LegacyBannerContent?
        var fileSearchResults: [LegacyFileSearchResult]?
        var fileSearchQuery: String
        var fileNavigationHistory: [Data]
        var fileNavigationIndex: Int
        var expandedFilePaths: Set<Data>
        var expandedDirectoryListings: [Data: LegacyDirectoryListing]
        var selectedFilePaths: Set<Data>
        var fileTableScrollY: CGFloat
        var transferMonitorItems: [UUID: ClientTransferMonitorItem]
        var transferMonitorOrder: [UUID]
        var clientTransferTasks: [UUID: LegacyFileTransferTask]
        var clientTransferOperations: [UUID: ClientTransferOperation]
        var selectedTransferID: UUID?
        var selectedRemoteTransferID: UInt32?
        var remoteTransferSnapshot: [LegacyTransferInfoRecord]
        var remoteManagedTransferSnapshot: [LegacyManagedTransferRecord]
        var remoteTransferUploadLimitBytesPerSecond: UInt64?
        var remoteDownloadTrafficBytesPerSecond: UInt64?
        var lastChannels: [LegacyChannelSummary]
        var lastNewsgroups: [Data]
        var newsClient: LegacyNewsClient?
        var mediaClient: LegacyMediaClient?
        var mediaCache: CarrachoMediaCache?
        var hiddenMediaIDs: Set<UUID>
        var currentNewsIndex: LegacyArticleIndex?
        var currentArticle: LegacyArticleReply?
        var currentNewsCategory: Data?
        var currentNewsThreads: [LegacyNewsThreadSummary]
        var currentNewsThreadID: UInt32?
        var currentNewsThreadPosts: [LegacyNewsThreadPostSummary]
        var currentNewsThreadArticles: [LegacyArticleReply]
        var currentNewsReactions: [UInt32: [LegacyNewsReactionSummary]]
        var currentNewsPostCapabilities: [UInt32: LegacyNewsPostCapability]
        var newsReactionsSupported: Bool
        var newsReadState: NewsReadState
        var newsReadScope: String?
        var newsThreadsByCategory: [Data: [LegacyNewsThreadSummary]]
        var newsBadgesSupported: Bool
        var activeChannel: LegacyChannelState?
        var channelMembers: [UInt32: UInt8]
        var joinedChannels: [UInt32: JoinedChannelSession]
        var privateMessageConversations: [UInt32: PrivateMessageConversation]
        var selectedPrivateConversationID: UInt32?
        var offlineMessageCenterMessages: [LegacyOfflineMessage]
        var offlineMessageCenterUnreadIDs: Set<String>
        var offlineMessageCenterUnreadCount: Int
        var messageCenterPersistenceScope: MessageCenterStoreScope?
        var offlineMessageLoginNoticePresented: Bool
        var selectedOfflineMessages: Bool
        var privateMessageSearchQuery: String
        var liveUsers: [UInt32: LegacyUserListEntry]
        var selectedUserID: UInt32?
        var sleepingUsers: Set<UInt32>
        var userStatusMessages: [UInt32: Data]
        var userGroupColors: [UInt32: UInt32]
        var remoteAccountSummaries: [LegacyCompactAccountSummary]
        var remoteAccountGroups: [ServerAccountGroup]
        var remoteAccountGroupByLogin: [String: UUID]
        var activeAvatarIdentity: LocalAvatarIdentity?
        var detailsText: String
        var deferredInteractiveEvents: [LegacyControlEvent]
    }

    final class BookmarkConnectionContext {
        let bookmarkID: UUID
        let client: LegacyControlClient
        var snapshot: BookmarkSessionSnapshot?
        var pendingEvents: [LegacyControlEvent] = []
        var eventNotificationCount = 0
        var newsNotificationCount = 0
        var backgroundNewsTimer: Timer?
        var backgroundNewsRefreshInFlight = false
        var backgroundNewsSupported = true
        var backgroundNewsKnownGroups: Set<Data> = []
        var backgroundNewsTotals: [Data: [UInt32: UInt32]] = [:]

        var notificationCount: Int {
            min(999, eventNotificationCount + newsNotificationCount)
        }

        init(bookmarkID: UUID, client: LegacyControlClient = LegacyControlClient()) {
            self.bookmarkID = bookmarkID
            self.client = client
        }
    }

    static let channelOperatorMode: UInt8 = 0x80
    static let channelSpeechMode: UInt8 = 0x40
    static let channelRestrictedChatFlag: UInt16 = 0x1000
    static let channelRestrictedTopicFlag: UInt16 = 0x2000
    static let maximumJoinedChannels = 6
    static let contentFontSizeOptions: [CGFloat] = [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24]
    static let filesFontSizeDefaultsKey = "Carracho.FilesFontSize"

    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let fileByteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    static let newsFontSizeDefaultsKey = "Carracho.NewsFontSize"
    static let channelChatFontSizeDefaultsKey = "Carracho.ChannelChatFontSize"
    static let serverLogFontSizeDefaultsKey = "Carracho.ServerLogFontSize"
    static let eventsFontSizeDefaultsKey = "Carracho.EventsFontSize"
    static let messageCenterFontSizeDefaultsKey = "Carracho.MessageCenterFontSize"
    static let transferAutoRemoveFinishedDefaultsKey = "Carracho.TransferMonitor.AutoRemoveFinished.v1"
    static let transferMonitorPersistenceFilename = "transfer-monitor-v1.json"
    static let mainWindowFrameAutosaveName = "Carracho.MainWindow.v1"
    static let bookmarkSidebarCollapsedDefaultsKey = "Carracho.Sidebar.BookmarksCollapsed.v1"
    static let trackerSidebarCollapsedDefaultsKey = "Carracho.Sidebar.TrackersCollapsed.v1"
    static let serverSidebarCollapsedDefaultsKey = "Carracho.Sidebar.ServerCollapsed.v1"
    static let conferencesSidebarCollapsedDefaultsKey = "Carracho.Sidebar.ConferencesCollapsed.v1"
    static let administrationSidebarCollapsedDefaultsKey = "Carracho.Sidebar.AdministrationCollapsed.v1"
    static let sidebarBlockOrderDefaultsKey = "Carracho.Sidebar.BlockOrder.v1"
    static let inspectorServerInfoCollapsedDefaultsKey = "Carracho.Inspector.ServerInfoCollapsed.v1"
    static let inspectorConnectionDetailsCollapsedDefaultsKey = "Carracho.Inspector.ConnectionDetailsCollapsed.v1"
    static let statisticsHelpCollapsedDefaultsKey = "Carracho.Statistics.HelpCollapsed.v1"

    enum SidebarBlock: String, CaseIterable {
        case server
        case trackers
        case bookmarks
        case administration
    }
    /// Units offered for the aggregate server-upload cap. `kb/s` intentionally means
    /// kilobytes per second here; Kbit/Mbit are bit rates and MB/s is megabytes per second.
    static let transferBandwidthUnitTitles = ["kb/s", "Kbit", "Mbit", "MB/s"]
    static let transferBandwidthUnitBytesPerSecond: [Double] = [1_000, 125, 125_000, 1_000_000]

    static func localAvatarStoreDirectoryOverride() -> URL? {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--avatar-store-directory=") }) else { return nil }
        let path = String(argument.dropFirst("--avatar-store-directory=".count))
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var client = LegacyControlClient()
    var bookmarkConnections: [UUID: BookmarkConnectionContext] = [:]
    var activeBookmarkConnectionID: UUID?
    let serverStateLoadQueue = DispatchQueue(label: "com.carracho.server-state-loader", qos: .userInitiated)
    var serverBackend: ModernServerBackend?
    var localServerRuntime: LegacyServerRuntime?
    var startServerWhenBackendLoads = false
    var localServerState: ServerState = .initial
    var localAccountTransferStatistics: [UUID: LegacyAccountTransferStatistics] = [:]
    var currentWorkspace: Workspace = .overview
    var didRestoreMainWindowFrame = false
    var sidebarButtons: [Workspace: NSButton] = [:]
    let overviewFilesHost = NSView()
    let overviewConferencesHost = NSView()
    let standaloneFilesHost = NSView()
    let standaloneConferencesHost = NSView()
    lazy var sharedFilesCard: NSView = makeFilesCard()
    lazy var sharedConferencesCard: NSView = makeChatCard()
    weak var bookmarkSidebarHeader: NSButton?
    weak var trackerSidebarHeader: NSButton?
    weak var serverSidebarHeader: NSButton?
    weak var serverSidebarContent: NSStackView?
    weak var conferencesSidebarHeader: NSButton?
    weak var conferencesSidebarContent: NSStackView?
    weak var administrationSidebarHeader: NSButton?
    weak var administrationSidebarContent: NSStackView?
    weak var administrationSidebarBlock: NSStackView?
    let sidebarBlockStack = SidebarBlockStackView(frame: .zero)
    var sidebarBlockViews: [SidebarBlock: NSView] = [:]
    var sidebarBlockEdgeConstraints: [NSLayoutConstraint] = []
    weak var advancedToolbarButton: NSButton?
    weak var workspaceColumnSplit: CarrachoResizableColumnSplitView?
    weak var workspaceTransferBar: NSView?
    var workspaceTransferBarHeightConstraint: NSLayoutConstraint?
    let inspectorToggleButton = NSButton()
    weak var serverBannerHost: NSView?
    weak var serverBannerSeparator: NSView?
    weak var inspectorServerInfoBody: NSStackView?
    weak var inspectorConnectionDetailsBody: NSStackView?
    weak var inspectorServerInfoDisclosureButton: NSButton?
    weak var inspectorConnectionDetailsDisclosureButton: NSButton?
    weak var generalInspectorContent: NSView?
    weak var conferenceInspectorContent: NSView?
    let conferenceInspectorTitleLabel = NSTextField(labelWithString: L("Room Details"))
    let conferenceInspectorRoomLabel = NSTextField(labelWithString: L("No room selected"))
    let conferenceInspectorPropertiesLabel = NSTextField(labelWithString: "")
    let conferenceInspectorParticipantsLabel = NSTextField(labelWithString: L("Participants"))
    var channelDiscoverySheet: NSWindow?
    var newChatRoomWindowController: NewChatRoomWindowController?
    var trackerEditorWindowController: TrackerEditorWindowController?
    var trackerPrivateLoginWindowController: TrackerPrivateLoginWindowController?
    var trackerCredentialValidationClient: LegacyControlClient?
    var fileInfoWindowController: FileInfoWindowController?
    var serverBookmarkEditorWindowController: ServerBookmarkEditorWindowController?
    var serverBookmarks: [ServerBookmark] = []
    var temporaryServerBookmarkIDs: Set<UUID> = []
    var selectedBookmarkID: UUID?
    var connectingBookmarkID: UUID?
    var connectedBookmarkID: UUID?
    var autoReconnectBookmarkID: UUID?
    var autoReconnectWorkItem: DispatchWorkItem?
    var autoReconnectAttempt = 0
    let bookmarkStack = NSStackView()
    let serverBookmarkStore = ServerBookmarkStore()
    let trackerBookmarkStore = TrackerBookmarkStore()
    var trackerBookmarks: [TrackerBookmark] = []
    var selectedTrackerID: UUID?
    var trackerResults: [UUID: [LegacyTrackerServerEntry]] = [:]
    var trackerErrors: [UUID: String] = [:]
    var trackerRefreshInFlight: Set<UUID> = []
    var trackerRefreshGeneration: [UUID: Int] = [:]
    var trackerRefreshTimer: Timer?
    var serverWorkspaceBeforeTracker: Workspace?
    let trackerStack = NSStackView()
    let serverBookmarkKeychain = ServerBookmarkKeychain()
    var bookmarkPasswordChangeClient: LegacyControlClient?
    let localAvatarStore = LocalAvatarStore(directoryURL: ViewController.localAvatarStoreDirectoryOverride())
    var activeAvatarIdentity: LocalAvatarIdentity?
    var clientSettingsWindow: NSWindow?
    let clientSoundPreferences = ClientSoundPreferences()
    let clientNotificationManager = ClientNotificationManager()
    weak var clientSettingsTabControl: NSSegmentedControl?
    weak var clientSettingsGeneralView: NSView?
    weak var clientSettingsSoundsView: NSView?
    weak var clientSettingsRestoreDefaultsButton: NSButton?
    weak var clientSettingsSoundsEnabledCheckbox: NSButton?
    weak var clientSettingsVolumeSlider: NSSlider?
    weak var clientSettingsVolumeLabel: NSTextField?
    var clientSettingsSoundPopups: [ClientSoundEvent: NSPopUpButton] = [:]
    var clientSettingsSoundPreviewButtons: [ClientSoundEvent: NSButton] = [:]
    var clientSettingsNotificationCheckboxes: [ClientSoundEvent: NSButton] = [:]
    var clientSettingsGeneralWasVisited = false
    weak var clientSettingsNicknameField: NSTextField?
    weak var clientSettingsStatusField: NSTextField?
    weak var clientSettingsEmailField: NSTextField?
    weak var clientSettingsAboutView: NSTextView?
    weak var clientSettingsDownloadFolderField: NSTextField?
    weak var clientSettingsAvatarView: AvatarDropView?
    var clientSettingsPendingDownloadFolderPath: String?
    var resumeConnectionAfterIdentitySetup = false
    var resumeConnectionBookmarkID: UUID?
    var legacyPrivateMessageComposerWindow: PrivateMessageComposerWindowController?
    var offlineMessageComposer: OfflineMessageComposerWindowController?
    var flatNewsWindowController: FlatNewsWindowController?

    let serverTitleLabel = NSTextField(labelWithString: L("Carracho Server"))
    let rightServerNameValue = NSTextField(labelWithString: "—")
    let rightServerUptimeValue = NSTextField(labelWithString: "—")
    let rightServerVersionValue = NSTextField(labelWithString: "—")
    let rightServerProtocolValue = NSTextField(labelWithString: "—")
    let rightServerCipherValue = NSTextField(labelWithString: "—")
    let rightServerUsersValue = NSTextField(labelWithString: "0")
    let rightEndpointValue = NSTextField(labelWithString: "—")
    let rightServerDescriptionValue = NSTextField(wrappingLabelWithString: "—")
    let rightBannerImageView = NSImageView()
    var serverBannerWidthConstraint: NSLayoutConstraint?
    var remoteServerUptimeSeconds: TimeInterval?
    var remoteServerUptimeObservedAt: Date?
    var serverUptimeDisplayTimer: Timer?
    let transferSummaryLabel = NSTextField(labelWithString: L("No active transfers"))
    let transferBarSpeedLabel = NSTextField(labelWithString: "")
    let bottomStatusLabel = NSTextField(labelWithString: L("Not connected"))
    let bottomEndpointLabel = NSTextField(labelWithString: "—")
    let bottomEncryptionLabel = NSTextField(labelWithString: L("Encrypted"))
    let fileSearchField = NSSearchField()
    let filesFontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let newsFontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let channelChatFontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let serverLogFontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let eventsFontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let messageCenterFontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let eventLogFilterField = NSSearchField()
    let eventLogFilterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let eventLogFilterStatusLabel = NSTextField(labelWithString: "")
    var filesFontSize: CGFloat = 13
    var newsFontSize: CGFloat = 13
    var channelChatFontSize: CGFloat = 13
    var serverLogFontSize: CGFloat = 11
    var eventsFontSize: CGFloat = 11
    var messageCenterFontSize: CGFloat = 13
    var eventLogRawText = ""
    let serverLogTextView = NSTextView()
    let eventLogTextView = NSTextView()
    let userInfoButton = NSButton(title: L("Info"), target: nil, action: nil)
    let userMessageButton = NSButton(title: L("Message"), target: nil, action: nil)
    let userOfflineMessageButton = CarrachoSidebarButton(title: L("Offline Message…"), target: nil, action: nil)
    let userDisconnectButton = NSButton(title: L("Kick"), target: nil, action: nil)
    let userBanButton = NSButton(title: L("Ban"), target: nil, action: nil)
    let presenceButton = NSButton(title: L("Sleep"), target: nil, action: nil)
    let chatUsersLabel = NSTextField(labelWithString: L("0 users"))
    let chatRoomStateLabel = NSTextField(labelWithString: "")
    let chatTopicLabel = NSTextField(wrappingLabelWithString: "")
    let broadcastButton = CarrachoSidebarButton(title: L("Broadcast"), target: nil, action: nil)
    let chatJoinedRoomsLabel = NSTextField(labelWithString: "")
    let appearancePopup = NSPopUpButton()
    var workspacePopovers: [Int: NSPopover] = [:]
    let transferProgress = NSProgressIndicator()


    let adminServerNameField = NSTextField(string: "")
    let adminOperatorField = NSTextField(string: "")
    let adminLocationField = NSTextField(string: "")
    let adminDescriptionView = NSTextView()
    let adminBannerURLField = NSTextField(string: "")
    let adminBannerImageView = NSImageView()
    let adminBannerChooseButton = NSButton(title: L("Choose PNG…"), target: nil, action: nil)
    let adminBannerRemoveButton = NSButton(title: L("Remove Banner"), target: nil, action: nil)
    let adminServerInfoStatusLabel = NSTextField(labelWithString: "")
    let adminServerInfoSaveButton = NSButton(title: L("Save"), target: nil, action: nil)
    let adminServerInfoDiscardButton = NSButton(title: L("Discard Changes"), target: nil, action: nil)
    let adminServerInfoPreviewNameLabel = NSTextField(labelWithString: L("Carracho Server"))
    let adminServerInfoPreviewDescriptionLabel = NSTextField(wrappingLabelWithString: "")
    let adminServerInfoPreviewOperatorLabel = NSTextField(labelWithString: "")
    let adminServerInfoPreviewLocationLabel = NSTextField(labelWithString: "")
    let adminServerInfoPreviewNoBannerLabel = NSTextField(labelWithString: L("No banner selected"))
    let adminServerInfoPreviewCaptionLabel = NSTextField(labelWithString: L("Preview only — client presentation may vary."))
    let adminAccountTable = NSTableView()
    let adminAccountNewButton = NSButton(title: L("New Account"), target: nil, action: nil)
    let adminAccountGroupsButton = NSButton(title: L("Groups…"), target: nil, action: nil)
    let adminAccountReloadButton = NSButton(title: L("Reload"), target: nil, action: nil)
    let adminAccountStatusLabel = NSTextField(labelWithString: "")
    let adminBotStatusLabel = NSTextField(labelWithString: L("Bot status has not been loaded yet."))
    let adminBotAccountLabel = NSTextField(labelWithString: "—")
    let adminBotRuntimeLabel = NSTextField(labelWithString: "—")
    let adminBotToggleButton = NSButton(title: L("Connect Bot"), target: nil, action: nil)
    let adminBotReloadButton = NSButton(title: L("Reload"), target: nil, action: nil)
    let adminBotAccountsButton = NSButton(title: L("Open Accounts"), target: nil, action: nil)
    let adminBotGreetingSwitch = NSSwitch()
    let adminBotGreetingTemplateField = NSTextField(string: LegacyBotAdminStatus.defaultGreetingTemplate)
    let adminBotGreetingSaveButton = NSButton(title: L("Save Greeting"), target: nil, action: nil)
    let adminBotCommandTable = NSTableView()
    let adminBotCommandAddButton = NSButton(title: L("Add Rule"), target: nil, action: nil)
    let adminBotCommandDeleteButton = NSButton(title: L("Remove Rule"), target: nil, action: nil)
    let adminBotCommandSaveButton = NSButton(title: L("Save Rules"), target: nil, action: nil)
    let adminBotRSSTable = NSTableView()
    let adminBotRSSAddButton = NSButton(title: L("Add Feed"), target: nil, action: nil)
    let adminBotRSSDeleteButton = NSButton(title: L("Remove Feed"), target: nil, action: nil)
    let adminBotRSSTestButton = NSButton(title: L("Test Feed"), target: nil, action: nil)
    let adminBotRSSSaveButton = NSButton(title: L("Save Feeds"), target: nil, action: nil)
    let adminBotLoadingIndicator = NSProgressIndicator()
    var remoteBotStatus: LegacyBotAdminStatus?
    var remoteBotLoading = false
    var remoteBotMutationInProgress = false
    var remoteBotGreetingMutationInProgress = false
    var remoteBotCommandMutationInProgress = false
    var remoteBotCommandRulesDirty = false
    var remoteBotCommandRuleDraft: [LegacyBotCommandRule] = []
    var remoteBotRSSMutationInProgress = false
    var remoteBotRSSTestInProgress = false
    var remoteBotRSSFeedsDirty = false
    var remoteBotRSSFeedDraft: [LegacyBotRSSFeed] = []
    var remoteBotRefreshGeneration: UInt64 = 0
    var remoteAccountSummaries: [LegacyCompactAccountSummary] = []
    var remoteAccountGroups: [ServerAccountGroup] = []
    var remoteAccountGroupByLogin: [String: UUID] = [:]
    var remoteAccountListLoading = false
    let adminNewsgroupTable = NSTableView()
    var remoteAdminNewsgroups: [ServerNewsgroup] = []
    var remoteNewsgroupAdministrationLoading = false
    var remoteNewsgroupAdministrationGeneration: UInt64 = 0
    let adminTrackerTable = NSTableView()
    let adminTrackerAddButton = NSButton(title: L("Add Tracker"), target: nil, action: nil)
    let adminTrackerModifyButton = NSButton(title: L("Modify"), target: nil, action: nil)
    let adminTrackerDeleteButton = NSButton(title: L("Delete"), target: nil, action: nil)
    let adminTrackerRegisterCheckbox = NSSwitch()
    let adminTrackerPrivateCheckbox = NSSwitch()
    let adminTrackerBandwidthPopup = NSPopUpButton()
    let adminTrackerDescriptionField = NSTextField(string: "")
    let adminTrackerStatusLabel = NSTextField(labelWithString: "")
    let adminTrackerSelectionSummaryLabel = NSTextField(labelWithString: L("No trackers configured"))
    let adminTrackerEmptyLabel = NSTextField(wrappingLabelWithString: L("No trackers configured. Add a tracker to choose where this server may be published."))
    let adminTrackerSaveButton = NSButton(title: L("Save"), target: nil, action: nil)
    let adminTrackerDiscardButton = NSButton(title: L("Discard"), target: nil, action: nil)
    var adminTrackerListHeightConstraint: NSLayoutConstraint?

    struct TrackerAdminSnapshot: Equatable {
        var trackers: [ServerTrackerSetting]
        var advertisementFlags: UInt32
        var description: String
    }
    var trackerLoadedSnapshot: TrackerAdminSnapshot?
    var trackerDraftTrackers: [ServerTrackerSetting] = []
    var trackerDraftAdvertisementFlags: UInt32 = 0
    var trackerSourceKey: String?
    var trackerHasUnsavedChanges = false
    var trackerSaveInProgress = false
    var trackerLoadGeneration: UInt64 = 0
    var trackerStatusOverride: String?
    var trackerStatusColor: NSColor?
    var remoteTrackerSettingsLoading = false
    var remoteAdvancedAuthenticationMode: ServerAuthenticationMode?
    let adminAccountModifyButton = NSButton(title: L("Modify"), target: nil, action: nil)
    let adminAccountDeleteButton = NSButton(title: L("Delete"), target: nil, action: nil)
    let adminNewsgroupModifyButton = NSButton(title: L("Modify"), target: nil, action: nil)
    let adminNewsgroupDeleteButton = NSButton(title: L("Delete"), target: nil, action: nil)
    let adminAuthenticationModePopup = NSPopUpButton()
    let adminMaxConnectionsField = NSTextField(string: "")
    let adminMaxConnectionsPerIPField = NSTextField(string: "")
    let adminMaxTransfersField = NSTextField(string: "")
    let adminMaxTransfersPerUserField = NSTextField(string: "")
    let adminMaxFolderDepthField = NSTextField(string: "")
    let adminLegacyFilesRootField = NSTextField(string: "")
    let adminLegacyFilesRootStatusLabel = NSTextField(labelWithString: "")
    let adminSearchIndexExclusionsView = NSTextView()
    let adminSearchIndexExclusionsStatusLabel = NSTextField(labelWithString: "")
    let adminIPRulesView = NSTextView()
    let adminBanStatusLabel = NSTextField(labelWithString: L("Connect to a server to manage bans."))
    let advancedSaveButton = NSButton(title: L("Save Changes"), target: nil, action: nil)
    let advancedResetButton = NSButton(title: L("Reset"), target: nil, action: nil)
    let advancedSaveStatusLabel = NSTextField(labelWithString: L("No unsaved changes"))
    let advancedRebuildIndexButton = NSButton(title: L("Rebuild Search Index"), target: nil, action: nil)
    let advancedEmptyTrashButton = NSButton(title: L("Empty Trash…"), target: nil, action: nil)
    var advancedTrashOperationInProgress = false
    var advancedSearchIndexRebuildInProgress = false
    var advancedHasUnsavedChanges = false
    var advancedBandwidthDirty = false
    var advancedSaveInProgress = false
    var advancedSaveStatusOverride: String?
    var advancedSaveStatusColor: NSColor?
    var advancedRemoteCoreLoaded = false
    var advancedRemoteLegacyRootLoaded = false
    var advancedRemoteExclusionsLoaded = false
    var advancedRemoteBansLoaded = false
    let adminNewsExpireTimeField = NSTextField(string: "")
    let agreementEditor = NSTextView()
    let agreementCheckbox = NSButton(checkboxWithTitle: L("Show Agreement"), target: nil, action: nil)
    let statsHitsValue = NSTextField(labelWithString: "—")
    let statsCurrentUsersValue = NSTextField(labelWithString: "—")
    let statsConnectionPeakValue = NSTextField(labelWithString: "—")
    let statsIncorrectLoginsValue = NSTextField(labelWithString: "—")
    let statsAdminsValue = NSTextField(labelWithString: "—")
    let statsAccountHoldersValue = NSTextField(labelWithString: "—")
    let statsGuestsValue = NSTextField(labelWithString: "—")
    let statsRefreshButton = NSButton(title: L("Refresh"), target: nil, action: nil)
    let statsLoadingIndicator = NSProgressIndicator()
    let statsStatusLabel = NSTextField(labelWithString: L("Statistics have not been loaded yet."))
    let statsHelpDisclosureButton = NSButton(title: L("About these counters"), target: nil, action: nil)
    var statsHelpBody: NSView?

    struct StatisticsAdminSnapshot: Equatable {
        var hits: UInt64?
        var currentlyConnected: UInt64?
        var connectionPeak: UInt64?
        var incorrectLogins: UInt64?
        var adminsConnected: UInt64?
        var accountHoldersConnected: UInt64?
        var guestsConnected: UInt64?
    }
    var statisticsSnapshot: StatisticsAdminSnapshot?
    var statisticsSourceKey: String?
    var statisticsLoading = false
    var statisticsStale = false
    var statisticsRefreshGeneration: UInt64 = 0
    var statisticsLastSuccessfulRefresh: Date?
    var statisticsStatusOverride: String?
    var statisticsStatusColor: NSColor?

    let hostField = NSTextField(string: "localhost")
    let portField = NSTextField(string: String(LegacyWire.defaultControlPort))
    let loginField = NSTextField(string: "anonymous")
    let passwordField = NSSecureTextField(string: "")
    let nicknameField = NSTextField(string: "")
    let connectButton = NSButton(title: L("Connect"), target: nil, action: nil)
    let headerConnectionButton = NSButton(title: L("Connect"), target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: L("Not connected"))

    let tabView = NSTabView()
    let detailsTextView = NSTextView()
    let fileTable = NSTableView()
    let transferTable = NSTableView()
    let trackerBrowserTable = NSTableView()
    let trackerBrowserTitleLabel = NSTextField(labelWithString: L("Tracker"))
    let trackerBrowserStatusLabel = NSTextField(labelWithString: L("Select a Tracker"))
    let transferMonitorStatusLabel = NSTextField(labelWithString: L("No transfers yet"))
    let transferScopeControl = NSSegmentedControl(labels: [L("My Transfers"), L("Server-wide")], trackingMode: .selectOne, target: nil, action: nil)
    let transferFilterControl = NSSegmentedControl(labels: [L("All"), L("Active"), L("Waiting"), L("Paused"), L("Finished")], trackingMode: .selectOne, target: nil, action: nil)
    let transferSearchField = NSSearchField()
    let transferRefreshButton = NSButton(title: L("Refresh"), target: nil, action: nil)
    let transferViewRateLabel = NSTextField(labelWithString: "")
    let transferEmptyStateLabel = NSTextField(wrappingLabelWithString: L("No transfers"))
    let transferDetailsDisclosureButton = NSButton(title: L("Transfer Details"), target: nil, action: nil)
    let transferDetailNameLabel = NSTextField(labelWithString: "—")
    let transferDetailUserLabel = NSTextField(labelWithString: "—")
    let transferDetailServerLabel = NSTextField(labelWithString: "—")
    let transferDetailLocationLabel = NSTextField(wrappingLabelWithString: "—")
    let transferDetailStartedLabel = NSTextField(labelWithString: "—")
    let transferDetailErrorLabel = NSTextField(wrappingLabelWithString: "—")
    weak var transferDetailsBody: NSView?
    var transferDetailsCollapsed = false
    let transferBandwidthField = NSTextField(string: "0")
    let transferBandwidthUnitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let transferBandwidthApplyButton = NSButton(title: L("Apply"), target: nil, action: nil)
    let transferBandwidthValueLabel = NSTextField(labelWithString: L("Unlimited"))
    let transferDownloadSpeedLabel = NSTextField(labelWithString: L("Downloader traffic: —"))
    let transferPauseButton = NSButton(title: L("Pause"), target: nil, action: nil)
    let transferResumeButton = NSButton(title: L("Resume"), target: nil, action: nil)
    let transferAbortButton = NSButton(title: L("Abort"), target: nil, action: nil)
    let transferRemoveButton = NSButton(title: L("Remove"), target: nil, action: nil)
    let transferDeletePartialButton = NSButton(title: L("Delete Partial"), target: nil, action: nil)
    let transferShowInFinderButton = NSButton(title: L("Show in Finder"), target: nil, action: nil)
    let transferClearButton = NSButton(title: L("Clean Up"), target: nil, action: nil)
    let transferAutoRemoveFinishedCheckbox = NSButton(checkboxWithTitle: L("Remove finished transfers automatically"), target: nil, action: nil)

    // Message Center: a modern conversation UI over the unchanged Private Message command.
    let privateMessageConversationTable = NSTableView()
    let privateMessageSearchField = NSSearchField()
    let privateMessageNewButton = NSButton(title: L("New Message"), target: nil, action: nil)
    let privateMessageMarkReadButton = NSButton(title: L("Mark All Read"), target: nil, action: nil)
    let privateMessageClearChatButton = NSButton(title: L("Clear Chat"), target: nil, action: nil)
    let privateMessageDeleteChatButton = NSButton(title: L("Delete Chat"), target: nil, action: nil)
    let privateMessageHeaderAvatar = NSImageView()
    let privateMessageHeaderNameLabel = NSTextField(labelWithString: L("Select a conversation"))
    let privateMessageHeaderStatusLabel = NSTextField(labelWithString: "")
    let privateMessageTranscriptStack = NSStackView()
    weak var privateMessageTranscriptScroll: NSScrollView?
    let privateMessageEmptyLabel = NSTextField(wrappingLabelWithString: L("Choose a conversation or start a new message."))
    let privateMessageComposer = CarrachoMediaComposerTextView(frame: .zero)
    lazy var privateMessageEmojiButton = EmojiPickerButton(editor: privateMessageComposer)
    let privateMessageSendButton = NSButton(title: L("Send"), target: nil, action: nil)
    let privateMessageComposerStatusLabel = NSTextField(labelWithString: "")
    let privateMessageComposerHintLabel = NSTextField(labelWithString: L("Return to send · Shift-Return for a new line"))

    let userTable = NSTableView()
    let channelTable = NSTableView()
    let channelMemberTable = NSTableView()
    let channelChatTextView = CarrachoMediaDisplayTextView()
    let channelMessageField = CarrachoMediaComposerTextView(frame: .zero)
    lazy var channelEmojiButton = EmojiPickerButton(editor: channelMessageField)
    let channelComposerPlaceholderLabel = MousePassthroughLabel(labelWithString: L("Join a room to chat…"))
    let channelComposerStatusLabel = NSTextField(labelWithString: "")
    let channelComposerHintLabel = NSTextField(labelWithString: L("Return to send · Shift-Return for a new line"))
    var channelComposerHeightConstraint: NSLayoutConstraint?
    let channelHeaderSettingsButton = NSButton()
    let channelRoomSwitchButton = NSButton()
    let channelMemberActionsButton = NSButton()
    let channelTopicEditButton = NSButton(title: L("Edit Topic"), target: nil, action: nil)
    let channelDiscoverButton = CarrachoSidebarButton(title: L("Discover Rooms"), target: nil, action: nil)
    let joinedChannelSidebarStack = NSStackView()
    let channelJoinButton = NSButton(title: L("Join"), target: nil, action: nil)
    let channelLeaveButton = NSButton(title: L("Leave"), target: nil, action: nil)
    let channelNewButton = CarrachoSidebarButton(title: L("New Room"), target: nil, action: nil)
    let channelSettingsButton = NSButton(title: L("Room Settings"), target: nil, action: nil)
    let channelInviteButton = NSButton(title: L("Invite User"), target: nil, action: nil)
    let channelModeButton = NSButton(title: L("Member Mode"), target: nil, action: nil)
    let channelSendButton = NSButton(title: L("Send"), target: nil, action: nil)
    let channelClearButton = NSButton()
    let channelAttachButton = NSButton(title: L("Image"), target: nil, action: nil)
    let channelYouTubeButton = NSButton(title: L("YouTube"), target: nil, action: nil)
    let channelAttachmentStrip = CarrachoComposerAttachmentStrip()
    let channelTitleLabel = NSTextField(labelWithString: L("Choose a chat room"))
    let newsTable = NSTableView()
    let newsArticleTable = NSTableView()
    let newsArticleTextView = CarrachoMediaDisplayTextView()
    let newsLoadButton = NSButton(title: L("Open Category"), target: nil, action: nil)
    let newsNewCategoryButton = NSButton(title: L("New Category"), target: nil, action: nil)
    let newsPostButton = NSButton(title: L("New Thread"), target: nil, action: nil)
    let newsReplyButton = NSButton(title: L("Send Reply"), target: nil, action: nil)
    let newsDeleteButton = NSButton(title: L("Delete Thread"), target: nil, action: nil)
    let newsTitleLabel = NSTextField(labelWithString: L("No topic selected"))
    let newsBreadcrumbLabel = NSTextField(labelWithString: L("News"))
    let newsCategoryHeaderLabel = NSTextField(labelWithString: L("Categories"))
    let newsThreadsHeaderLabel = NSTextField(labelWithString: L("Topics"))
    let newsThreadMetaLabel = NSTextField(labelWithString: "")
    let newsThreadSortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let newsThreadActionsButton = NSButton()
    let newsRefreshButton = NSButton()
    let newsReplyTextView = CarrachoMediaComposerTextView(frame: .zero)
    let newsReplyAttachments = CarrachoComposerAttachmentStrip()
    let newsReplyTargetLabel = NSTextField(labelWithString: "")
    let newsReplyClearTargetButton = NSButton()
    let newsReplyValidationLabel = NSTextField(wrappingLabelWithString: "")
    let newsReplyAttachButton = NSButton(title: L("Image"), target: nil, action: nil)
    let newsReplyYouTubeButton = NSButton(title: L("YouTube"), target: nil, action: nil)
    let newsReplySendingIndicator = NSProgressIndicator()
    let filePathLabel = NSTextField(labelWithString: "/")
    let fileBreadcrumbStack = NSStackView()
    let fileBackButton = NSButton(title: L("Back"), target: nil, action: nil)
    let fileForwardButton = NSButton(title: L("Forward"), target: nil, action: nil)
    let fileRefreshButton = NSButton(title: L("Refresh"), target: nil, action: nil)
    let fileParentButton = NSButton(title: L("Parent"), target: nil, action: nil)
    let fileNewFolderButton = NSButton(title: L("New Folder"), target: nil, action: nil)
    let fileInfoButton = NSButton(title: L("Get Info"), target: nil, action: nil)
    let fileQuickViewButton = NSButton(title: L("Quick View"), target: nil, action: nil)
    let fileDeleteButton = NSButton(title: L("Delete"), target: nil, action: nil)
    let fileDownloadButton = NSButton(title: L("Download"), target: nil, action: nil)
    let fileUploadButton = NSButton(title: L("Upload"), target: nil, action: nil)
    let fileStatusLabel = NSTextField(labelWithString: "")
    let fileTransferLabel = NSTextField(labelWithString: "")
    let fileEmptyStateLabel = NSTextField(wrappingLabelWithString: "")
    let fileEmptyStateRetryButton = NSButton(title: L("Retry"), target: nil, action: nil)
    let fileLoadingIndicator = NSProgressIndicator()
    let fileContextMenu = NSMenu(title: L("File Actions"))
    let userContextMenu = NSMenu(title: L("User Actions"))

    var lastLoginResult: LegacyLoginResult?
    var lastServerInfo: LegacyServerInfo?
    var lastDirectory: LegacyDirectoryListing?
    var fileTransferClient: LegacyFileTransferClient?
    var fileSearchClient: LegacyFileSearchClient?
    var bannerClient: LegacyBannerClient?
    var currentBanner: LegacyBannerContent?
    var pendingAdminBannerData: Data?

    struct ServerInfoAdminSnapshot: Equatable {
        var serverName: String
        var operatorName: String
        var location: String
        var description: String
        var bannerURL: String
        var bannerData: Data?
    }
    var serverInfoLoadedSnapshot: ServerInfoAdminSnapshot?
    var serverInfoDraftSourceKey: String?
    var serverInfoHasUnsavedChanges = false
    var serverInfoSaveInProgress = false
    var serverInfoLoading = false
    var serverInfoSuppressChangeTracking = false
    var serverInfoLoadGeneration: UInt64 = 0
    var serverInfoStatusOverride: String?
    var serverInfoStatusColor: NSColor?
    var fileSearchResults: [LegacyFileSearchResult]?
    var fileSearchGeneration = 0
    var isFileSearchBusy = false
    var fileDirectoryLoadGeneration: UInt64 = 0
    var fileDirectoryLoading = false
    var filePendingDirectoryPath: Data?
    var fileDirectoryError: String?
    var fileSearchError: String?
    var fileNavigationHistory: [Data] = []
    var fileNavigationIndex = -1
    var fileBreadcrumbOverflowPaths: [(String, Data)] = []
    var fileBreadcrumbVisiblePaths: [Data] = []
    var fileShouldResetScrollOnNextReload = false
    var pendingFileScrollRestoreY: CGFloat?
    /// The shared Files card initially lives in Overview. Its first move into the full Files
    /// workspace needs one final top alignment after Auto Layout has resized the scroll view.
    var fileNeedsInitialWorkspaceTopAlignment = false
    var selectedFilePaths: Set<Data> = []
    /// Stable snapshot consumed by NSTableView while it asks for visible cells.
    /// Rebuilding/sorting the complete directory tree from every data-source callback makes
    /// scrolling large listings accidentally O(rows * visibleCells * log(rows)).
    var visibleFileRowSnapshot: [VisibleFileRow] = []
    var expandedFilePaths: Set<Data> = []
    var expandedDirectoryListings: [Data: LegacyDirectoryListing] = [:]
    var loadingExpandedFilePaths: Set<Data> = []
    var fileExpansionGeneration = 0
    var quickViewTransferTask: LegacyFileTransferTask?
    var quickViewTemporaryDirectory: URL?
    var quickViewItem: CarrachoQuickLookItem?
    var isQuickViewPreparing = false
    var quickViewGeneration = 0

    // File-list icons come from LaunchServices/NSWorkspace and can be surprisingly expensive.
    // Keep immutable copies by type so scrolling does not repeat icon lookup + TIFF comparison.
    var filesFolderIconCache: NSImage?
    var filesGenericDocumentIconCache: NSImage?
    var filesIncompleteIconCache: NSImage?
    var filesSystemFileTypeIconCache: [String: NSImage] = [:]
    var filesSystemFileTypeIconMisses: Set<String> = []

    static let quickViewMaximumBytes: UInt64 = 2_000_000
    static let quickViewExtensions: Set<String> = ["txt", "jpg", "png", "pdf", "html", "gif", "sh"]
    var transferMonitorItems: [UUID: ClientTransferMonitorItem] = [:]
    var transferMonitorOrder: [UUID] = []
    var clientTransferTasks: [UUID: LegacyFileTransferTask] = [:]
    var clientTransferOperations: [UUID: ClientTransferOperation] = [:]
    var selectedTransferID: UUID?
    var selectedRemoteTransferID: UInt32?
    var selectedTransferKeys: Set<TransferMonitorRowKey> = []
    var transferMonitorScope: TransferMonitorScope = .mine
    var transferMonitorFilter: TransferMonitorFilter = .all
    var transferMonitorSearchQuery = ""
    var transferRemoteRatesByKey: [TransferMonitorRowKey: UInt64] = [:]
    var transferRemotePreviousBytesByKey: [TransferMonitorRowKey: UInt64] = [:]
    var transferRemotePreviousSampleDate: Date?
    /// Folder/file kind fallback for servers that do not yet set the managed-transfer directory bit.
    /// Keyed by connection source so identical paths on different servers never bleed together.
    var transferRemoteDirectoryKindsBySource: [String: [Data: Bool]] = [:]
    var transferRemoteDirectoryLookupsBySource: [String: Set<Data>] = [:]
    var isReloadingTransferTable = false
    var transferTableReloadGeneration: UInt64 = 0
    static let downloadFolderDefaultsKey = "CarrachoDownloadFolder"
    static let generalIdentityConfiguredDefaultsKey = "CarrachoGeneralIdentityConfigured.v1"
    static let generalNicknameDefaultsKey = "CarrachoGeneralNickname.v1"
    static let generalStatusDefaultsKey = "CarrachoGeneralStatus.v1"
    static let generalEmailDefaultsKey = "CarrachoGeneralEmail.v1"
    static let generalAboutMeDefaultsKey = "CarrachoGeneralAboutMe.v1"
    static let globalAvatarIdentity = LocalAvatarIdentity(host: "__carracho_global_profile__", port: 0, login: "profile")
    var remoteTransferSnapshot: [LegacyTransferInfoRecord] = []
    var remoteManagedTransferSnapshot: [LegacyManagedTransferRecord] = []
    var remoteTransferUploadLimitBytesPerSecond: UInt64?
    var remoteDownloadTrafficBytesPerSecond: UInt64?
    var transferBarPreviousCompletedBytes: UInt64?
    var transferBarPreviousSampleDate: Date?
    var transferBarRateBytesPerSecond: UInt64 = 0
    var transferMonitorRefreshTimer: Timer?
    var transferMonitorRequestInFlight = false
    var transferMonitorPersistenceWorkItem: DispatchWorkItem?
    var transferMonitorPersistenceFingerprint: Int?
    var suppressTransferMonitorPersistence = false
    var transferQueueRetryWorkItem: DispatchWorkItem?
    var transferCapacityRequestInFlight = false
    var lastChannels: [LegacyChannelSummary] = []
    var lastNewsgroups: [Data] = []
    var newsClient: LegacyNewsClient?
    var mediaClient: LegacyMediaClient?
    var mediaCache: CarrachoMediaCache?
    var mediaDownloadsInFlight: Set<UUID> = []
    var mediaDownloadFailures: Set<UUID> = []
    var hiddenMediaIDs: Set<UUID> = []
    var currentNewsIndex: LegacyArticleIndex?
    var currentArticle: LegacyArticleReply?
    var currentNewsCategory: Data?
    var currentNewsThreads: [LegacyNewsThreadSummary] = []
    var currentNewsThreadID: UInt32?
    var currentNewsThreadPosts: [LegacyNewsThreadPostSummary] = []
    var currentNewsThreadArticles: [LegacyArticleReply] = []
    var currentNewsReactions: [UInt32: [LegacyNewsReactionSummary]] = [:]
    var currentNewsPostCapabilities: [UInt32: LegacyNewsPostCapability] = [:]
    var newsReactionsSupported = true
    let newsReadStateStore = NewsReadStateStore()
    var newsReadState = NewsReadState()
    var newsReadScope: String?
    var newsThreadsByCategory: [Data: [LegacyNewsThreadSummary]] = [:]
    var newsBadgeRefreshTimer: Timer?
    var newsBadgeRefreshInFlight = false
    var channelCatalogRefreshTimer: Timer?
    var channelCatalogRefreshInFlight = false
    var channelSendInFlight = false
    var isRestoringChannelComposer = false
    var isReloadingChannelTable = false
    var newsBadgesSupported = true
    var isReloadingNewsTable = false

    struct NewsReplyDraft {
        var text: String
        var attachmentTokens: [String]
        var targetArticleID: UInt32?
    }
    var newsReplyDrafts: [String: NewsReplyDraft] = [:]
    var newsReplyContextKey: String?
    var newsReplyTargetArticleID: UInt32?
    var newsReplySending = false
    var newsReplyMediaBusy = false
    var newsLoadErrorMessage: String?
    var newsThreadPreviewsByCategory: [Data: [UInt32: String]] = [:]
    var newsThreadPreviewLoading: [Data: Set<UInt32>] = [:]
    var activeChannel: LegacyChannelState?
    var channelMembers: [UInt32: UInt8] = [:]
    var joinedChannels: [UInt32: JoinedChannelSession] = [:]
    let messageCenterStore = MessageCenterStore()
    var privateMessageConversations: [UInt32: PrivateMessageConversation] = [:]
    var selectedPrivateConversationID: UInt32?
    var offlineMessageCenterMessages: [LegacyOfflineMessage] = []
    var offlineMessageCenterUnreadIDs: Set<String> = []
    var offlineMessageCenterUnreadCount = 0
    var messageCenterPersistenceScope: MessageCenterStoreScope?
    var offlineMessageLoginNoticePresented = false
    var selectedOfflineMessages = false
    var offlineMessageFetchInFlight = false
    var privateMessageSearchQuery = ""
    var isReloadingPrivateMessageTable = false
    var liveUsers: [UInt32: LegacyUserListEntry] = [:]
    var selectedUserID: UInt32?
    var isReloadingUserTable = false
    var sleepingUsers: Set<UInt32> = []
    var userStatusMessages: [UInt32: Data] = [:]
    var userGroupColors: [UInt32: UInt32] = [:]
    var localServerLogLines: [String] = []
    var remoteServerLogLoading = false
    var remoteEventLogLoading = false
    var didProcessLaunchArguments = false
    var didRunUserInfoSmoke = false
    var didRunChatSmoke = false
    var chatSmokeDumpPath: String?
    var didRunOfflineMessageSmoke = false
    var offlineMessageSmokeDumpPath: String?
    var offlineMessageSmokeNoticeCount = 0
    var isAwaitingAgreementAcceptance = false
    var connectionSetupBookmarkID: UUID?
    var pendingBookmarkActivationID: UUID?
    var deferredInteractiveEvents: [LegacyControlEvent] = []

    deinit {
        NotificationCenter.default.removeObserver(self)
        transferMonitorPersistenceWorkItem?.cancel()
        autoReconnectWorkItem?.cancel()
        transferMonitorRefreshTimer?.invalidate()
        newsBadgeRefreshTimer?.invalidate()
        channelCatalogRefreshTimer?.invalidate()
        trackerRefreshTimer?.invalidate()
        bookmarkConnections.values.forEach { $0.backgroundNewsTimer?.invalidate() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applySavedAppearance()
        loadSavedContentFontSizes()
        loadServerBookmarks()
        loadGeneralClientPreferences()
        loadTrackerBookmarks()
        buildInterface()
        applySelectedBookmarkToFields()
        if let selectedBookmarkID { restorePersistedTransferMonitorSession(for: selectedBookmarkID) }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)),
                                               name: NSApplication.willTerminateNotification, object: nil)
        configureClientCallbacks()
        renderWelcome()
        startTrackerRefreshTimer()
        // Server startup must not depend on the window reaching viewDidAppear. In
        // automated/headless-style GUI launches AppKit may delay appearance while the
        // local state has already finished loading.
        startServerWhenBackendLoads = ProcessInfo.processInfo.arguments.contains("--start-server")
        loadModernServerState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        window.title = "Carracho"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = CarrachoTheme.canvas
        window.minSize = NSSize(width: 980, height: 640)
        if !didRestoreMainWindowFrame {
            didRestoreMainWindowFrame = true
            let restored = window.setFrameUsingName(Self.mainWindowFrameAutosaveName)
            if !restored {
                window.setContentSize(NSSize(width: 1360, height: 820))
                window.center()
            }
            _ = window.setFrameAutosaveName(Self.mainWindowFrameAutosaveName)
        }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.view.layoutSubtreeIfNeeded()
            var lines: [String] = []
            func dump(_ node: NSView, _ indent: String) {
                lines.append("\(indent)\(type(of: node)) \(node.frame) hidden=\(node.isHidden) ambiguous=\(node.hasAmbiguousLayout)")
                for child in node.subviews { dump(child, indent + "  ") }
            }
            dump(self.view, "")
            try? lines.joined(separator: "\n").write(toFile: "/private/tmp/carracho-mockup-layout.txt", atomically: true, encoding: .utf8)
        }

        if !didProcessLaunchArguments {
            didProcessLaunchArguments = true
            let arguments = ProcessInfo.processInfo.arguments
            func launchValue(_ prefix: String) -> String? {
                arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
            }
            if let host = launchValue("--host="), !host.isEmpty { hostField.stringValue = host }
            if let port = launchValue("--port="), UInt16(port) != nil { portField.stringValue = port }
            if let login = launchValue("--login="), !login.isEmpty { loginField.stringValue = login }
            if let nickname = launchValue("--nickname="), !nickname.isEmpty { nicknameField.stringValue = nickname }
            if let workspaceArg = arguments.first(where: { $0.hasPrefix("--workspace=") }) {
                let value = String(workspaceArg.dropFirst("--workspace=".count))
                let workspace: Workspace?
                switch value {
                case "overview": workspace = .overview
                case "conferences": workspace = .conferences
                case "files": workspace = .files
                case "transfers": workspace = .transfers
                case "users": workspace = .conferences
                case "news": workspace = .news
                case "messages", "messageCenter": workspace = .messageCenter
                case "accounts": workspace = .accounts
                case "bot": workspace = .bot
                case "newsgroups": workspace = .newsgroups
                case "serverInfo": workspace = .serverInfo
                case "trackers": workspace = .trackers
                case "serverLog": workspace = .serverLog
                case "events": workspace = .events
                case "advanced", "banManagement": workspace = .advanced
                case "agreement": workspace = .agreement
                case "statistics": workspace = .statistics
                default: workspace = nil
                }
                if let workspace { selectWorkspace(workspace) }
            }
            if arguments.contains("--autoconnect") {
                DispatchQueue.main.async { [weak self] in self?.connectPressed(nil) }
            } else if let startupBookmark = serverBookmarks.first(where: \.connectAtLaunch) {
                DispatchQueue.main.async { [weak self] in self?.connect(to: startupBookmark) }
            }
            if arguments.contains("--start-server"),
               serverBackend != nil,
               localServerRuntime?.status.isRunning != true {
                DispatchQueue.main.async { [weak self] in self?.startLocalServer() }
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if currentWorkspace == .conferences || currentWorkspace == .overview {
            updateChannelComposerHeight()
        }
    }

    func buildInterface() {
        view.wantsLayer = true
        view.layer?.backgroundColor = CarrachoTheme.canvas.cgColor

        hostField.placeholderString = "server.example.org"
        portField.placeholderString = "6700"
        loginField.placeholderString = L("Account")
        passwordField.placeholderString = L("Password")
        nicknameField.placeholderString = L("Nickname")
        connectButton.target = self
        connectButton.action = #selector(connectPressed(_:))
        CarrachoTheme.applyPrimaryButtonStyle(connectButton)
        connectButton.keyEquivalent = "\r"

        configureCatalogViews()

        let sidebar = makeSidebar()
        let workspace = makeWorkspaceArea()
        let shellSplit = makeResizableColumnSplit(
            panes: [sidebar, workspace],
            autosaveName: "Carracho.MainColumns",
            edge: .leading,
            initialEdgeWidth: 236,
            minimumPaneWidths: [208, 760]
        )
        shellSplit.identifier = NSUserInterfaceItemIdentifier("mainColumnSplit")
        shellSplit.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shellSplit)
        NSLayoutConstraint.activate([
            shellSplit.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shellSplit.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shellSplit.topAnchor.constraint(equalTo: view.topAnchor),
            shellSplit.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        selectWorkspace(.overview)
    }

    func configureCatalogViews() {
        detailsTextView.isEditable = false
        detailsTextView.isSelectable = true
        detailsTextView.isRichText = false
        detailsTextView.drawsBackground = false
        detailsTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        detailsTextView.textContainerInset = NSSize(width: 12, height: 12)

        configure(table: fileTable, columns: [
            ("name", "Name", 360), ("size", "Size / Contents", 100), ("kind", "Type", 90), ("modified", "Modified", 120),
        ])
        fileTable.usesAlternatingRowBackgroundColors = false
        fileTable.gridStyleMask = []
        fileTable.intercellSpacing = NSSize(width: 0, height: 0)
        fileTable.allowsMultipleSelection = true
        fileTable.allowsEmptySelection = true
        fileTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        fileTable.autosaveName = "Carracho.FilesTable.Columns.v1"
        fileTable.autosaveTableColumns = true
        fileTable.target = self
        fileTable.doubleAction = #selector(openSelectedFileEntry(_:))
        fileTable.registerForDraggedTypes([.fileURL, Self.remoteFileMovePasteboardType])
        fileTable.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Finder-style in-place organization: dragging server items within the Files table
        // moves them; dragging out to Finder keeps the existing download/file-promise copy.
        fileTable.setDraggingSourceOperationMask(.move, forLocal: true)
        fileContextMenu.delegate = self
        fileTable.menu = fileContextMenu
        if let column = fileTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) {
            column.minWidth = 140
            column.resizingMask = [.autoresizingMask, .userResizingMask]
            // Match the Files row guide: Name, folder disclosure arrows and root files share
            // one clean vertical line instead of hugging the table's left border.
            column.headerCell = LeadingInsetTableHeaderCell(textCell: column.title, leadingInset: 14)
        }
        let fileColumnMinimums: [String: CGFloat] = ["size": 86, "kind": 78, "modified": 105]
        for identifier in ["size", "kind", "modified"] {
            if let column = fileTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier)) {
                column.minWidth = fileColumnMinimums[identifier] ?? 70
                column.resizingMask = [.userResizingMask]
            }
        }
        fileBackButton.target = self
        fileBackButton.action = #selector(goBackInFileHistory(_:))
        fileForwardButton.target = self
        fileForwardButton.action = #selector(goForwardInFileHistory(_:))
        fileRefreshButton.target = self
        fileRefreshButton.action = #selector(refreshFilesPressed(_:))
        fileParentButton.target = self
        fileParentButton.action = #selector(goToParentDirectory(_:))
        fileNewFolderButton.target = self
        fileNewFolderButton.action = #selector(createServerFolder(_:))
        fileInfoButton.target = self
        fileInfoButton.action = #selector(editSelectedFileInfo(_:))
        fileQuickViewButton.target = self
        fileQuickViewButton.action = #selector(quickViewSelectedFile(_:))
        fileDeleteButton.target = self
        fileDeleteButton.action = #selector(deleteSelectedServerItem(_:))
        fileDownloadButton.target = self
        fileDownloadButton.action = #selector(downloadSelectedFile(_:))
        fileUploadButton.target = self
        fileUploadButton.action = #selector(uploadFile(_:))
        fileTransferLabel.textColor = CarrachoTheme.secondaryText
        fileTransferLabel.lineBreakMode = .byTruncatingTail
        filePathLabel.lineBreakMode = .byTruncatingMiddle
        filePathLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fileBreadcrumbStack.orientation = .horizontal
        fileBreadcrumbStack.alignment = .centerY
        fileBreadcrumbStack.spacing = 4
        fileBreadcrumbStack.translatesAutoresizingMaskIntoConstraints = false
        fileBreadcrumbStack.heightAnchor.constraint(equalToConstant: 22).isActive = true
        fileBreadcrumbStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileSearchField.placeholderString = L("Search all server files…")
        fileSearchField.toolTip = L("Server-wide recursive filename search. This is not limited to the current folder.")
        fileSearchField.setAccessibilityLabel(L("Search all server files"))
        fileSearchField.target = self
        fileSearchField.action = #selector(searchChanged(_:))
        configureContentFontSizePopup(filesFontSizePopup, selectedSize: filesFontSize, help: L("Files font size"))
        fileEmptyStateRetryButton.target = self
        fileEmptyStateRetryButton.action = #selector(retryFilesPressed(_:))
        fileEmptyStateRetryButton.bezelStyle = .rounded
        fileEmptyStateLabel.alignment = .center
        fileEmptyStateLabel.maximumNumberOfLines = 3
        fileEmptyStateLabel.textColor = CarrachoTheme.secondaryText
        fileLoadingIndicator.style = .spinning
        fileLoadingIndicator.controlSize = .small
        fileLoadingIndicator.isIndeterminate = true
        fileLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        fileLoadingIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        fileLoadingIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true

        configure(table: transferTable, columns: [
            ("name", "File", 390), ("progress", "Progress", 300), ("status", "Status", 260),
        ])
        transferTable.allowsMultipleSelection = true
        transferTable.allowsEmptySelection = true
        transferTable.usesAlternatingRowBackgroundColors = false
        transferTable.gridStyleMask = []
        // Transfer rows are intentionally two-line cells. Keep AppKit from deriving a smaller
        // automatic row height from one of the individual column views and clipping the rest.
        transferTable.usesAutomaticRowHeights = false
        transferTable.rowSizeStyle = .custom
        transferTable.rowHeight = 66
        transferTable.intercellSpacing = NSSize(width: 0, height: 0)
        transferTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        transferTable.target = self
        transferTable.doubleAction = #selector(transferRowDoubleClicked(_:))

        transferScopeControl.selectedSegment = TransferMonitorScope.mine.rawValue
        transferScopeControl.target = self
        transferScopeControl.action = #selector(transferScopeChanged(_:))
        transferScopeControl.controlSize = .regular
        transferScopeControl.setAccessibilityLabel(L("Transfer view"))

        transferFilterControl.selectedSegment = TransferMonitorFilter.all.rawValue
        transferFilterControl.target = self
        transferFilterControl.action = #selector(transferFilterChanged(_:))
        transferFilterControl.controlSize = .small
        transferFilterControl.setAccessibilityLabel(L("Transfer status filter"))

        transferSearchField.placeholderString = L("Filter transfers")
        transferSearchField.target = self
        transferSearchField.action = #selector(transferSearchChanged(_:))
        transferSearchField.sendsSearchStringImmediately = true
        transferSearchField.setAccessibilityLabel(L("Filter transfers"))

        transferRefreshButton.target = self
        transferRefreshButton.action = #selector(refreshTransferMonitorPressed(_:))
        transferRefreshButton.image = symbolImage("arrow.clockwise", fallback: NSImage.refreshTemplateName)
        transferRefreshButton.imagePosition = .imageLeading
        transferRefreshButton.bezelStyle = .rounded
        transferRefreshButton.toolTip = L("Refresh transfer information")

        transferPauseButton.target = self
        transferPauseButton.action = #selector(pauseSelectedTransfer(_:))
        transferResumeButton.target = self
        transferResumeButton.action = #selector(resumeSelectedTransfer(_:))
        transferAbortButton.target = self
        transferAbortButton.action = #selector(abortSelectedRemoteTransfer(_:))
        transferRemoveButton.target = self
        transferRemoveButton.action = #selector(removeSelectedTransfer(_:))
        transferDeletePartialButton.target = self
        transferDeletePartialButton.action = #selector(deleteSelectedTransferPartialData(_:))
        for button in [transferPauseButton, transferResumeButton, transferAbortButton, transferRemoveButton, transferDeletePartialButton] {
            button.controlSize = .small
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 11.5, weight: .medium)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        transferPauseButton.image = symbolImage("pause.fill", fallback: NSImage.touchBarPauseTemplateName)
        transferResumeButton.image = symbolImage("play.fill", fallback: NSImage.touchBarPlayTemplateName)
        transferAbortButton.image = symbolImage("xmark.circle", fallback: NSImage.stopProgressTemplateName)
        transferRemoveButton.image = symbolImage("minus.circle", fallback: NSImage.removeTemplateName)
        transferDeletePartialButton.image = symbolImage("trash", fallback: NSImage.trashEmptyName)
        for button in [transferPauseButton, transferResumeButton, transferAbortButton, transferRemoveButton, transferDeletePartialButton] {
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        transferRemoveButton.toolTip = L("Remove the selected transfer from the monitor list")
        transferDeletePartialButton.toolTip = L("Delete incomplete local/server staging data for the selected transfer")
        transferShowInFinderButton.target = self
        transferShowInFinderButton.action = #selector(showSelectedTransferInFinder(_:))
        transferShowInFinderButton.toolTip = L("Reveal an available local source or completed destination in Finder")
        transferClearButton.target = self
        transferClearButton.action = #selector(clearFinishedTransfers(_:))
        transferClearButton.title = L("Remove Completed from List")
        transferClearButton.toolTip = L("Remove successfully completed transfers from this list only")
        transferClearButton.isEnabled = false
        transferAutoRemoveFinishedCheckbox.title = L("Automatically remove completed transfers from list")
        transferAutoRemoveFinishedCheckbox.target = self
        transferAutoRemoveFinishedCheckbox.action = #selector(transferAutoRemoveFinishedChanged(_:))
        transferAutoRemoveFinishedCheckbox.state = UserDefaults.standard.bool(forKey: Self.transferAutoRemoveFinishedDefaultsKey) ? .on : .off
        transferAutoRemoveFinishedCheckbox.toolTip = L("Only successfully completed transfers are removed; files are never deleted")

        transferViewRateLabel.textColor = CarrachoTheme.secondaryText
        transferViewRateLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        transferViewRateLabel.alignment = .right
        transferViewRateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        transferEmptyStateLabel.textColor = CarrachoTheme.secondaryText
        transferEmptyStateLabel.font = .systemFont(ofSize: 13)
        transferEmptyStateLabel.alignment = .center
        transferEmptyStateLabel.maximumNumberOfLines = 3
        transferEmptyStateLabel.isHidden = true
        transferEmptyStateLabel.setAccessibilityLabel(L("Transfer list status"))

        transferDetailsDisclosureButton.target = self
        transferDetailsDisclosureButton.action = #selector(toggleTransferDetails(_:))
        transferDetailsDisclosureButton.isBordered = false
        transferDetailsDisclosureButton.alignment = .left
        transferDetailsDisclosureButton.font = .systemFont(ofSize: 11.5, weight: .semibold)
        transferDetailsDisclosureButton.imagePosition = .imageLeading
        transferDetailsDisclosureButton.image = symbolImage("chevron.down", fallback: NSImage.touchBarGoDownTemplateName)
        transferDetailsDisclosureButton.toolTip = L("Show or hide selected transfer details")
        for label in [transferDetailNameLabel, transferDetailUserLabel, transferDetailServerLabel,
                      transferDetailLocationLabel, transferDetailStartedLabel, transferDetailErrorLabel] {
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.isSelectable = true
        }
        transferDetailLocationLabel.maximumNumberOfLines = 3
        transferDetailErrorLabel.maximumNumberOfLines = 3
        transferDetailErrorLabel.textColor = .systemRed

        updateTransferActionButtons()
        transferMonitorStatusLabel.textColor = CarrachoTheme.secondaryText
        transferMonitorStatusLabel.font = .systemFont(ofSize: 11)
        transferMonitorStatusLabel.lineBreakMode = .byTruncatingTail
        transferBandwidthField.placeholderString = "0"
        transferBandwidthField.toolTip = L("Enter 0 for unlimited. kb/s means kilobytes per second; Kbit/Mbit are bits per second.")
        transferBandwidthField.alignment = .right
        transferBandwidthField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        transferBandwidthField.target = self
        transferBandwidthField.action = #selector(transferBandwidthChanged(_:))
        transferBandwidthField.isEnabled = false
        transferBandwidthUnitPopup.addItems(withTitles: Self.transferBandwidthUnitTitles)
        transferBandwidthUnitPopup.toolTip = L("Bandwidth unit: kb/s, Kbit/s, Mbit/s or MB/s")
        transferBandwidthUnitPopup.selectItem(at: 3)
        transferBandwidthUnitPopup.target = self
        transferBandwidthUnitPopup.action = #selector(transferBandwidthUnitChanged(_:))
        transferBandwidthUnitPopup.isEnabled = false
        transferBandwidthApplyButton.target = self
        transferBandwidthApplyButton.action = #selector(transferBandwidthChanged(_:))
        transferBandwidthApplyButton.isEnabled = false
        transferBandwidthValueLabel.textColor = CarrachoTheme.secondaryText
        transferBandwidthValueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        transferDownloadSpeedLabel.textColor = CarrachoTheme.secondaryText
        transferDownloadSpeedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        configure(table: trackerBrowserTable, columns: [
            ("name", "Server", 240), ("users", "Users", 75), ("address", "Address", 150),
            ("description", "Description", 280), ("bandwidth", "Bandwidth", 145), ("visibility", "Visibility", 90),
        ])
        trackerBrowserTable.target = self
        trackerBrowserTable.doubleAction = #selector(connectSelectedTrackerServer(_:))
        trackerBrowserTable.rowHeight = 32
        trackerBrowserStatusLabel.textColor = CarrachoTheme.secondaryText
        trackerBrowserStatusLabel.font = .systemFont(ofSize: 11)

        configure(table: userTable, columns: [("nickname", "User", 270)])
        userTable.headerView = nil
        userTable.usesAlternatingRowBackgroundColors = false
        userTable.target = self
        userTable.doubleAction = #selector(showSelectedUserInfo(_:))
        userTable.rowHeight = 46
        userContextMenu.delegate = self
        userTable.menu = userContextMenu
        userInfoButton.target = self
        userInfoButton.action = #selector(showSelectedUserInfo(_:))
        userMessageButton.target = self
        userMessageButton.action = #selector(messageSelectedUser(_:))
        userOfflineMessageButton.target = self
        userOfflineMessageButton.action = #selector(sendOfflineMessage(_:))
        userDisconnectButton.target = self
        userDisconnectButton.action = #selector(kickSelectedUser(_:))
        userBanButton.target = self
        userBanButton.action = #selector(banSelectedUser(_:))
        presenceButton.target = self
        presenceButton.action = #selector(toggleOwnPresence(_:))

        configure(table: channelTable, columns: [("name", "Room", 430)])
        channelTable.headerView = nil
        channelTable.usesAlternatingRowBackgroundColors = false
        channelTable.allowsEmptySelection = true
        channelTable.rowHeight = 52
        channelTable.intercellSpacing = NSSize(width: 0, height: 2)
        channelTable.target = self
        channelTable.doubleAction = #selector(joinSelectedChannel(_:))

        configure(table: channelMemberTable, columns: [("member", "Participant", 260)])
        channelMemberTable.headerView = nil
        channelMemberTable.usesAlternatingRowBackgroundColors = false
        channelMemberTable.allowsEmptySelection = true
        channelMemberTable.rowHeight = 48
        channelMemberTable.intercellSpacing = NSSize(width: 0, height: 2)
        channelMemberTable.target = self
        channelMemberTable.doubleAction = #selector(showSelectedChannelMemberInfo(_:))

        channelJoinButton.target = self
        channelJoinButton.action = #selector(joinSelectedChannel(_:))
        channelJoinButton.title = L("Join")
        channelJoinButton.bezelStyle = .rounded

        channelLeaveButton.target = self
        channelLeaveButton.action = #selector(leaveCurrentChannel(_:))
        channelLeaveButton.title = L("Leave Room")

        channelNewButton.target = self
        channelNewButton.action = #selector(createChannel(_:))
        channelNewButton.title = L("New Room")

        channelDiscoverButton.target = self
        channelDiscoverButton.action = #selector(showChannelDiscovery(_:))
        channelDiscoverButton.image = symbolImage("magnifyingglass", fallback: NSImage.revealFreestandingTemplateName)
        channelDiscoverButton.imagePosition = .imageLeading
        channelDiscoverButton.imageHugsTitle = true
        channelDiscoverButton.toolTip = L("Browse rooms available on this server")
        channelDiscoverButton.setAccessibilityLabel(L("Discover chat rooms"))

        channelSettingsButton.target = self
        channelSettingsButton.action = #selector(editChannelSettings(_:))
        channelSettingsButton.title = L("Room Settings…")

        channelInviteButton.target = self
        channelInviteButton.action = #selector(inviteUserToActiveChannel(_:))
        channelInviteButton.title = L("Invite User…")

        channelModeButton.target = self
        channelModeButton.action = #selector(editSelectedChannelMemberMode(_:))
        channelModeButton.title = L("Manage Role…")

        channelSendButton.target = self
        channelSendButton.action = #selector(sendChannelChat(_:))
        channelSendButton.keyEquivalent = "\r"
        channelSendButton.keyEquivalentModifierMask = []
        channelSendButton.setAccessibilityLabel(L("Send chat message"))

        channelClearButton.target = self
        channelClearButton.action = #selector(clearActiveChannelTranscript(_:))
        styleIconButton(channelClearButton, symbol: "trash", help: L("Clear local chat history"))
        channelClearButton.isHidden = true

        channelTopicEditButton.target = self
        channelTopicEditButton.action = #selector(editChannelSettings(_:))
        channelTopicEditButton.bezelStyle = .inline
        channelTopicEditButton.controlSize = .small
        channelTopicEditButton.contentTintColor = CarrachoTheme.selection
        channelTopicEditButton.toolTip = L("Edit the room topic")
        channelTopicEditButton.setAccessibilityLabel(L("Edit room topic"))

        channelHeaderSettingsButton.target = self
        channelHeaderSettingsButton.action = #selector(editChannelSettings(_:))
        channelHeaderSettingsButton.title = ""
        channelHeaderSettingsButton.image = symbolImage("gearshape", fallback: NSImage.actionTemplateName)
        channelHeaderSettingsButton.imagePosition = .imageOnly
        channelHeaderSettingsButton.controlSize = .small
        channelHeaderSettingsButton.bezelStyle = .inline
        channelHeaderSettingsButton.focusRingType = .none
        channelHeaderSettingsButton.contentTintColor = CarrachoTheme.secondaryText
        channelHeaderSettingsButton.toolTip = L("Room Settings…")
        channelHeaderSettingsButton.setAccessibilityLabel(L("Room Settings…"))
        channelHeaderSettingsButton.isHidden = true
        channelHeaderSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            channelHeaderSettingsButton.widthAnchor.constraint(equalToConstant: 30),
            channelHeaderSettingsButton.heightAnchor.constraint(equalToConstant: 26),
        ])
        channelRoomSwitchButton.target = self
        channelRoomSwitchButton.action = #selector(showChannelRoomSwitchMenu(_:))
        styleIconButton(channelRoomSwitchButton, symbol: "chevron.down", help: L("Switch chat room"))
        channelMemberActionsButton.target = self
        channelMemberActionsButton.action = #selector(showChannelMemberActions(_:))
        styleIconButton(channelMemberActionsButton, symbol: "ellipsis", help: L("Participant actions"))

        channelAttachButton.target = self
        channelAttachButton.action = #selector(attachImageToChannel(_:))
        channelYouTubeButton.target = self
        channelYouTubeButton.action = #selector(attachYouTubeToChannel(_:))

        channelMessageField.delegate = self
        channelMessageField.imageFileHandler = { [weak self] urls in self?.uploadChannelImages(urls: urls) }
        channelMessageField.imageDataHandler = { [weak self] data in self?.uploadChannelImage(data: data) }
        channelMessageField.youTubeURLHandler = { [weak self] reference in
            guard let self,
                  self.client.isConnected,
                  self.activeChannel != nil,
                  self.lastLoginResult?.supportsYouTubeLinks == true,
                  self.channelAttachmentStrip.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerChatMessage else { return false }
            self.channelAttachmentStrip.addYouTube(reference)
            return true
        }
        channelMessageField.isRichText = false
        channelMessageField.allowsUndo = true
        channelMessageField.isAutomaticQuoteSubstitutionEnabled = false
        channelMessageField.isAutomaticDashSubstitutionEnabled = false
        channelMessageField.isHorizontallyResizable = false
        channelMessageField.isVerticallyResizable = true
        channelMessageField.autoresizingMask = [.width]
        channelMessageField.textContainer?.widthTracksTextView = true
        channelMessageField.textContainerInset = NSSize(width: 10, height: 9)
        channelMessageField.font = .systemFont(ofSize: 13)
        channelMessageField.drawsBackground = false
        channelMessageField.toolTip = CarrachoHTMLText.editorHint
        channelMessageField.setAccessibilityLabel(L("Chat message"))

        channelAttachmentStrip.onChange = { [weak self] in
            guard let self else { return }
            if !self.isRestoringChannelComposer { self.persistActiveChannelComposerDraft() }
            self.reloadChannelView(reloadTables: false)
        }
        channelAttachmentStrip.onRemoveImage = { [weak self] id in self?.deletePendingMedia(id) }
        channelChatTextView.mediaDeleteHandler = { [weak self] id in self?.confirmDeletePostedMedia(id) }

        channelComposerPlaceholderLabel.font = .systemFont(ofSize: 13)
        channelComposerPlaceholderLabel.textColor = CarrachoTheme.tertiaryText
        channelComposerPlaceholderLabel.isEnabled = false
        channelComposerPlaceholderLabel.setAccessibilityElement(false)
        channelComposerStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        channelComposerStatusLabel.textColor = CarrachoTheme.secondaryText
        channelComposerStatusLabel.maximumNumberOfLines = 2
        channelComposerStatusLabel.lineBreakMode = .byWordWrapping
        channelComposerHintLabel.font = .systemFont(ofSize: 10.5)
        channelComposerHintLabel.textColor = CarrachoTheme.tertiaryText
        channelComposerHintLabel.alignment = .right
        channelComposerHintLabel.lineBreakMode = .byTruncatingHead

        configureContentFontSizePopup(channelChatFontSizePopup, selectedSize: channelChatFontSize, help: L("Conference chat font size"))
        channelTitleLabel.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        channelChatTextView.isEditable = false
        channelChatTextView.isSelectable = true
        channelChatTextView.isRichText = true
        channelChatTextView.isAutomaticLinkDetectionEnabled = true
        channelChatTextView.useCarrachoLinkAppearance()
        channelChatTextView.drawsBackground = false
        channelChatTextView.font = NSFont.systemFont(ofSize: channelChatFontSize)
        channelChatTextView.textContainerInset = NSSize(width: 18, height: 16)

        configure(table: newsTable, columns: [("name", "Category", 360)])
        configure(table: newsArticleTable, columns: [
            ("subject", "Subject", 360),
            ("sender", "Nick", 150),
            ("replies", "Replies", 74),
            ("date", "Posted", 150),
            ("activity", "Last Post", 160),
        ])

        // Categories remain a card-like one-column list. Topics intentionally use a real table
        // header like the classic Carracho client: Subject, Nick, Replies, Posted and Last Post.
        newsTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        if let column = newsTable.tableColumns.first {
            column.resizingMask = [.autoresizingMask]
            column.minWidth = 80
        }
        newsTable.headerView = nil

        newsArticleTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let topicMinimumWidths: [String: CGFloat] = [
            "subject": 120, "sender": 80, "replies": 58, "date": 100, "activity": 110,
        ]
        for column in newsArticleTable.tableColumns {
            column.minWidth = topicMinimumWidths[column.identifier.rawValue] ?? 60
            column.resizingMask = column.identifier.rawValue == "subject"
                ? [.autoresizingMask, .userResizingMask]
                : [.userResizingMask]
            if column.identifier.rawValue == "subject" {
                // Match the Subject header to the actual topic text inset in the first column.
                column.headerCell = LeadingInsetTableHeaderCell(textCell: column.title, leadingInset: 10)
            }
        }
        newsArticleTable.headerView = NSTableHeaderView()

        for table in [newsTable, newsArticleTable] {
            table.usesAlternatingRowBackgroundColors = false
            table.allowsEmptySelection = true
            table.selectionHighlightStyle = .regular
        }
        newsTable.intercellSpacing = NSSize(width: 0, height: 2)
        newsArticleTable.intercellSpacing = NSSize(width: 0, height: 0)
        newsArticleTable.gridStyleMask = []
        newsTable.target = self
        newsTable.doubleAction = #selector(loadSelectedNewsgroup(_:))
        newsArticleTable.target = self
        newsArticleTable.doubleAction = #selector(openSelectedNewsThread(_:))
        newsLoadButton.target = self
        newsLoadButton.action = #selector(loadSelectedNewsgroup(_:))

        newsNewCategoryButton.target = self
        newsNewCategoryButton.action = #selector(createNewsCategoryFromNews(_:))
        styleIconButton(newsNewCategoryButton, symbol: "plus", help: L("Create News category"))

        newsPostButton.target = self
        newsPostButton.action = #selector(showArticleEditor(_:))
        newsPostButton.image = symbolImage("plus", fallback: NSImage.addTemplateName)
        newsPostButton.imagePosition = .imageLeading
        newsPostButton.font = .systemFont(ofSize: 12.5, weight: .semibold)
        CarrachoTheme.applyPrimaryButtonStyle(newsPostButton)
        newsPostButton.toolTip = L("Create a topic in the selected category")
        newsPostButton.setAccessibilityLabel(L("New News topic"))

        newsReplyButton.target = self
        newsReplyButton.action = #selector(sendInlineNewsReply(_:))
        newsReplyButton.font = .systemFont(ofSize: 12.5, weight: .semibold)
        CarrachoTheme.applyPrimaryButtonStyle(newsReplyButton)
        newsReplyButton.keyEquivalent = "\r"
        newsReplyButton.keyEquivalentModifierMask = [.command]
        newsReplyButton.toolTip = L("Send reply (⌘Return)")
        newsReplyButton.setAccessibilityLabel(L("Send News reply"))

        newsDeleteButton.target = self
        newsDeleteButton.action = #selector(deleteCurrentArticle(_:))
        newsDeleteButton.isHidden = true

        styleIconButton(newsThreadActionsButton, symbol: "ellipsis", help: L("Topic actions"))
        newsThreadActionsButton.target = self
        newsThreadActionsButton.action = #selector(showNewsThreadActions(_:))
        styleIconButton(newsRefreshButton, symbol: "arrow.clockwise", help: L("Refresh News"))
        newsRefreshButton.target = self
        newsRefreshButton.action = #selector(refreshCurrentNews(_:))

        newsThreadSortPopup.addItems(withTitles: [L("Latest Activity"), L("Title"), L("Author"), L("Replies")])
        newsThreadSortPopup.selectItem(at: 0)
        newsThreadSortPopup.target = self
        newsThreadSortPopup.action = #selector(newsThreadSortChanged(_:))
        newsThreadSortPopup.controlSize = .small
        newsThreadSortPopup.toolTip = L("Sort topics")
        newsThreadSortPopup.setAccessibilityLabel(L("Sort News topics"))

        newsTitleLabel.font = NSFont.systemFont(ofSize: 23, weight: .bold)
        newsTitleLabel.lineBreakMode = .byTruncatingTail
        newsTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newsBreadcrumbLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        newsBreadcrumbLabel.textColor = CarrachoTheme.secondaryText
        newsBreadcrumbLabel.lineBreakMode = .byTruncatingTail
        newsBreadcrumbLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newsCategoryHeaderLabel.font = .systemFont(ofSize: 11, weight: .bold)
        newsCategoryHeaderLabel.textColor = CarrachoTheme.secondaryText
        newsThreadsHeaderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        newsThreadsHeaderLabel.lineBreakMode = .byTruncatingTail
        newsThreadsHeaderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newsThreadMetaLabel.font = .systemFont(ofSize: 12)
        newsThreadMetaLabel.textColor = CarrachoTheme.secondaryText
        newsThreadMetaLabel.lineBreakMode = .byTruncatingTail
        newsThreadMetaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        newsArticleTextView.isEditable = false
        newsArticleTextView.isSelectable = true
        newsArticleTextView.isRichText = true
        newsArticleTextView.isAutomaticLinkDetectionEnabled = true
        newsArticleTextView.drawsBackground = false
        newsArticleTextView.useCarrachoLinkAppearance()
        newsArticleTextView.font = NSFont.systemFont(ofSize: newsFontSize)
        newsArticleTextView.textContainerInset = NSSize(width: 18, height: 16)
        newsArticleTextView.mediaDeleteHandler = { [weak self] id in self?.confirmDeletePostedMedia(id) }
        newsArticleTextView.appLinkHandler = { [weak self] link in
            self?.handleNewsInlineLink(link) ?? false
        }

        newsReplyTextView.isRichText = false
        newsReplyTextView.allowsUndo = true
        newsReplyTextView.isAutomaticQuoteSubstitutionEnabled = false
        newsReplyTextView.isAutomaticDashSubstitutionEnabled = false
        newsReplyTextView.font = .systemFont(ofSize: newsFontSize)
        newsReplyTextView.textContainerInset = NSSize(width: 10, height: 8)
        newsReplyTextView.isHorizontallyResizable = false
        newsReplyTextView.isVerticallyResizable = true
        newsReplyTextView.autoresizingMask = [.width]
        newsReplyTextView.textContainer?.widthTracksTextView = true
        newsReplyTextView.toolTip = CarrachoHTMLText.editorHint
        newsReplyTextView.imageFileHandler = { [weak self] urls in self?.uploadInlineNewsReplyImages(urls: urls) }
        newsReplyTextView.imageDataHandler = { [weak self] data in self?.uploadInlineNewsReplyImage(data: data) }
        newsReplyTextView.youTubeURLHandler = { [weak self] reference in
            guard let self,
                  self.currentNewsThreadID != nil,
                  self.lastLoginResult?.supportsYouTubeLinks == true,
                  self.newsReplyAttachments.youtubeCount < LegacyMediaTransfer.maximumYouTubeLinksPerNewsPost else { return false }
            self.newsReplyAttachments.addYouTube(reference)
            self.saveInlineNewsReplyDraft()
            self.updateInlineNewsReplyState()
            return true
        }

        newsReplyAttachments.onRemoveImage = { [weak self] id in self?.deletePendingMedia(id) }
        newsReplyAttachments.onChange = { [weak self] in self?.updateInlineNewsReplyState() }
        newsReplyTargetLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        newsReplyTargetLabel.textColor = CarrachoTheme.secondaryText
        newsReplyTargetLabel.lineBreakMode = .byTruncatingTail
        newsReplyTargetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        styleIconButton(newsReplyClearTargetButton, symbol: "xmark.circle.fill", help: L("Reply to the topic instead"))
        newsReplyClearTargetButton.target = self
        newsReplyClearTargetButton.action = #selector(clearInlineNewsReplyTarget(_:))
        newsReplyValidationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        newsReplyValidationLabel.textColor = .systemRed
        newsReplyValidationLabel.maximumNumberOfLines = 2
        newsReplyValidationLabel.isHidden = true

        newsReplyAttachButton.target = self
        newsReplyAttachButton.action = #selector(attachImageToInlineNewsReply(_:))
        newsReplyAttachButton.controlSize = .small
        newsReplyAttachButton.image = symbolImage("photo", fallback: NSImage.addTemplateName)
        newsReplyAttachButton.imagePosition = .imageLeading
        newsReplyYouTubeButton.target = self
        newsReplyYouTubeButton.action = #selector(attachYouTubeToInlineNewsReply(_:))
        newsReplyYouTubeButton.controlSize = .small
        newsReplyYouTubeButton.image = symbolImage("play.rectangle", fallback: NSImage.addTemplateName)
        newsReplyYouTubeButton.imagePosition = .imageLeading

        newsReplySendingIndicator.style = .spinning
        newsReplySendingIndicator.controlSize = .small
        newsReplySendingIndicator.isIndeterminate = true
        newsReplySendingIndicator.isHidden = true
        newsReplySendingIndicator.translatesAutoresizingMaskIntoConstraints = false
        newsReplySendingIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        newsReplySendingIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true

        configureContentFontSizePopup(newsFontSizePopup, selectedSize: newsFontSize, help: L("News font size"))
        applyFilesFontSize()
        applyNewsFontSize()
    }

    func configure(table: NSTableView, columns: [(String, String, CGFloat)]) {
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = CarrachoTheme.tableBackground
        table.gridStyleMask = []
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        if #available(macOS 11.0, *) { table.style = .plain }
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = L(title)
            column.width = width
            column.minWidth = identifier == "name" ? 150 : 65
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            table.addTableColumn(column)
        }
    }

    func sortDescriptor(for table: NSTableView) -> (key: String, ascending: Bool)? {
        guard let descriptor = table.sortDescriptors.first, let key = descriptor.key else { return nil }
        return (key, descriptor.ascending)
    }

    func sortedForTable<T>(_ values: [T], table: NSTableView,
                                   defaultCompare: ((T, T) -> ComparisonResult)? = nil,
                                   compare: (T, T, String) -> ComparisonResult) -> [T] {
        let descriptor = sortDescriptor(for: table)
        guard descriptor != nil || defaultCompare != nil else { return values }
        return values.enumerated().sorted { lhs, rhs in
            let result: ComparisonResult
            if let descriptor {
                result = compare(lhs.element, rhs.element, descriptor.key)
                if result != .orderedSame {
                    return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
                }
            } else if let defaultCompare {
                result = defaultCompare(lhs.element, rhs.element)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func compareText(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedStandardCompare(rhs)
    }

    static func compareNumber<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    static func accountTransferByteString(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func compareOptionalDate(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?): return compareNumber(left, right)
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        }
    }

    func verticallyCenteredTableContent(_ content: NSView, fillWidth: Bool = false, leadingInset: CGFloat = 0, trailingInset: CGFloat = 0) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        let trailing = fillWidth
            ? content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -trailingInset)
            : content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -trailingInset)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),
            trailing,
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 2),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }

    func sidebarBlock(from view: NSView) -> SidebarBlock? {
        guard let raw = view.identifier?.rawValue,
              raw.hasPrefix(sidebarBlockViewIdentifierPrefix) else { return nil }
        return SidebarBlock(rawValue: String(raw.dropFirst(sidebarBlockViewIdentifierPrefix.count)))
    }

    func savedSidebarBlockOrder() -> [SidebarBlock] {
        let stored = UserDefaults.standard.stringArray(forKey: Self.sidebarBlockOrderDefaultsKey) ?? []
        var seen = Set<SidebarBlock>()
        var order: [SidebarBlock] = []
        for raw in stored {
            guard let block = SidebarBlock(rawValue: raw), seen.insert(block).inserted else { continue }
            order.append(block)
        }
        for block in SidebarBlock.allCases where seen.insert(block).inserted { order.append(block) }
        return order
    }

    func applySidebarBlockOrder(_ requestedOrder: [SidebarBlock]) {
        // Sidebar modules are always siblings. Rebuild only the arranged list at one level
        // and recreate the edge constraints so reordered blocks keep the full sidebar width.
        var seen = Set<SidebarBlock>()
        var order = requestedOrder.filter { seen.insert($0).inserted }
        for block in SidebarBlock.allCases where seen.insert(block).inserted { order.append(block) }

        NSLayoutConstraint.deactivate(sidebarBlockEdgeConstraints)
        sidebarBlockEdgeConstraints.removeAll(keepingCapacity: true)

        // Rebuild only the arranged-subview order. Once a block already belongs to the
        // sidebar stack, keep it attached as a normal subview while reordering. Detaching the
        // dragged block from the window during `performDragOperation` can terminate AppKit's
        // source callbacks early and used to make its drag handle work exactly once per launch.
        for block in SidebarBlock.allCases {
            guard let view = sidebarBlockViews[block] else { continue }
            if let parentStack = view.superview as? NSStackView,
               parentStack.arrangedSubviews.contains(where: { $0 === view }) {
                parentStack.removeArrangedSubview(view)
            }
            if view.superview !== sidebarBlockStack {
                // Initial construction, or recovery from an unexpected parent: make the block
                // a direct child before adding it back as an arranged subview. This also keeps
                // the sidebar strictly flat and prevents block nesting.
                view.removeFromSuperview()
            }
        }

        for (index, block) in order.enumerated() {
            guard let view = sidebarBlockViews[block] else { continue }
            sidebarBlockStack.insertArrangedSubview(view, at: min(index, sidebarBlockStack.arrangedSubviews.count))
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebarBlockEdgeConstraints.append(contentsOf: [
                view.leadingAnchor.constraint(equalTo: sidebarBlockStack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: sidebarBlockStack.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate(sidebarBlockEdgeConstraints)
        sidebarBlockStack.needsLayout = true
    }

    func moveSidebarBlock(identifier: String, to destinationIndex: Int) {
        guard let block = SidebarBlock(rawValue: identifier) else { return }
        var order = sidebarBlockStack.arrangedSubviews.compactMap(sidebarBlock(from:))
        for missing in SidebarBlock.allCases where !order.contains(missing) { order.append(missing) }
        guard order.contains(block) else { return }
        order.removeAll { $0 == block }
        order.insert(block, at: min(max(0, destinationIndex), order.count))
        UserDefaults.standard.set(order.map(\.rawValue), forKey: Self.sidebarBlockOrderDefaultsKey)
        applySidebarBlockOrder(order)
    }

    func plainSidebarBlockHeader(_ title: String, block: SidebarBlock,
                                         addAction: Selector? = nil,
                                         addHelp: String? = nil) -> (NSView, SidebarBlockDragHandle) {
        let label = sidebarSectionLabel(L(title))
        let handle = SidebarBlockDragHandle(blockIdentifier: block.rawValue)
        var items: [NSView] = [label, NSView()]
        if let addAction {
            let add = NSButton()
            add.target = self
            add.action = addAction
            add.image = symbolImage("plus", fallback: NSImage.addTemplateName)
            add.imagePosition = .imageOnly
            add.isBordered = false
            add.contentTintColor = CarrachoTheme.secondaryText
            add.toolTip = addHelp.map(L)
            add.setAccessibilityLabel(addHelp.map(L) ?? L("Add"))
            add.translatesAutoresizingMaskIntoConstraints = false
            add.widthAnchor.constraint(equalToConstant: 20).isActive = true
            add.heightAnchor.constraint(equalToConstant: 20).isActive = true
            items.append(add)
        }
        items.append(handle)
        let row = horizontalStack(items, spacing: 4)
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return (row, handle)
    }

    func collapsibleSidebarBlockHeader(_ title: String,
                                       block: SidebarBlock,
                                       collapsed: Bool,
                                       action: Selector,
                                       addAction: Selector? = nil,
                                       addHelp: String? = nil) -> (NSView, SidebarBlockDragHandle, NSButton) {
        let button = collapsibleSidebarSectionButton(title: title, collapsed: collapsed, action: action)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let handle = SidebarBlockDragHandle(blockIdentifier: block.rawValue)
        var items: [NSView] = [button, NSView()]
        if let addAction {
            let add = NSButton()
            add.target = self
            add.action = addAction
            add.image = symbolImage("plus", fallback: NSImage.addTemplateName)
            add.imagePosition = .imageOnly
            add.isBordered = false
            add.contentTintColor = CarrachoTheme.secondaryText
            add.toolTip = addHelp.map(L)
            add.setAccessibilityLabel(addHelp.map(L) ?? L("Add"))
            add.translatesAutoresizingMaskIntoConstraints = false
            add.widthAnchor.constraint(equalToConstant: 20).isActive = true
            add.heightAnchor.constraint(equalToConstant: 20).isActive = true
            items.append(add)
        }
        items.append(handle)
        let row = horizontalStack(items, spacing: 4)
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return (row, handle, button)
    }

    func collapsibleSidebarBlockHeader(_ button: NSButton,
                                               block: SidebarBlock) -> (NSView, SidebarBlockDragHandle) {
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let handle = SidebarBlockDragHandle(blockIdentifier: block.rawValue)
        let row = horizontalStack([button, NSView(), handle], spacing: 4)
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return (row, handle)
    }

    func configureSidebarBlock(_ view: NSView, block: SidebarBlock,
                                       handle: SidebarBlockDragHandle) {
        view.identifier = NSUserInterfaceItemIdentifier(sidebarBlockViewIdentifierPrefix + block.rawValue)
        handle.draggedView = view
    }

    func makeSidebar() -> NSView {
        let sidebar = CarrachoBackgroundView()
        sidebar.fillColor = CarrachoTheme.sidebar
        let logo = NSImageView()
        logo.image = NSImage(named: "CarrachoLogo")
        logo.imageScaling = .scaleProportionallyDown
        logo.imageAlignment = .alignLeft
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 196).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 66).isActive = true

        bookmarkStack.orientation = .vertical
        bookmarkStack.alignment = .leading
        bookmarkStack.spacing = 2
        bookmarkStack.translatesAutoresizingMaskIntoConstraints = false
        reloadBookmarkStack()

        trackerStack.orientation = .vertical
        trackerStack.alignment = .leading
        trackerStack.spacing = 2
        trackerStack.translatesAutoresizingMaskIntoConstraints = false
        reloadTrackerStack()

        let overviewButton = makeSidebarButton(.overview)
        let filesButton = makeSidebarButton(.files)
        let transfersButton = makeSidebarButton(.transfers)
        let newsButton = makeSidebarButton(.news)
        let messageCenterButton = makeSidebarButton(.messageCenter)
        joinedChannelSidebarStack.orientation = .vertical
        joinedChannelSidebarStack.alignment = .leading
        joinedChannelSidebarStack.spacing = 2
        joinedChannelSidebarStack.translatesAutoresizingMaskIntoConstraints = false

        CarrachoTheme.applySidebarButtonStyle(channelDiscoverButton, selected: false)
        channelDiscoverButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        channelNewButton.image = symbolImage("plus", fallback: NSImage.addTemplateName)
        channelNewButton.imagePosition = .imageLeading
        channelNewButton.imageHugsTitle = true
        CarrachoTheme.applySidebarButtonStyle(channelNewButton, selected: false)
        channelNewButton.alignment = .left
        channelNewButton.font = .systemFont(ofSize: 12)
        channelNewButton.contentTintColor = CarrachoTheme.secondaryText
        channelNewButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        channelNewButton.toolTip = L("Create a temporary chat room")
        channelNewButton.setAccessibilityLabel(L("Create new chat room"))

        let conferencesCollapsed = UserDefaults.standard.bool(forKey: Self.conferencesSidebarCollapsedDefaultsKey)
        let conferencesHeader = collapsibleSidebarNavigationButton(
            title: "Conferences", collapsed: conferencesCollapsed,
            action: #selector(toggleConferencesSidebarSection(_:))
        )
        let conferencesContent = NSStackView(views: [
            joinedChannelSidebarStack, channelDiscoverButton, channelNewButton,
        ])
        conferencesContent.orientation = .vertical
        conferencesContent.alignment = .leading
        conferencesContent.spacing = 2
        conferencesContent.edgeInsets = NSEdgeInsets(top: 0, left: 28, bottom: 0, right: 0)
        for child in conferencesContent.arrangedSubviews {
            child.translatesAutoresizingMaskIntoConstraints = false
            // NSStackView alignment is an edge, not a sizing rule. Explicitly fill the
            // inset content width so every row shares the same icon and text columns.
            child.widthAnchor.constraint(equalTo: conferencesContent.widthAnchor, constant: -28).isActive = true
            conferencesContent.setVisibilityPriority(.mustHold, for: child)
        }
        conferencesContent.isHidden = conferencesCollapsed
        conferencesSidebarHeader = conferencesHeader
        conferencesSidebarContent = conferencesContent
        let conferenceNavigation = verticalStack([conferencesHeader, conferencesContent], spacing: 2)
        conferenceNavigation.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        userOfflineMessageButton.title = L("Send Offline Messages")
        userOfflineMessageButton.image = symbolImage("envelope", fallback: NSImage.shareTemplateName)
        userOfflineMessageButton.showsOfflineSlash = true
        userOfflineMessageButton.imagePosition = .imageLeading
        userOfflineMessageButton.imageHugsTitle = true
        userOfflineMessageButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        userOfflineMessageButton.toolTip = L("Send an offline message to an account that accepts offline messages")
        CarrachoTheme.applySidebarButtonStyle(userOfflineMessageButton, selected: false)

        broadcastButton.target = self
        broadcastButton.action = #selector(broadcastPressed(_:))
        broadcastButton.title = L("Broadcast")
        broadcastButton.image = symbolImage("megaphone", fallback: NSImage.shareTemplateName)
        broadcastButton.imagePosition = .imageLeading
        broadcastButton.imageHugsTitle = true
        broadcastButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        broadcastButton.toolTip = L("Send a broadcast message to every connected user")
        CarrachoTheme.applySidebarButtonStyle(broadcastButton, selected: false)
        broadcastButton.isHidden = true

        let adminWorkspaces: [Workspace] = [.accounts, .bot, .advanced, .agreement, .events, .newsgroups, .serverInfo, .serverLog, .statistics, .trackers]
        let adminButtons = adminWorkspaces.map(makeSidebarButton)

        let serverCollapsed = UserDefaults.standard.bool(forKey: Self.serverSidebarCollapsedDefaultsKey)
        let serverHeader = collapsibleSidebarSectionButton(title: "SERVER", collapsed: serverCollapsed,
                                                           action: #selector(toggleServerSidebarSection(_:)))
        let serverContent = verticalStack([
            overviewButton, conferenceNavigation, filesButton, transfersButton, newsButton, messageCenterButton, userOfflineMessageButton,
        ], spacing: 3)
        serverContent.isHidden = serverCollapsed
        serverSidebarHeader = serverHeader
        serverSidebarContent = serverContent
        reloadJoinedChannelSidebar()

        let administrationCollapsed = UserDefaults.standard.bool(forKey: Self.administrationSidebarCollapsedDefaultsKey)
        let adminHeader = collapsibleSidebarSectionButton(title: "ADMINISTRATION", collapsed: administrationCollapsed,
                                                          action: #selector(toggleAdministrationSidebarSection(_:)))
        let adminContent = verticalStack(Array(adminButtons.prefix(3)) + [broadcastButton] + Array(adminButtons.dropFirst(3)), spacing: 3)
        administrationSidebarHeader = adminHeader
        administrationSidebarContent = adminContent
        adminHeader.isHidden = true
        adminContent.isHidden = true
        adminButtons.forEach { $0.isHidden = true }

        let bookmarksCollapsed = UserDefaults.standard.bool(forKey: Self.bookmarkSidebarCollapsedDefaultsKey)
        let (bookmarkHeader, bookmarkDragHandle, bookmarkCollapseButton) = collapsibleSidebarBlockHeader(
            "BOOKMARKS", block: .bookmarks, collapsed: bookmarksCollapsed,
            action: #selector(toggleBookmarkSidebarSection(_:)),
            addAction: #selector(addServerPressed(_:)), addHelp: "Add Server"
        )
        bookmarkStack.isHidden = bookmarksCollapsed
        bookmarkSidebarHeader = bookmarkCollapseButton
        let bookmarkBlock = verticalStack([bookmarkHeader, bookmarkStack], spacing: 3)
        configureSidebarBlock(bookmarkBlock, block: .bookmarks, handle: bookmarkDragHandle)
        NSLayoutConstraint.activate([
            bookmarkHeader.widthAnchor.constraint(equalTo: bookmarkBlock.widthAnchor),
            bookmarkStack.widthAnchor.constraint(equalTo: bookmarkBlock.widthAnchor),
        ])

        let trackersCollapsed = UserDefaults.standard.bool(forKey: Self.trackerSidebarCollapsedDefaultsKey)
        let (trackerHeader, trackerDragHandle, trackerCollapseButton) = collapsibleSidebarBlockHeader(
            "TRACKERS", block: .trackers, collapsed: trackersCollapsed,
            action: #selector(toggleTrackerSidebarSection(_:)),
            addAction: #selector(addClientTrackerPressed(_:)), addHelp: "Add Tracker"
        )
        trackerStack.isHidden = trackersCollapsed
        trackerSidebarHeader = trackerCollapseButton
        let trackerBlock = verticalStack([trackerHeader, trackerStack], spacing: 3)
        configureSidebarBlock(trackerBlock, block: .trackers, handle: trackerDragHandle)
        NSLayoutConstraint.activate([
            trackerHeader.widthAnchor.constraint(equalTo: trackerBlock.widthAnchor),
            trackerStack.widthAnchor.constraint(equalTo: trackerBlock.widthAnchor),
        ])

        let (serverHeaderRow, serverDragHandle) = collapsibleSidebarBlockHeader(serverHeader, block: .server)
        let serverBlock = verticalStack([serverHeaderRow, serverContent], spacing: 5)
        configureSidebarBlock(serverBlock, block: .server, handle: serverDragHandle)
        NSLayoutConstraint.activate([
            serverHeaderRow.widthAnchor.constraint(equalTo: serverBlock.widthAnchor),
            serverContent.widthAnchor.constraint(equalTo: serverBlock.widthAnchor),
        ])

        let (adminHeaderRow, adminDragHandle) = collapsibleSidebarBlockHeader(adminHeader, block: .administration)
        let adminBlock = verticalStack([adminHeaderRow, adminContent], spacing: 5)
        NSLayoutConstraint.activate([
            adminHeaderRow.widthAnchor.constraint(equalTo: adminBlock.widthAnchor),
            adminContent.widthAnchor.constraint(equalTo: adminBlock.widthAnchor),
        ])
        configureSidebarBlock(adminBlock, block: .administration, handle: adminDragHandle)
        adminBlock.isHidden = true
        administrationSidebarBlock = adminBlock

        sidebarBlockViews = [
            .bookmarks: bookmarkBlock,
            .trackers: trackerBlock,
            .server: serverBlock,
            .administration: adminBlock,
        ]
        for view in sidebarBlockStack.arrangedSubviews {
            sidebarBlockStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        sidebarBlockStack.orientation = .vertical
        sidebarBlockStack.alignment = .leading
        sidebarBlockStack.spacing = 11
        sidebarBlockStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarBlockStack.onMoveBlock = { [weak self] identifier, index in
            self?.moveSidebarBlock(identifier: identifier, to: index)
        }
        applySidebarBlockOrder(savedSidebarBlockOrder())

        let navigation = verticalStack([logo, sidebarBlockStack], spacing: 6)
        // The reorderable modules must continue to occupy the complete sidebar width.
        // NSStackView otherwise sizes the new draggable wrapper from its intrinsic content,
        // which made all cards/buttons collapse into a narrow centered column.
        sidebarBlockStack.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let scrollContent = CarrachoFlippedView()
        scrollContent.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = scrollContent
        navigation.translatesAutoresizingMaskIntoConstraints = false
        scrollContent.addSubview(navigation)
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: scrollContent.leadingAnchor),
            navigation.trailingAnchor.constraint(equalTo: scrollContent.trailingAnchor),
            navigation.topAnchor.constraint(equalTo: scrollContent.topAnchor),
            navigation.bottomAnchor.constraint(equalTo: scrollContent.bottomAnchor),
            scrollContent.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let version = infoLabel(L("Carracho 1.0"))
        version.font = .systemFont(ofSize: 10)
        appearancePopup.removeAllItems()
        appearancePopup.addItems(withTitles: [L("System Appearance"), L("Light"), L("Dark")])
        appearancePopup.controlSize = .small
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged(_:))
        appearancePopup.selectItem(at: savedAppearanceIndex())
        let footer = verticalStack([version, appearancePopup], spacing: 4)
        for child in [scroll, footer] { child.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(child) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
        ])
        return sidebar
    }

    func makeWorkspaceArea() -> NSView {
        let container = CarrachoBackgroundView()
        container.fillColor = CarrachoTheme.canvas
        let serverHeader = makeServerHeader()
        let rightPanel = makeRightPanel()
        let transferBar = makeTransferBar()
        workspaceTransferBar = transferBar
        let transferBarHeight = transferBar.heightAnchor.constraint(equalToConstant: 42)
        workspaceTransferBarHeightConstraint = transferBarHeight

        tabView.tabViewType = .noTabsNoBorder
        // NSTabView briefly lays out its selected item before Auto Layout owns the shell.
        // A realistic construction frame avoids zero-size intermediate constraints.
        tabView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        tabView.addTabViewItem(makeDeckItem(id: "overview", view: makeOverviewPage()))
        tabView.addTabViewItem(makeDeckItem(id: "conferences", view: makeConferencesPage()))
        tabView.addTabViewItem(makeDeckItem(id: "files", view: makeFilesPage()))
        tabView.addTabViewItem(makeDeckItem(id: "transfers", view: makeTransferMonitorPage()))
        tabView.addTabViewItem(makeDeckItem(id: "news", view: makeNewsClientPage()))
        tabView.addTabViewItem(makeDeckItem(id: "messageCenter", view: makeMessageCenterPage()))
        tabView.addTabViewItem(makeDeckItem(id: "trackerBrowser", view: makeTrackerBrowserPage()))
        tabView.addTabViewItem(makeDeckItem(id: "accounts", view: makeAccountsAdminPage()))
        tabView.addTabViewItem(makeDeckItem(id: "bot", view: makeBotAdminPage()))
        tabView.addTabViewItem(makeDeckItem(id: "newsgroups", view: makeNewsAdminPage()))
        tabView.addTabViewItem(makeDeckItem(id: "serverInfo", view: makeServerInfoAdminPage()))
        tabView.addTabViewItem(makeDeckItem(id: "trackers", view: makeTrackersAdminPage()))
        tabView.addTabViewItem(makeDeckItem(id: "serverLog", view: makeServerLogAdminPage()))
        tabView.addTabViewItem(makeDeckItem(id: "events", view: makeEventsAdminPage()))
        tabView.addTabViewItem(makeDeckItem(id: "advanced", view: makeAdvancedAdminPage()))
        tabView.addTabViewItem(makeDeckItem(id: "agreement", view: makeAgreementAdminPage()))
        tabView.addTabViewItem(makeDeckItem(id: "statistics", view: makeStatisticsAdminPage()))

        let bodySplit = makeResizableColumnSplit(
            panes: [tabView, rightPanel],
            autosaveName: "Carracho.WorkspaceColumns",
            edge: .trailing,
            initialEdgeWidth: 286,
            minimumPaneWidths: [450, 224]
        )
        bodySplit.identifier = NSUserInterfaceItemIdentifier("workspaceColumnSplit")
        workspaceColumnSplit = bodySplit

        for child in [serverHeader, bodySplit, transferBar] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            serverHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            serverHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            serverHeader.topAnchor.constraint(equalTo: container.topAnchor),

            bodySplit.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodySplit.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodySplit.topAnchor.constraint(equalTo: serverHeader.bottomAnchor),
            bodySplit.bottomAnchor.constraint(equalTo: transferBar.topAnchor),

            transferBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            transferBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            transferBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            transferBarHeight,
        ])
        updateInspectorToggleButton()
        return container
    }

    func makeServerHeader() -> NSView {
        let container = CarrachoBackgroundView()
        container.fillColor = CarrachoTheme.sidebar

        let bannerHost = CarrachoBackgroundView()
        bannerHost.fillColor = .clear
        bannerHost.translatesAutoresizingMaskIntoConstraints = false
        serverBannerHost = bannerHost

        rightBannerImageView.imageScaling = .scaleProportionallyDown
        rightBannerImageView.imageAlignment = .alignLeft
        rightBannerImageView.translatesAutoresizingMaskIntoConstraints = false
        rightBannerImageView.toolTip = L("Click to open the server banner link in your browser")
        rightBannerImageView.setAccessibilityLabel(L("Server banner link"))
        rightBannerImageView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openServerBannerLink(_:))))
        bannerHost.addSubview(rightBannerImageView)
        let bannerWidth = bannerHost.widthAnchor.constraint(equalToConstant: 280)
        bannerWidth.isActive = true
        serverBannerWidthConstraint = bannerWidth
        NSLayoutConstraint.activate([
            bannerHost.heightAnchor.constraint(equalToConstant: 58),
            rightBannerImageView.leadingAnchor.constraint(equalTo: bannerHost.leadingAnchor),
            rightBannerImageView.trailingAnchor.constraint(equalTo: bannerHost.trailingAnchor),
            rightBannerImageView.topAnchor.constraint(equalTo: bannerHost.topAnchor),
            rightBannerImageView.bottomAnchor.constraint(equalTo: bannerHost.bottomAnchor),
        ])

        let bannerSeparator = CarrachoBackgroundView()
        bannerSeparator.fillColor = CarrachoTheme.hairline.withAlphaComponent(0.7)
        bannerSeparator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bannerSeparator.widthAnchor.constraint(equalToConstant: 1),
            bannerSeparator.heightAnchor.constraint(equalToConstant: 44),
        ])
        serverBannerSeparator = bannerSeparator

        serverTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        serverTitleLabel.lineBreakMode = .byTruncatingTail
        serverTitleLabel.maximumNumberOfLines = 1
        serverTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rightServerDescriptionValue.font = .systemFont(ofSize: 12)
        rightServerDescriptionValue.textColor = CarrachoTheme.secondaryText
        rightServerDescriptionValue.maximumNumberOfLines = 1
        rightServerDescriptionValue.lineBreakMode = .byTruncatingTail
        rightServerDescriptionValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let settings = NSButton()
        settings.target = self
        settings.action = #selector(menuSettings(_:))
        styleIconButton(settings, symbol: "gearshape", help: L("Carracho settings"))

        inspectorToggleButton.target = self
        inspectorToggleButton.action = #selector(toggleWorkspaceInspector(_:))
        styleIconButton(inspectorToggleButton, symbol: "sidebar.right", help: L("Hide inspector"))

        let separator = CarrachoBackgroundView()
        separator.fillColor = CarrachoTheme.hairline.withAlphaComponent(0.7)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 22).isActive = true

        headerConnectionButton.target = self
        headerConnectionButton.action = #selector(connectionButtonPressed(_:))
        headerConnectionButton.isBordered = false
        headerConnectionButton.controlSize = .small
        headerConnectionButton.font = .systemFont(ofSize: 12, weight: .medium)
        headerConnectionButton.image = symbolImage("rectangle.portrait.and.arrow.right", fallback: NSImage.stopProgressTemplateName)
        headerConnectionButton.imagePosition = .imageLeading
        headerConnectionButton.imageHugsTitle = true
        headerConnectionButton.contentTintColor = CarrachoTheme.secondaryText
        headerConnectionButton.toolTip = L("Connect or disconnect the active server")
        headerConnectionButton.setAccessibilityLabel(L("Connection"))
        headerConnectionButton.setContentHuggingPriority(.required, for: .horizontal)
        headerConnectionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerConnectionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        headerConnectionButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let actions = horizontalStack([
            settings, inspectorToggleButton, separator, headerConnectionButton,
        ], spacing: 8)
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        rightServerDescriptionValue.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let labels = verticalStack([serverTitleLabel, rightServerDescriptionValue], spacing: 3)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for row in [serverTitleLabel, rightServerDescriptionValue] {
            row.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }

        let stack = horizontalStack([bannerHost, bannerSeparator, labels], spacing: 14)
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        container.addSubview(actions)
        let divider = CarrachoDividerView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -14),
            labels.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            actions.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            settings.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            inspectorToggleButton.leadingAnchor.constraint(equalTo: settings.trailingAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: inspectorToggleButton.trailingAnchor, constant: 8),
            headerConnectionButton.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 8),
            headerConnectionButton.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            actions.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        bannerHost.isHidden = rightBannerImageView.image == nil
        bannerSeparator.isHidden = bannerHost.isHidden
        return container
    }

    @objc func toggleWorkspaceInspector(_ sender: Any?) {
        workspaceColumnSplit?.toggleEdgeCollapsed()
        updateInspectorToggleButton()
    }

    func updateInspectorToggleButton() {
        let collapsed = workspaceColumnSplit?.isEdgeCollapsed ?? false
        inspectorToggleButton.image = symbolImage(collapsed ? "sidebar.right" : "sidebar.right",
                                                   fallback: NSImage.listViewTemplateName)
        inspectorToggleButton.toolTip = collapsed ? L("Show inspector") : L("Hide inspector")
        inspectorToggleButton.setAccessibilityLabel(collapsed ? L("Show inspector") : L("Hide inspector"))
        inspectorToggleButton.contentTintColor = collapsed ? CarrachoTheme.accent : CarrachoTheme.secondaryText
    }

    @objc func openServerBannerLink(_ sender: Any?) {
        guard rightBannerImageView.image != nil, let banner = currentBanner else { return }
        var target = banner.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        // Classic servers historically store the banner target as a plain string. Accept a
        // bare host for compatibility, but only launch web URLs because this action is explicitly
        // a browser link and the value comes from a remote server.
        if !target.contains("://") { target = "https://" + target }
        guard let components = URLComponents(string: target),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              let url = components.url else {
            showError(L("The server banner link is not a valid web URL."))
            return
        }
        NSWorkspace.shared.open(url)
    }

    func makeOverviewPage() -> NSView {
        let page = CarrachoBackgroundView()
        page.fillColor = CarrachoTheme.card

        let title = NSTextField(labelWithString: L("Overview"))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.setContentHuggingPriority(.required, for: .horizontal)

        let topBar = CarrachoBackgroundView()
        topBar.fillColor = CarrachoTheme.elevatedCard
        let topStack = horizontalStack([title, NSView()], spacing: 10)
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topStack)
        let topDivider = CarrachoDividerView()
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topDivider)

        let split = makeResizableVerticalSplit(
            panes: [overviewFilesHost, overviewConferencesHost],
            autosaveName: "Carracho.OverviewPanels",
            initialFractions: [0.43, 0.57],
            minimumPaneHeights: [170, 210]
        )

        topBar.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(topBar)
        page.addSubview(split)
        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 18),
            topStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            topStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topDivider.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topDivider.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            topBar.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: page.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: CarrachoTheme.workspaceHeaderHeight),

            split.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            split.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])

        mountSharedCard(sharedFilesCard, in: overviewFilesHost)
        mountSharedCard(sharedConferencesCard, in: overviewConferencesHost)
        return page
    }

    func mountSharedCard(_ card: NSView, in host: NSView) {
        guard card.superview !== host else { return }
        card.removeFromSuperview()
        card.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    func placeSharedWorkspaceCards(for workspace: Workspace) {
        switch workspace {
        case .overview:
            mountSharedCard(sharedFilesCard, in: overviewFilesHost)
            mountSharedCard(sharedConferencesCard, in: overviewConferencesHost)
        case .files:
            mountSharedCard(sharedFilesCard, in: standaloneFilesHost)
        case .conferences:
            mountSharedCard(sharedConferencesCard, in: standaloneConferencesHost)
        default:
            break
        }
    }

    func updateInspectorContext() {
        let conferenceMode = currentWorkspace == .conferences
        generalInspectorContent?.isHidden = conferenceMode
        conferenceInspectorContent?.isHidden = !conferenceMode
        guard conferenceMode else { return }

        conferenceInspectorParticipantsLabel.stringValue = LF("PARTICIPANTS · %@", String(channelMembers.count))
        guard let active = activeChannel else {
            conferenceInspectorRoomLabel.stringValue = L("No room selected")
            conferenceInspectorRoomLabel.toolTip = nil
            conferenceInspectorPropertiesLabel.stringValue = L("Join or open a room to see its participants and controls.")
            channelInviteButton.isEnabled = false
            channelSettingsButton.isHidden = true
            channelModeButton.isHidden = true
            channelLeaveButton.isEnabled = false
            channelMemberActionsButton.isEnabled = false
            return
        }

        let name = Self.macRomanString(active.name)
        conferenceInspectorRoomLabel.stringValue = "#\(name)"
        conferenceInspectorRoomLabel.toolTip = "#\(name)"
        var properties: [String] = []
        if active.flags & LegacyChannelSummary.passwordProtectedFlag != 0 {
            properties.append(L("Password protected"))
        } else {
            properties.append(L("Public room"))
        }
        if active.flags & Self.channelRestrictedChatFlag != 0 { properties.append(L("Restricted chat")) }
        if active.flags & Self.channelRestrictedTopicFlag != 0 { properties.append(L("Topic restricted")) }
        conferenceInspectorPropertiesLabel.stringValue = properties.joined(separator: " · ")

        let connected = client.isConnected
        let hasInviteCandidate = liveUsers.keys.contains { channelMembers[$0] == nil }
        channelInviteButton.isEnabled = connected && hasInviteCandidate
        channelSettingsButton.isHidden = !(isActiveChannelOperator || canEditActiveChannelTopic)
        channelSettingsButton.isEnabled = connected && (isActiveChannelOperator || canEditActiveChannelTopic)
        channelModeButton.isHidden = !isActiveChannelOperator
        channelModeButton.isEnabled = connected && isActiveChannelOperator
            && channelMemberTable.selectedRow >= 0 && channelMemberTable.selectedRow < sortedChannelMembers.count
        channelLeaveButton.isEnabled = connected
        channelMemberActionsButton.isEnabled = channelMemberTable.selectedRow >= 0
            && channelMemberTable.selectedRow < sortedChannelMembers.count
    }

    func inspectorDisclosureButton(title: String, collapsed: Bool, action: Selector) -> NSButton {
        let localizedTitle = L(title)
        let button = NSButton(title: localizedTitle, target: self, action: action)
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .labelColor
        button.imagePosition = .imageTrailing
        button.imageHugsTitle = false
        button.image = symbolImage(collapsed ? "chevron.right" : "chevron.down",
                                   fallback: NSImage.rightFacingTriangleTemplateName)
        button.toolTip = collapsed ? LF("Expand %@", localizedTitle) : LF("Collapse %@", localizedTitle)
        button.setAccessibilityLabel(localizedTitle)
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    func updateInspectorDisclosureButton(_ button: NSButton?, title: String, collapsed: Bool) {
        button?.image = symbolImage(collapsed ? "chevron.right" : "chevron.down",
                                    fallback: NSImage.rightFacingTriangleTemplateName)
        button?.toolTip = collapsed ? LF("Expand %@", L(title)) : LF("Collapse %@", L(title))
    }

    @objc func toggleInspectorServerInfo(_ sender: Any?) {
        guard let body = inspectorServerInfoBody else { return }
        let collapsed = !body.isHidden
        body.isHidden = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.inspectorServerInfoCollapsedDefaultsKey)
        updateInspectorDisclosureButton(inspectorServerInfoDisclosureButton,
                                        title: "Server Information", collapsed: collapsed)
    }

    @objc func toggleInspectorConnectionDetails(_ sender: Any?) {
        guard let body = inspectorConnectionDetailsBody else { return }
        let collapsed = !body.isHidden
        body.isHidden = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.inspectorConnectionDetailsCollapsedDefaultsKey)
        updateInspectorDisclosureButton(inspectorConnectionDetailsDisclosureButton,
                                        title: "Connection Details", collapsed: collapsed)
    }

    func makeStatusBar() -> NSView {
        let container = CarrachoBackgroundView()
        container.fillColor = CarrachoTheme.elevatedCard
        bottomStatusLabel.font = .systemFont(ofSize: 11)
        let stack = horizontalStack([bottomStatusLabel, NSView()], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    // Keep the shell's geometry explicit. Stack views only arrange their contents;
    // the sidebar, workspace and inspector are pinned independently to the window.
    func pin(_ child: NSView, in parent: NSView, inset: CGFloat) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }


    func makeResizableColumnSplit(panes: [NSView], autosaveName: String,
                                          edge: CarrachoResizableColumnSplitView.Edge,
                                          initialEdgeWidth: CGFloat,
                                          minimumPaneWidths: [CGFloat]) -> CarrachoResizableColumnSplitView {
        let split = CarrachoResizableColumnSplitView(layoutName: autosaveName,
                                                     edge: edge,
                                                     initialEdgeWidth: initialEdgeWidth,
                                                     minimumPaneWidths: minimumPaneWidths)
        split.installPanes(panes)
        return split
    }

    func makeResizableVerticalSplit(panes: [NSView], autosaveName: String,
                                            initialFractions: [CGFloat],
                                            minimumPaneHeights: [CGFloat]) -> CarrachoResizableSplitView {
        let split = CarrachoResizableSplitView(layoutName: autosaveName,
                                               initialFractions: initialFractions,
                                               minimumPaneHeights: minimumPaneHeights)
        // Give each pane a proportional starting frame before Auto Layout sizes the split view.
        // Thereafter NSSplitView owns the outer frames while the cards keep their internal constraints.
        split.installPanes(panes)
        return split
    }

    func horizontalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        for child in views {
            child.translatesAutoresizingMaskIntoConstraints = false
            stack.setVisibilityPriority(.mustHold, for: child)
        }
        return stack
    }

    func verticalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for child in views {
            let wasHidden = child.isHidden
            child.translatesAutoresizingMaskIntoConstraints = false
            let fillWidth = child.widthAnchor.constraint(equalTo: stack.widthAnchor)
            // Most composer/form rows should fill the stack, but fixed-width children such as
            // logos, icon buttons and compact popups must be allowed to keep their explicit
            // required width without producing an unsatisfiable required-required pair.
            fillWidth.priority = .defaultHigh
            fillWidth.isActive = true
            // AppKit's setVisibilityPriority(_:for:) unhides an arranged subview. Preserve an
            // explicitly hidden child so persisted collapsed sidebar sections stay collapsed
            // while their parent stack is being constructed during launch.
            stack.setVisibilityPriority(.mustHold, for: child)
            if wasHidden { child.isHidden = true }
        }
        return stack
    }

    func symbolView(_ name: String, size: CGFloat, tint: NSColor = CarrachoTheme.secondaryText) -> NSImageView {
        let image = NSImageView()
        image.image = symbolImage(name, fallback: NSImage.infoName)
        image.contentTintColor = tint
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: size),
            image.heightAnchor.constraint(equalToConstant: size),
        ])
        return image
    }

    func styleIconButton(_ button: NSButton, symbol: String, help: String) {
        button.title = ""
        button.image = symbolImage(symbol, fallback: NSImage.actionTemplateName)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = CarrachoTheme.secondaryText
        button.toolTip = L(help)
        button.setAccessibilityLabel(L(help))
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    func styleToolbarButton(_ button: NSButton, symbol: String?) {
        button.isBordered = false
        button.imagePosition = .imageAbove
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = CarrachoTheme.secondaryText
        if let symbol { button.image = symbolImage(symbol, fallback: NSImage.actionTemplateName) }
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 78),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    func popoverButton(symbol: String, help: String, content: NSView, width: CGFloat, tag: Int) -> NSButton {
        let controller = NSViewController()
        controller.view = NSView()
        pin(content, in: controller.view, inset: 16)
        controller.view.widthAnchor.constraint(equalToConstant: width).isActive = true
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        workspacePopovers[tag] = popover
        let button = NSButton(title: L(help), target: self, action: #selector(showWorkspacePopover(_:)))
        button.tag = tag
        styleIconButton(button, symbol: symbol, help: help)
        return button
    }

    @objc func showWorkspacePopover(_ sender: NSButton) {
        guard let popover = workspacePopovers[sender.tag] else { return }
        if popover.isShown { popover.performClose(sender); return }
        if sender.tag == 1 {
            reloadChannelView()
            refreshChannelCatalog()
        }
        if sender.tag == 2 { updateUserActionButtons() }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func makeDeckItem(id: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: id)
        let size = tabView.bounds.size.width > 100 && tabView.bounds.size.height > 100
            ? tabView.bounds.size
            : NSSize(width: 900, height: 700)
        view.frame = NSRect(origin: .zero, size: size)
        item.view = view
        return item
    }

    func cardView() -> NSView {
        CarrachoCardView()
    }

    func tableScroll(_ table: NSTableView, tracksViewportWidth: Bool = false) -> NSScrollView {
        let scroll: NSScrollView = tracksViewportWidth ? ViewportWidthTableScrollView() : NSScrollView()
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = table
        return scroll
    }

    func textScroll(_ textView: NSTextView, border: Bool = true) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = border ? .bezelBorder : .noBorder
        scroll.drawsBackground = border
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        return scroll
    }

    func cardTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    func infoLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = CarrachoTheme.secondaryText
        return label
    }

    func sidebarSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        label.textColor = CarrachoTheme.secondaryText
        return label
    }

    func collapsibleSidebarSectionButton(title: String, collapsed: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: L(title), target: self, action: action)
        button.isBordered = false
        button.alignment = .left
        button.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        button.contentTintColor = CarrachoTheme.secondaryText
        button.imagePosition = .imageLeading
        button.image = symbolImage(collapsed ? "chevron.right" : "chevron.down",
                                   fallback: NSImage.rightFacingTriangleTemplateName)
        button.toolTip = collapsed ? LF("Expand %@", L(title).capitalized) : LF("Collapse %@", L(title).capitalized)
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    func collapsibleSidebarNavigationButton(title: String, collapsed: Bool, action: Selector) -> NSButton {
        let button = CarrachoSidebarButton(title: L(title), target: self, action: action)
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.disclosureImage = symbolImage(collapsed ? "chevron.right" : "chevron.down",
                                             fallback: NSImage.rightFacingTriangleTemplateName)
        button.image = symbolImage("bubble.left.and.bubble.right", fallback: NSImage.userGroupName)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        CarrachoTheme.applySidebarButtonStyle(button, selected: false)
        button.toolTip = collapsed ? LF("Expand %@", L(title)) : LF("Collapse %@", L(title))
        return button
    }

    func updateCollapsibleSidebarNavigationButton(_ button: NSButton?, title: String, collapsed: Bool) {
        guard let button else { return }
        (button as? CarrachoSidebarButton)?.disclosureImage = symbolImage(
            collapsed ? "chevron.right" : "chevron.down", fallback: NSImage.rightFacingTriangleTemplateName)
        button.toolTip = collapsed ? LF("Expand %@", L(title)) : LF("Collapse %@", L(title))
        CarrachoTheme.applySidebarButtonStyle(button, selected: false)
    }

    func updateSidebarSectionButton(_ button: NSButton?, title: String, collapsed: Bool) {
        guard let button else { return }
        button.image = symbolImage(collapsed ? "chevron.right" : "chevron.down",
                                   fallback: NSImage.rightFacingTriangleTemplateName)
        button.toolTip = collapsed ? LF("Expand %@", L(title).capitalized) : LF("Collapse %@", L(title).capitalized)
    }

    @objc func toggleBookmarkSidebarSection(_ sender: Any?) {
        let collapsed = !bookmarkStack.isHidden
        bookmarkStack.isHidden = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.bookmarkSidebarCollapsedDefaultsKey)
        updateSidebarSectionButton(bookmarkSidebarHeader, title: "BOOKMARKS", collapsed: collapsed)
    }

    @objc func toggleTrackerSidebarSection(_ sender: Any?) {
        let collapsed = !trackerStack.isHidden
        trackerStack.isHidden = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.trackerSidebarCollapsedDefaultsKey)
        updateSidebarSectionButton(trackerSidebarHeader, title: "TRACKERS", collapsed: collapsed)
    }

    @objc func toggleServerSidebarSection(_ sender: Any?) {
        let collapsed = !(serverSidebarContent?.isHidden ?? false)
        serverSidebarContent?.isHidden = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.serverSidebarCollapsedDefaultsKey)
        updateSidebarSectionButton(serverSidebarHeader, title: "SERVER", collapsed: collapsed)
    }

    @objc func toggleConferencesSidebarSection(_ sender: Any?) {
        let collapsed = !(conferencesSidebarContent?.isHidden ?? false)
        conferencesSidebarContent?.isHidden = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.conferencesSidebarCollapsedDefaultsKey)
        updateCollapsibleSidebarNavigationButton(conferencesSidebarHeader, title: "Conferences", collapsed: collapsed)
    }

    @objc func toggleAdministrationSidebarSection(_ sender: Any?) {
        let collapsed = !(administrationSidebarContent?.isHidden ?? false)
        administrationSidebarContent?.isHidden = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.administrationSidebarCollapsedDefaultsKey)
        updateSidebarSectionButton(administrationSidebarHeader, title: "ADMINISTRATION", collapsed: collapsed)
    }

    func makeSidebarButton(_ workspace: Workspace) -> NSButton {
        let button = CarrachoSidebarButton(title: workspace.title, target: self, action: #selector(sidebarPressed(_:)))
        button.tag = workspace.rawValue
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.image = sidebarSymbol(for: workspace)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        CarrachoTheme.applySidebarButtonStyle(button, selected: false)
        sidebarButtons[workspace] = button
        return button
    }

    func sidebarSymbol(for workspace: Workspace) -> NSImage? {
        guard #available(macOS 11.0, *) else { return nil }
        let name: String
        switch workspace {
        case .overview: name = "house"
        case .conferences: name = "bubble.left.and.bubble.right"
        case .files: name = "folder"
        case .transfers: name = "arrow.up.arrow.down.circle"
        case .news: name = "newspaper"
        case .messageCenter: name = "envelope"
        case .accounts: name = "person.2.fill"
        case .bot: name = "cpu"
        case .newsgroups: name = "cube"
        case .serverInfo: name = "info.circle"
        case .trackers: name = "point.3.connected.trianglepath.dotted"
        case .serverLog: name = "doc.text"
        case .events: name = "list.bullet.rectangle.portrait"
        case .advanced: name = "gearshape"
        case .agreement: name = "person.text.rectangle"
        case .statistics: name = "chart.xyaxis.line"
        case .trackerBrowser: name = "point.3.connected.trianglepath.dotted"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: workspace.title)
    }

    func toolbarButton(_ title: String, _ action: Selector) -> NSButton {
        let button = CarrachoToolbarButton(title: title, target: self, action: action)
        button.isBordered = false
        button.controlSize = .small
        button.imagePosition = .imageAbove
        button.alignment = .center
        button.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        if #available(macOS 11.0, *) {
            let symbol: String
            switch title {
            case "Chat Rooms": symbol = "bubble.left.and.bubble.right.fill"
            case "Files": symbol = "folder.fill"
            case "Transfers": symbol = "arrow.up.arrow.down.circle.fill"
            case "News": symbol = "newspaper.fill"
            case "Broadcast": symbol = "megaphone.fill"
            case "Preferences": symbol = "gearshape.fill"
            default: symbol = "circle"
            }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.contentTintColor = CarrachoTheme.secondaryText
        }
        styleToolbarButton(button, symbol: nil)
        return button
    }

    func loadSavedContentFontSizes() {
        let defaults = UserDefaults.standard
        filesFontSize = normalizedContentFontSize(defaults.object(forKey: Self.filesFontSizeDefaultsKey) as? NSNumber, fallback: 13)
        newsFontSize = normalizedContentFontSize(defaults.object(forKey: Self.newsFontSizeDefaultsKey) as? NSNumber, fallback: 13)
        channelChatFontSize = normalizedContentFontSize(defaults.object(forKey: Self.channelChatFontSizeDefaultsKey) as? NSNumber, fallback: 13)
        serverLogFontSize = normalizedContentFontSize(defaults.object(forKey: Self.serverLogFontSizeDefaultsKey) as? NSNumber, fallback: 11)
        eventsFontSize = normalizedContentFontSize(defaults.object(forKey: Self.eventsFontSizeDefaultsKey) as? NSNumber, fallback: 11)
        messageCenterFontSize = normalizedContentFontSize(defaults.object(forKey: Self.messageCenterFontSizeDefaultsKey) as? NSNumber, fallback: 13)
    }

    func normalizedContentFontSize(_ number: NSNumber?, fallback: CGFloat) -> CGFloat {
        guard let number else { return fallback }
        let requested = CGFloat(number.doubleValue)
        return Self.contentFontSizeOptions.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? fallback
    }

    func configureContentFontSizePopup(_ popup: NSPopUpButton, selectedSize: CGFloat, help: String) {
        popup.removeAllItems()
        for size in Self.contentFontSizeOptions {
            popup.addItem(withTitle: "\(Int(size)) pt")
            popup.lastItem?.tag = Int(size)
        }
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.toolTip = help
        popup.target = self
        popup.action = #selector(contentFontSizeChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 68).isActive = true
        popup.selectItem(withTag: Int(selectedSize))
    }

    @objc func contentFontSizeChanged(_ sender: NSPopUpButton) {
        let size = CGFloat(sender.selectedTag())
        guard Self.contentFontSizeOptions.contains(size) else { return }
        if sender === filesFontSizePopup {
            filesFontSize = size
            UserDefaults.standard.set(Double(size), forKey: Self.filesFontSizeDefaultsKey)
            applyFilesFontSize()
        } else if sender === newsFontSizePopup {
            newsFontSize = size
            UserDefaults.standard.set(Double(size), forKey: Self.newsFontSizeDefaultsKey)
            applyNewsFontSize()
        } else if sender === channelChatFontSizePopup {
            channelChatFontSize = size
            UserDefaults.standard.set(Double(size), forKey: Self.channelChatFontSizeDefaultsKey)
            applyChannelChatFontSize()
        } else if sender === serverLogFontSizePopup {
            serverLogFontSize = size
            UserDefaults.standard.set(Double(size), forKey: Self.serverLogFontSizeDefaultsKey)
            applyServerLogFontSize()
        } else if sender === eventsFontSizePopup {
            eventsFontSize = size
            UserDefaults.standard.set(Double(size), forKey: Self.eventsFontSizeDefaultsKey)
            applyEventsFontSize()
        } else if sender === messageCenterFontSizePopup {
            messageCenterFontSize = size
            UserDefaults.standard.set(Double(size), forKey: Self.messageCenterFontSizeDefaultsKey)
            applyMessageCenterFontSize()
        }
    }

    func savedAppearanceIndex() -> Int {
        switch UserDefaults.standard.string(forKey: "CarrachoAppearance") {
        case "light": return 1
        case "dark": return 2
        default: return 0
        }
    }

    func applySavedAppearance() {
        if ProcessInfo.processInfo.arguments.contains("--appearance=dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--appearance=light") {
            NSApp.appearance = NSAppearance(named: .aqua)
            return
        }
        switch UserDefaults.standard.string(forKey: "CarrachoAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    @objc func appearanceChanged(_ sender: NSPopUpButton) {
        let value: String
        switch sender.indexOfSelectedItem {
        case 1: value = "light"
        case 2: value = "dark"
        default: value = "system"
        }
        UserDefaults.standard.set(value, forKey: "CarrachoAppearance")
        applySavedAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = CarrachoTheme.canvas.cgColor
        for (candidate, button) in sidebarButtons {
            CarrachoTheme.applySidebarButtonStyle(button, selected: candidate == currentWorkspace)
        }
        updateCollapsibleSidebarNavigationButton(
            conferencesSidebarHeader, title: "Conferences",
            collapsed: conferencesSidebarContent?.isHidden ?? false
        )
        for table in [fileTable, transferTable, trackerBrowserTable, privateMessageConversationTable, userTable, channelTable, channelMemberTable, newsTable, newsArticleTable, adminAccountTable, adminNewsgroupTable, adminTrackerTable] {
            table.backgroundColor = CarrachoTheme.tableBackground
            table.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        }
        // The inspector is one continuous surface; its user list should not suddenly turn into
        // a nested table card after an Appearance switch.
        userTable.backgroundColor = .clear
        channelMemberTable.backgroundColor = .clear
        reloadJoinedChannelSidebar()
        updateInspectorContext()
        reloadTrackerStack()
    }

    @objc func sidebarPressed(_ sender: NSButton) {
        guard let workspace = Workspace(rawValue: sender.tag) else { return }
        selectWorkspace(workspace)
    }

    func confirmServerInfoChangesCanBeAbandoned() -> Bool {
        guard serverInfoHasUnsavedChanges else { return true }
        if serverInfoSaveInProgress {
            showError(L("Server information is still being saved. Wait for the operation to finish before leaving this view."))
            return false
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Discard Unsaved Server Info Changes?")
        alert.informativeText = L("The current server information draft has not been fully saved. Discard it before leaving this server or view?")
        alert.addButton(withTitle: L("Keep Editing"))
        alert.addButton(withTitle: L("Discard Changes"))
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        discardServerInfoChanges(nil)
        return true
    }

    func selectWorkspace(_ workspace: Workspace) {
        if workspace != currentWorkspace, currentWorkspace == .serverInfo,
           !confirmServerInfoChangesCanBeAbandoned() { return }
        if workspace != currentWorkspace, currentWorkspace == .trackers,
           !confirmTrackerChangesCanBeAbandoned() { return }
        if administrativePermission(for: workspace) != nil, !canAccessAdministrativeWorkspace(workspace) { return }
        if workspace == .transfers, !canAccessTransferWorkspace { return }
        currentWorkspace = workspace
        updateWorkspaceTransferBarVisibility()
        if workspace != .trackerBrowser { serverWorkspaceBeforeTracker = nil }
        placeSharedWorkspaceCards(for: workspace)
        tabView.selectTabViewItem(withIdentifier: workspace.deckIdentifier)
        for (candidate, button) in sidebarButtons {
            CarrachoTheme.applySidebarButtonStyle(button, selected: candidate == workspace)
        }
        reloadJoinedChannelSidebar()
        updateInspectorContext()
        switch workspace {
        case .files:
            view.window?.makeFirstResponder(fileTable)
            alignInitialFilesWorkspaceToTopIfNeeded()
        case .transfers:
            view.window?.makeFirstResponder(transferTable)
        case .conferences:
            channelMemberTable.reloadData()
            updateInspectorContext()
            view.window?.makeFirstResponder(channelMessageField)
        case .trackerBrowser:
            view.window?.makeFirstResponder(trackerBrowserTable)
            reloadTrackerBrowser()
        case .news:
            view.window?.makeFirstResponder(newsTable)
        case .messageCenter:
            refreshPrivateMessageCenter(scrollToBottom: false)
            if selectedPrivateConversationID != nil { view.window?.makeFirstResponder(privateMessageComposer) }
            else { view.window?.makeFirstResponder(privateMessageConversationTable) }
        case .accounts:
            view.window?.makeFirstResponder(adminAccountTable)
            if client.isConnected { reloadRemoteAccounts() }
        case .bot:
            reloadBotAdministration()
        case .newsgroups:
            view.window?.makeFirstResponder(adminNewsgroupTable)
            reloadNewsgroupAdministration()
        case .trackers:
            view.window?.makeFirstResponder(adminTrackerTable)
            reloadTrackerAdministration()
        case .serverInfo:
            if serverInfoHasUnsavedChanges { updateServerInfoEditorState() }
            else { reloadServerInfoAdministration() }
        case .serverLog:
            refreshServerLog(nil)
        case .events:
            refreshEventLog(nil)
        case .advanced:
            if advancedHasUnsavedChanges {
                updateAdvancedSaveUI()
            } else {
                reloadAdvancedSettings()
                reloadTransferBandwidthAdministration()
                reloadLegacyFilesRoot()
                reloadSearchIndexExclusions()
                reloadBanManagement()
            }
        case .agreement:
            reloadAgreementAdministration()
        case .statistics:
            reloadStatisticsAdministration()
        default:
            break
        }
        reloadTrackerStack()
        updateTransferMonitorPolling()
    }

    var usesRemoteTrackerAdministration: Bool { client.isConnected }

    var selectedTrackerBandwidthCode: UInt8 {
        UInt8(clamping: adminTrackerBandwidthPopup.selectedItem?.tag ?? 0)
    }

    var usesRemoteAccountAdministration: Bool { client.isConnected }
    /// A negotiated Blowfish transfer/control session identifies an original/Classic server.
    /// Keep this generic: several administration views need to suppress modern-only features.
    var isConnectedToClassicServer: Bool {
        client.isConnected && client.transferSession?.usesModernCrypto == false
    }
    /// Original Carracho Server peers expose the account list/record commands but have no
    /// modern permission-group setting. Their permissions therefore live directly on each account.
    var usesClassicRemoteAccountAdministration: Bool {
        usesRemoteAccountAdministration && isConnectedToClassicServer
    }
    var usesRemoteNewsgroupAdministration: Bool { client.isConnected }

    var isRemoteAdministrator: Bool {
        client.isConnected && remotePermissionEnabled(LegacyAccountPermissionBit.administrator)
    }

    var administrativeWorkspacePermissions: [(Workspace, Int)] {
        [
            (.accounts, LegacyAccountPermissionBit.manageAccounts),
            (.bot, LegacyAccountPermissionBit.manageAccounts),
            (.advanced, LegacyAccountPermissionBit.editAdvancedSettings),
            (.agreement, LegacyAccountPermissionBit.editServerAgreement),
            (.events, LegacyAccountPermissionBit.viewServerLog),
            (.newsgroups, LegacyAccountPermissionBit.manageNewsgroups),
            (.serverInfo, LegacyAccountPermissionBit.editServerInformation),
            (.serverLog, LegacyAccountPermissionBit.viewServerLog),
            (.statistics, LegacyAccountPermissionBit.viewStatistics),
            (.trackers, LegacyAccountPermissionBit.editTrackers),
        ]
    }

    var canManageRemoteTransfers: Bool {
        guard client.isConnected else { return false }
        // Administrators always get the complete server-wide monitor. A non-admin account can
        // be delegated the same capability explicitly through the manageTransfers permission.
        return isRemoteAdministrator || remotePermissionEnabled(LegacyAccountPermissionBit.manageTransfers)
    }

    var canBroadcastMessages: Bool {
        client.isConnected && remotePermissionEnabled(LegacyAccountPermissionBit.broadcastMessages)
    }

    var canAccessTransferWorkspace: Bool {
        // Regular users keep their personal transfer history/control. Administrator
        // accounts additionally need the explicit central-monitor permission.
        guard client.isConnected, isRemoteAdministrator else { return true }
        return canManageRemoteTransfers
    }

    var canManageRemoteAccounts: Bool {
        client.isConnected && remotePermissionEnabled(LegacyAccountPermissionBit.manageAccounts)
    }

    var canManageRemoteNewsgroups: Bool {
        client.isConnected && remotePermissionEnabled(LegacyAccountPermissionBit.manageNewsgroups)
    }

    var canPostRemoteNews: Bool {
        guard client.isConnected else { return false }
        // Original Classic has no account-level threaded-News permission. Its category ACL
        // remains authoritative, while modern Carracho additionally advertises bit 0x31.
        return isConnectedToClassicServer || remotePermissionEnabled(ServerPermission.postNews.rawValue)
    }

    var availableAccountGroups: [ServerAccountGroup] {
        let groups = usesRemoteAccountAdministration ? remoteAccountGroups : localServerState.accountGroups
        return groups.sorted {
            let li = ServerState.builtInAccountGroupOrder.firstIndex(of: $0.id) ?? Int.max
            let ri = ServerState.builtInAccountGroupOrder.firstIndex(of: $1.id) ?? Int.max
            return li == ri ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : li < ri
        }
    }

    var accountPermissionSections: [(String, [(String, ServerPermission)])] {
        [
            ("Files / Folders", [
                ("Download", .download), ("Upload", .upload), ("Upload anywhere", .uploadAnywhere),
                ("Create folders", .createFolders), ("View dropboxes", .viewDropboxes), ("Change folder mode", .changeFolderMode),
                ("Move files", .moveFiles), ("Move folders", .moveFolders), ("Rename files", .renameFiles),
                ("Rename folders", .renameFolders), ("Delete files", .deleteFiles), ("Delete folders", .deleteFolders),
                ("Comment files", .commentFiles), ("Comment folders", .commentFolders),
            ]),
            ("Administration", [
                ("Accounts", .manageAccounts), ("News categories", .manageNewsgroups),
                ("Server info", .editServerInformation), ("Trackers", .editTrackers),
                ("Server log / events", .viewServerLog), ("Advanced / bans", .editAdvancedSettings),
                ("Agreement", .editServerAgreement), ("Statistics", .viewStatistics),
                ("Transfer monitor / control", .manageTransfers), ("Empty server Trash", .emptyServerTrash),
            ]),
            ("Users / Chat", [
                ("Join chat rooms", .joinChatRooms), ("Broadcast messages", .broadcastMessages),
                ("Extended user info", .extendedUserInfo), ("Disconnect users", .disconnectUsers),
                ("Ban users", .banUsers), ("Search files", .searchFiles),
                ("Post news", .postNews), ("Post flat news", .postFlatNews),
            ]),
        ]
    }

    @objc func menuConnect(_ sender: Any?) { presentConnectionSheet() }
    @objc func menuDisconnect(_ sender: Any?) {
        if client.isConnected || autoReconnectBookmarkID != nil { disconnectByUser() }
    }
    @objc func menuAdministration(_ sender: Any?) {
        guard let workspace = administrativeWorkspacePermissions.map(\.0).first(where: canAccessAdministrativeWorkspace) else { return }
        selectWorkspace(workspace)
    }
    @objc func menuImportBookmarks(_ sender: Any?) { importBookmarksPressed(sender) }
    @objc func menuExportBookmarks(_ sender: Any?) { exportBookmarksPressed(sender) }

    @objc func broadcastPressed(_ sender: Any?) {
        guard client.isConnected, canBroadcastMessages, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L("Broadcast Message")
        alert.informativeText = L("Send a message to every connected user. The server permission ‘Can broadcast messages’ is required. HTML formatting is supported.")
        alert.addButton(withTitle: L("Broadcast"))
        alert.addButton(withTitle: L("Cancel"))
        let message = NSTextField(string: "")
        message.placeholderString = L("Message (max. 512 bytes)")
        message.translatesAutoresizingMaskIntoConstraints = false
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let emoji = EmojiPickerButton(editor: message)
        emoji.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 68))
        accessory.addSubview(message)
        accessory.addSubview(emoji)
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            message.topAnchor.constraint(equalTo: accessory.topAnchor),
            message.heightAnchor.constraint(equalToConstant: 28),

            emoji.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            emoji.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 7),
            emoji.bottomAnchor.constraint(lessThanOrEqualTo: accessory.bottomAnchor),
        ])
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = message
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let text = message.stringValue
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.showError(L("Broadcast must not be empty."))
                return
            }
            let data: Data
            do {
                data = try CarrachoTextWire.encode(text, maximumBytes: 0x200)
            } catch {
                self.showError(L("Broadcast may contain at most 512 bytes."))
                return
            }
            self.client.broadcastMessage(data) { [weak self] result in
                if case let .failure(error) = result {
                    self?.appendLine("\n" + LF("Broadcast could not be sent: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    @objc func addServerPressed(_ sender: Any?) {
        presentBookmarkEditor(bookmark: nil)
    }

    func captureActiveBookmarkSession() -> BookmarkSessionSnapshot {
        BookmarkSessionSnapshot(
            workspace: currentWorkspace == .trackerBrowser ? (serverWorkspaceBeforeTracker ?? .overview) : currentWorkspace,
            lastLoginResult: lastLoginResult,
            lastServerInfo: lastServerInfo,
            remoteServerUptimeSeconds: remoteServerUptimeSeconds,
            remoteServerUptimeObservedAt: remoteServerUptimeObservedAt,
            lastDirectory: lastDirectory,
            fileTransferClient: fileTransferClient,
            fileSearchClient: fileSearchClient,
            bannerClient: bannerClient,
            currentBanner: currentBanner,
            fileSearchResults: fileSearchResults,
            fileSearchQuery: fileSearchField.stringValue,
            fileNavigationHistory: fileNavigationHistory,
            fileNavigationIndex: fileNavigationIndex,
            expandedFilePaths: expandedFilePaths,
            expandedDirectoryListings: expandedDirectoryListings,
            selectedFilePaths: selectedFilePaths,
            fileTableScrollY: fileTable.enclosingScrollView?.contentView.bounds.origin.y ?? 0,
            transferMonitorItems: transferMonitorItems,
            transferMonitorOrder: transferMonitorOrder,
            clientTransferTasks: clientTransferTasks,
            clientTransferOperations: clientTransferOperations,
            selectedTransferID: selectedTransferID,
            selectedRemoteTransferID: selectedRemoteTransferID,
            remoteTransferSnapshot: remoteTransferSnapshot,
            remoteManagedTransferSnapshot: remoteManagedTransferSnapshot,
            remoteTransferUploadLimitBytesPerSecond: remoteTransferUploadLimitBytesPerSecond,
            remoteDownloadTrafficBytesPerSecond: remoteDownloadTrafficBytesPerSecond,
            lastChannels: lastChannels,
            lastNewsgroups: lastNewsgroups,
            newsClient: newsClient,
            mediaClient: mediaClient,
            mediaCache: mediaCache,
            hiddenMediaIDs: hiddenMediaIDs,
            currentNewsIndex: currentNewsIndex,
            currentArticle: currentArticle,
            currentNewsCategory: currentNewsCategory,
            currentNewsThreads: currentNewsThreads,
            currentNewsThreadID: currentNewsThreadID,
            currentNewsThreadPosts: currentNewsThreadPosts,
            currentNewsThreadArticles: currentNewsThreadArticles,
            currentNewsReactions: currentNewsReactions,
            currentNewsPostCapabilities: currentNewsPostCapabilities,
            newsReactionsSupported: newsReactionsSupported,
            newsReadState: newsReadState,
            newsReadScope: newsReadScope,
            newsThreadsByCategory: newsThreadsByCategory,
            newsBadgesSupported: newsBadgesSupported,
            activeChannel: activeChannel,
            channelMembers: channelMembers,
            joinedChannels: joinedChannels,
            privateMessageConversations: privateMessageConversations,
            selectedPrivateConversationID: selectedPrivateConversationID,
            offlineMessageCenterMessages: offlineMessageCenterMessages,
            offlineMessageCenterUnreadIDs: offlineMessageCenterUnreadIDs,
            offlineMessageCenterUnreadCount: offlineMessageCenterUnreadCount,
            messageCenterPersistenceScope: messageCenterPersistenceScope,
            offlineMessageLoginNoticePresented: offlineMessageLoginNoticePresented,
            selectedOfflineMessages: selectedOfflineMessages,
            privateMessageSearchQuery: privateMessageSearchField.stringValue,
            liveUsers: liveUsers,
            selectedUserID: selectedUserID,
            sleepingUsers: sleepingUsers,
            userStatusMessages: userStatusMessages,
            userGroupColors: userGroupColors,
            remoteAccountSummaries: remoteAccountSummaries,
            remoteAccountGroups: remoteAccountGroups,
            remoteAccountGroupByLogin: remoteAccountGroupByLogin,
            activeAvatarIdentity: activeAvatarIdentity,
            detailsText: detailsTextView.string,
            deferredInteractiveEvents: deferredInteractiveEvents
        )
    }

    /// Clears the shared views without cancelling any transfer task belonging to the
    /// session that was just parked. Those objects remain retained by its snapshot.
    func clearPresentationForBookmarkSwitch() {
        let previousPersistenceSuppression = suppressTransferMonitorPersistence
        suppressTransferMonitorPersistence = true
        defer { suppressTransferMonitorPersistence = previousPersistenceSuppression }
        cleanupQuickView(closePanel: true)
        flatNewsWindowController?.close()
        flatNewsWindowController = nil
        transferQueueRetryWorkItem?.cancel()
        transferQueueRetryWorkItem = nil
        transferCapacityRequestInFlight = false
        stopNewsBadgePolling()
        stopChannelCatalogPolling()
        transferMonitorRefreshTimer?.invalidate()
        transferMonitorRefreshTimer = nil
        transferMonitorRequestInFlight = false
        activeAvatarIdentity = nil
        lastLoginResult = nil
        lastServerInfo = nil
        remoteServerUptimeSeconds = nil
        remoteServerUptimeObservedAt = nil
        serverUptimeDisplayTimer?.invalidate()
        serverUptimeDisplayTimer = nil
        lastDirectory = nil
        fileTransferClient = nil
        fileSearchClient = nil
        bannerClient = nil
        mediaClient = nil
        mediaCache = nil
        mediaDownloadsInFlight = []
        mediaDownloadFailures = []
        hiddenMediaIDs = []
        currentBanner = nil
        fileSearchResults = nil
        fileSearchGeneration += 1
        isFileSearchBusy = false
        fileDirectoryLoadGeneration &+= 1
        fileDirectoryLoading = false
        filePendingDirectoryPath = nil
        fileDirectoryError = nil
        fileSearchError = nil
        fileNavigationHistory = []
        fileNavigationIndex = -1
        selectedFilePaths.removeAll()
        pendingFileScrollRestoreY = nil
        fileShouldResetScrollOnNextReload = true
        fileNeedsInitialWorkspaceTopAlignment = false
        resetInlineFileExpansion()
        transferMonitorItems = [:]
        transferMonitorOrder = []
        clientTransferTasks = [:]
        clientTransferOperations = [:]
        selectedTransferID = nil
        selectedRemoteTransferID = nil
        remoteTransferSnapshot = []
        remoteManagedTransferSnapshot = []
        remoteTransferUploadLimitBytesPerSecond = nil
        remoteDownloadTrafficBytesPerSecond = nil
        saveInlineNewsReplyDraft()
        lastChannels = []
        lastNewsgroups = []
        newsClient = nil
        mediaClient = nil
        mediaCache = nil
        mediaDownloadsInFlight = []
        mediaDownloadFailures = []
        hiddenMediaIDs = []
        currentNewsIndex = nil
        currentArticle = nil
        currentNewsCategory = nil
        currentNewsThreads = []
        currentNewsThreadID = nil
        currentNewsThreadPosts = []
        currentNewsThreadArticles = []
        currentNewsReactions = [:]
        currentNewsPostCapabilities = [:]
        newsReactionsSupported = true
        newsReadState = NewsReadState()
        newsReadScope = nil
        newsThreadsByCategory = [:]
        newsBadgesSupported = true
        activeChannel = nil
        channelMembers = [:]
        joinedChannels = [:]
        privateMessageConversations = [:]
        selectedPrivateConversationID = nil
        offlineMessageCenterMessages = []
        offlineMessageCenterUnreadIDs = []
        offlineMessageCenterUnreadCount = 0
        messageCenterPersistenceScope = nil
        offlineMessageLoginNoticePresented = false
        selectedOfflineMessages = false
        offlineMessageFetchInFlight = false
        privateMessageSearchQuery = ""
        privateMessageSearchField.stringValue = ""
        privateMessageComposer.string = ""
        liveUsers = [:]
        selectedUserID = nil
        sleepingUsers = []
        userStatusMessages = [:]
        userGroupColors = [:]
        remoteServerLogLoading = false
        remoteEventLogLoading = false
        advancedTrashOperationInProgress = false
        advancedSearchIndexRebuildInProgress = false
        serverLogTextView.string = ""
        eventLogRawText = ""
        eventLogTextView.string = ""
        eventLogFilterStatusLabel.stringValue = ""
        statisticsRefreshGeneration &+= 1
        statisticsLoading = false
        statisticsSourceKey = nil
        statisticsSnapshot = nil
        statisticsLastSuccessfulRefresh = nil
        statisticsStale = false
        statisticsStatusOverride = nil
        statisticsStatusColor = nil
        updateStatisticsPresentation()
        trackerLoadGeneration &+= 1
        remoteTrackerSettingsLoading = false
        trackerSaveInProgress = false
        trackerLoadedSnapshot = nil
        trackerDraftTrackers = []
        trackerDraftAdvertisementFlags = 0
        trackerSourceKey = nil
        trackerHasUnsavedChanges = false
        trackerStatusOverride = nil
        trackerStatusColor = nil
        adminTrackerTable.reloadData()
        updateTrackerEditorState()
        remoteAccountSummaries = []
        remoteAccountGroups = []
        remoteAccountGroupByLogin = [:]
        remoteAccountListLoading = false
        remoteNewsgroupAdministrationGeneration &+= 1
        remoteNewsgroupAdministrationLoading = false
        remoteAdminNewsgroups = []
        deferredInteractiveEvents = []
        detailsTextView.string = ""
        rightBannerImageView.image = nil
        fileSearchField.stringValue = ""
        fileTransferLabel.stringValue = ""
        currentWorkspace = .overview
        tabView.selectTabViewItem(withIdentifier: Workspace.overview.deckIdentifier)
        refreshTransferMonitorUI()
        reloadCatalogViews()
        adminAccountTable.reloadData()
        updateAdminSelectionButtons()
    }

    func restoreBookmarkSession(_ snapshot: BookmarkSessionSnapshot) {
        lastLoginResult = snapshot.lastLoginResult
        lastServerInfo = snapshot.lastServerInfo
        remoteServerUptimeSeconds = snapshot.remoteServerUptimeSeconds
        remoteServerUptimeObservedAt = snapshot.remoteServerUptimeObservedAt
        lastDirectory = snapshot.lastDirectory
        fileTransferClient = snapshot.fileTransferClient
        fileSearchClient = snapshot.fileSearchClient
        bannerClient = snapshot.bannerClient
        currentBanner = snapshot.currentBanner
        fileSearchResults = snapshot.fileSearchResults
        fileSearchField.stringValue = snapshot.fileSearchQuery
        fileNavigationHistory = snapshot.fileNavigationHistory
        fileNavigationIndex = snapshot.fileNavigationIndex
        expandedFilePaths = snapshot.expandedFilePaths
        expandedDirectoryListings = snapshot.expandedDirectoryListings
        loadingExpandedFilePaths = []
        selectedFilePaths = snapshot.selectedFilePaths
        let fileScrollWasNearTop = snapshot.fileTableScrollY <= max(2, fileTable.rowHeight * 1.5)
        pendingFileScrollRestoreY = fileScrollWasNearTop ? nil : snapshot.fileTableScrollY
        fileShouldResetScrollOnNextReload = fileScrollWasNearTop
        fileDirectoryLoading = false
        filePendingDirectoryPath = nil
        fileDirectoryError = nil
        fileSearchError = nil
        transferMonitorItems = snapshot.transferMonitorItems
        transferMonitorOrder = snapshot.transferMonitorOrder
        clientTransferTasks = snapshot.clientTransferTasks
        clientTransferOperations = snapshot.clientTransferOperations
        selectedTransferID = snapshot.selectedTransferID
        selectedRemoteTransferID = snapshot.selectedRemoteTransferID
        remoteTransferSnapshot = snapshot.remoteTransferSnapshot
        remoteManagedTransferSnapshot = snapshot.remoteManagedTransferSnapshot
        remoteTransferUploadLimitBytesPerSecond = snapshot.remoteTransferUploadLimitBytesPerSecond
        remoteDownloadTrafficBytesPerSecond = snapshot.remoteDownloadTrafficBytesPerSecond
        lastChannels = snapshot.lastChannels
        lastNewsgroups = snapshot.lastNewsgroups
        newsClient = snapshot.newsClient
        mediaClient = snapshot.mediaClient
        mediaCache = snapshot.mediaCache
        mediaDownloadsInFlight = []
        mediaDownloadFailures = []
        hiddenMediaIDs = snapshot.hiddenMediaIDs
        currentNewsIndex = snapshot.currentNewsIndex
        currentArticle = snapshot.currentArticle
        currentNewsCategory = snapshot.currentNewsCategory
        currentNewsThreads = snapshot.currentNewsThreads
        currentNewsThreadID = snapshot.currentNewsThreadID
        currentNewsThreadPosts = snapshot.currentNewsThreadPosts
        currentNewsThreadArticles = snapshot.currentNewsThreadArticles
        currentNewsReactions = snapshot.currentNewsReactions
        currentNewsPostCapabilities = snapshot.currentNewsPostCapabilities
        newsReactionsSupported = snapshot.newsReactionsSupported
        newsReadState = snapshot.newsReadState
        newsReadScope = snapshot.newsReadScope
        newsThreadsByCategory = snapshot.newsThreadsByCategory
        newsBadgesSupported = snapshot.newsBadgesSupported
        activeChannel = snapshot.activeChannel
        channelMembers = snapshot.channelMembers
        joinedChannels = snapshot.joinedChannels
        privateMessageConversations = snapshot.privateMessageConversations
        selectedPrivateConversationID = snapshot.selectedPrivateConversationID
        offlineMessageCenterMessages = snapshot.offlineMessageCenterMessages
        offlineMessageCenterUnreadIDs = snapshot.offlineMessageCenterUnreadIDs
        offlineMessageCenterUnreadCount = snapshot.offlineMessageCenterUnreadCount
        messageCenterPersistenceScope = snapshot.messageCenterPersistenceScope
        offlineMessageLoginNoticePresented = snapshot.offlineMessageLoginNoticePresented
        selectedOfflineMessages = snapshot.selectedOfflineMessages
        offlineMessageFetchInFlight = false
        privateMessageSearchQuery = snapshot.privateMessageSearchQuery
        privateMessageSearchField.stringValue = snapshot.privateMessageSearchQuery
        liveUsers = snapshot.liveUsers
        selectedUserID = snapshot.selectedUserID
        sleepingUsers = snapshot.sleepingUsers
        userStatusMessages = snapshot.userStatusMessages
        userGroupColors = snapshot.userGroupColors
        remoteAccountSummaries = snapshot.remoteAccountSummaries
        remoteAccountGroups = snapshot.remoteAccountGroups
        remoteAccountGroupByLogin = snapshot.remoteAccountGroupByLogin
        remoteAccountListLoading = false
        activeAvatarIdentity = snapshot.activeAvatarIdentity
        deferredInteractiveEvents = snapshot.deferredInteractiveEvents
        detailsTextView.string = snapshot.detailsText
        refreshPrivateMessageCenter(scrollToBottom: false)
        if let banner = currentBanner {
            rightBannerImageView.image = banner.imageData.isEmpty ? nil : NSImage(data: banner.imageData)
        } else {
            rightBannerImageView.image = nil
            }
        refreshTransferMonitorUI()
        if client.isConnected {
            if remoteServerUptimeSeconds != nil, remoteServerUptimeObservedAt != nil {
                startServerUptimeDisplayTimer()
            } else if let ticks = lastServerInfo?.uptimeTicks {
                applyRemoteServerUptimeTicks(ticks)
            } else {
                refreshRemoteServerUptime()
            }
        } else {
            serverUptimeDisplayTimer?.invalidate()
            serverUptimeDisplayTimer = nil
        }
        renderSession()
        refreshAdministrativeNavigationVisibility()
        selectWorkspace(snapshot.workspace)
        if fileScrollWasNearTop { alignFilesToTopAfterFinalLayout() }
        if client.isConnected {
            startNewsBadgePolling()
            startChannelCatalogPolling()
            refreshChannelCatalog()
        }
        updateTransferMonitorPolling()
        if client.isConnected { scheduleClientTransferQueue(refreshCapacity: true) }
    }

    func bookmarkConnectionContext(for bookmarkID: UUID) -> BookmarkConnectionContext {
        if let existing = bookmarkConnections[bookmarkID] { return existing }
        let context = BookmarkConnectionContext(bookmarkID: bookmarkID)
        bookmarkConnections[bookmarkID] = context
        configureClientCallbacks(for: context.client, bookmarkID: bookmarkID)
        return context
    }

    func backgroundNotificationIncrement(for event: LegacyControlEvent,
                                                 context: BookmarkConnectionContext) -> Int {
        switch event {
        case .privateMessage, .broadcastMessage, .channelInvitation, .flatNewsPosted:
            return 1
        case let .offlineMessagesAvailable(count):
            return max(0, count)
        case let .channelMessage(message):
            let ownUserID = context.snapshot?.lastLoginResult?.session.userID
            return message.senderUserID == ownUserID ? 0 : 1
        default:
            return 0
        }
    }

    func clearBookmarkNotifications(for context: BookmarkConnectionContext) {
        context.eventNotificationCount = 0
        context.newsNotificationCount = 0
    }

    func parkActiveBookmarkConnection() {
        guard let id = activeBookmarkConnectionID,
              let context = bookmarkConnections[id], context.client === client else { return }
        context.snapshot = captureActiveBookmarkSession()
        if let snapshot = context.snapshot {
            persistTransferMonitorSession(bookmarkID: id, items: snapshot.transferMonitorItems,
                                          order: snapshot.transferMonitorOrder,
                                          operations: snapshot.clientTransferOperations,
                                          selectedTransferID: snapshot.selectedTransferID)
        }
        clearBookmarkNotifications(for: context)
        startBackgroundNewsPolling(for: context)
        configureClientCallbacks(for: context.client, bookmarkID: id)
    }

    func activate(bookmark: ServerBookmark) {
        if activeBookmarkConnectionID != bookmark.id, currentWorkspace == .serverInfo,
           !confirmServerInfoChangesCanBeAbandoned() { return }
        if activeBookmarkConnectionID != bookmark.id, currentWorkspace == .trackers,
           !confirmTrackerChangesCanBeAbandoned() { return }
        if activeBookmarkConnectionID == bookmark.id {
            selectedBookmarkID = bookmark.id
            apply(bookmark: bookmark)
            if currentWorkspace == .trackerBrowser {
                let returnWorkspace = serverWorkspaceBeforeTracker ?? .overview
                selectWorkspace(returnWorkspace)
            }
            reloadBookmarkStack()
            refreshShellChrome()
            return
        }

        // A modal Agreement cannot be safely moved to another server. Initial catalog
        // loading, however, is short-lived: remember the click and switch immediately
        // when bootstrap finishes instead of making the bookmark appear dead.
        guard !isAwaitingAgreementAcceptance else {
            pendingBookmarkActivationID = bookmark.id
            selectedBookmarkID = bookmark.id
            saveServerBookmarks()
            reloadBookmarkStack()
            return
        }
        if connectionSetupBookmarkID != nil, connectionSetupBookmarkID == activeBookmarkConnectionID {
            pendingBookmarkActivationID = bookmark.id
            selectedBookmarkID = bookmark.id
            saveServerBookmarks()
            reloadBookmarkStack()
            return
        }

        pendingBookmarkActivationID = nil
        if activeBookmarkConnectionID != nil {
            if autoReconnectWorkItem != nil { cancelAutoReconnect() }
            switch client.state {
            case .connecting, .handshaking, .authenticating:
                showBookmarkError(LegacyControlClientError.invalidInput(L("Wait for the current connection attempt to finish before switching bookmarks.")))
                return
            default:
                break
            }
            parkActiveBookmarkConnection()
        } else if client.isConnected {
            // An ad-hoc connection has no bookmark to park safely.
            client.disconnect()
        }

        clearPresentationForBookmarkSwitch()
        let context = bookmarkConnectionContext(for: bookmark.id)
        stopBackgroundNewsPolling(for: context)
        clearBookmarkNotifications(for: context)
        activeBookmarkConnectionID = bookmark.id
        client = context.client
        selectedBookmarkID = bookmark.id
        serverWorkspaceBeforeTracker = nil
        connectedBookmarkID = client.isConnected ? bookmark.id : nil
        switch client.state {
        case .connecting, .handshaking, .authenticating: connectingBookmarkID = bookmark.id
        default: connectingBookmarkID = nil
        }
        configureClientCallbacks(for: client, bookmarkID: bookmark.id)
        saveServerBookmarks()
        apply(bookmark: bookmark)

        if client.isConnected, let snapshot = context.snapshot {
            restoreBookmarkSession(snapshot)
            let queued = context.pendingEvents
            context.pendingEvents.removeAll()
            for event in queued { handle(event) }
        } else {
            context.snapshot = nil
            context.pendingEvents.removeAll()
            restorePersistedTransferMonitorSession(for: bookmark.id)
            refreshAdministrativeNavigationVisibility()
            selectWorkspace(.overview)
            refreshShellChrome()
        }
        reloadBookmarkStack()
    }

    func activatePendingBookmarkIfPossible() {
        guard connectionSetupBookmarkID == nil, !isAwaitingAgreementAcceptance,
              let pendingID = pendingBookmarkActivationID,
              let bookmark = serverBookmarks.first(where: { $0.id == pendingID }) else { return }
        pendingBookmarkActivationID = nil
        DispatchQueue.main.async { [weak self] in self?.activate(bookmark: bookmark) }
    }

    @objc func bookmarkPressed(_ sender: NSButton) {
        guard serverBookmarks.indices.contains(sender.tag) else { return }
        let bookmark = serverBookmarks[sender.tag]
        activate(bookmark: bookmark)

        // A single click only activates/switches the bookmark. Double-click keeps the
        // convenient connect shortcut for a disconnected bookmark.
        guard NSApp.currentEvent?.clickCount ?? 1 >= 2, activeBookmarkConnectionID == bookmark.id,
              !client.isConnected else { return }
        connect(to: bookmark)
    }

    func cancelAutoReconnect(clearBookmark: Bool = true) {
        autoReconnectWorkItem?.cancel()
        autoReconnectWorkItem = nil
        autoReconnectAttempt = 0
        if clearBookmark { autoReconnectBookmarkID = nil }
    }

    func discardTemporaryServerBookmarkAfterDisconnect(_ bookmarkID: UUID) {
        guard temporaryServerBookmarkIDs.remove(bookmarkID) != nil else { return }

        do { try serverBookmarkKeychain.removePassword(for: bookmarkID) }
        catch { appendLine("\n" + LF("Bookmark Keychain: %@", Self.displayMessage(for: error))) }
        serverBookmarks.removeAll { $0.id == bookmarkID }
        if let context = bookmarkConnections.removeValue(forKey: bookmarkID) {
            stopBackgroundNewsPolling(for: context)
            context.snapshot = nil
            context.pendingEvents.removeAll()
        }

        if selectedBookmarkID == bookmarkID { selectedBookmarkID = nil }
        if connectedBookmarkID == bookmarkID { connectedBookmarkID = nil }
        if connectingBookmarkID == bookmarkID { connectingBookmarkID = nil }
        if autoReconnectBookmarkID == bookmarkID { cancelAutoReconnect() }
        if pendingBookmarkActivationID == bookmarkID { pendingBookmarkActivationID = nil }
        if connectionSetupBookmarkID == bookmarkID { connectionSetupBookmarkID = nil }

        if activeBookmarkConnectionID == bookmarkID {
            activeBookmarkConnectionID = nil
            client = LegacyControlClient()
            configureClientCallbacks()
        }

        saveServerBookmarks()
        reloadBookmarkStack()
        if selectedBookmarkID == nil { passwordField.stringValue = "" }
    }

    func disconnectByUser() {
        let temporaryBookmarkID = activeBookmarkConnectionID.flatMap { id in
            temporaryServerBookmarkIDs.contains(id) ? id : nil
        }
        cancelAutoReconnect()
        connectingBookmarkID = nil
        switch client.state {
        case .idle:
            if let temporaryBookmarkID {
                discardTemporaryServerBookmarkAfterDisconnect(temporaryBookmarkID)
            }
        default:
            client.disconnect()
            if let temporaryBookmarkID, case .idle = client.state {
                discardTemporaryServerBookmarkAfterDisconnect(temporaryBookmarkID)
            }
        }
    }

    func scheduleAutoReconnect(for bookmarkID: UUID) {
        guard let bookmark = serverBookmarks.first(where: { $0.id == bookmarkID }), bookmark.autoReconnect else {
            cancelAutoReconnect()
            return
        }
        autoReconnectWorkItem?.cancel()
        autoReconnectBookmarkID = bookmarkID
        connectedBookmarkID = nil
        // A scheduled retry is not an active connection attempt. Keep the bookmark
        // indicator off until the retry actually starts.
        connectingBookmarkID = nil
        let delays: [TimeInterval] = [2, 5, 10, 20, 30]
        let delay = delays[min(autoReconnectAttempt, delays.count - 1)]
        autoReconnectAttempt += 1
        reloadBookmarkStack()
        statusLabel.stringValue = LF("Reconnect in %@ s …", String(Int(delay)))
        statusLabel.textColor = CarrachoTheme.warning
        refreshShellChrome()

        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.autoReconnectBookmarkID == bookmarkID,
                  let current = self.serverBookmarks.first(where: { $0.id == bookmarkID }),
                  current.autoReconnect else { return }
            self.autoReconnectWorkItem = nil
            self.connectingBookmarkID = bookmarkID
            self.apply(bookmark: current)
            self.reloadBookmarkStack()
            self.connectPressed(nil)
        }
        autoReconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func connect(to bookmark: ServerBookmark) {
        activate(bookmark: bookmark)
        guard activeBookmarkConnectionID == bookmark.id else { return }
        if client.isConnected { return }
        cancelAutoReconnect()
        selectedBookmarkID = bookmark.id
        connectingBookmarkID = bookmark.id
        connectedBookmarkID = nil
        autoReconnectBookmarkID = bookmark.autoReconnect ? bookmark.id : nil
        saveServerBookmarks()
        apply(bookmark: bookmark)
        reloadBookmarkStack()

        switch client.state {
        case .idle, .failed:
            connectPressed(nil)
        case .connecting, .handshaking, .authenticating:
            break
        default:
            client.disconnect()
            if case .idle = client.state {
                connectingBookmarkID = bookmark.id
                autoReconnectBookmarkID = bookmark.autoReconnect ? bookmark.id : nil
                reloadBookmarkStack()
                connectPressed(nil)
            }
        }
    }

    @objc func editBookmarkPressed(_ sender: NSButton) {
        guard serverBookmarks.indices.contains(sender.tag) else { return }
        let bookmark = serverBookmarks[sender.tag]
        do {
            let password = try serverBookmarkKeychain.password(for: bookmark.id) ?? ""
            presentBookmarkEditor(bookmark: bookmark, draft: ServerBookmarkDraft(bookmark: bookmark, password: password))
        } catch {
            showBookmarkError(error)
        }
    }

    @objc func changeBookmarkPasswordPressed(_ sender: NSButton) {
        guard serverBookmarks.indices.contains(sender.tag) else { return }
        let bookmark = serverBookmarks[sender.tag]
        // The action now lives inside the bookmark editor. Close that sheet first,
        // then present the dedicated account-password workflow on the parent window.
        if let sheet = sender.window, let parent = sheet.sheetParent {
            parent.endSheet(sheet, returnCode: .abort)
            DispatchQueue.main.async { [weak self] in
                self?.presentBookmarkPasswordChange(for: bookmark)
            }
        } else {
            presentBookmarkPasswordChange(for: bookmark)
        }
    }

    @objc func exportBookmarksPressed(_ sender: Any?) {
        guard let window = view.window else { return }
        guard serverBookmarks.contains(where: { !temporaryServerBookmarkIDs.contains($0.id) }) else {
            showBookmarkError(ServerBookmarkStoreError.invalidBookmark(L("there are no saved bookmarks to export")))
            return
        }

        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = L("Export Bookmarks with Passwords?")
        warning.informativeText = L("The export file contains all bookmark passwords in readable form so it can be imported on another Mac. Store the file securely.")
        warning.addButton(withTitle: L("Export"))
        warning.addButton(withTitle: L("Cancel"))
        warning.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let window = self.view.window else { return }
            do {
                let persistent = self.serverBookmarks.filter { !self.temporaryServerBookmarkIDs.contains($0.id) }
                let selected = self.selectedBookmarkID.flatMap { id in persistent.contains(where: { $0.id == id }) ? id : nil }
                let snapshot = ServerBookmarkStore.Snapshot(bookmarks: persistent, selectedID: selected)
                let data = try self.serverBookmarkStore.exportData(snapshot: snapshot, keychain: self.serverBookmarkKeychain)
                let panel = NSSavePanel()
                panel.title = L("Export Carracho Bookmarks")
                panel.nameFieldStringValue = "Carracho Bookmarks.carrachobookmarks"
                panel.allowedFileTypes = ["carrachobookmarks", "json"]
                panel.canCreateDirectories = true
                panel.beginSheetModal(for: window) { [weak self] result in
                    guard result == .OK, let url = panel.url else { return }
                    do {
                        try data.write(to: url, options: .atomic)
                    } catch {
                        self?.showBookmarkError(error)
                    }
                }
            } catch {
                self.showBookmarkError(error)
            }
        }
    }

    @objc func importBookmarksPressed(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = L("Import Carracho Bookmarks")
        panel.allowedFileTypes = ["carrachobookmarks", "json"]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self, let url = panel.url, let window = self.view.window else { return }
            do {
                let document = try self.serverBookmarkStore.decodeImport(Data(contentsOf: url))
                let confirm = NSAlert()
                confirm.alertStyle = .informational
                confirm.messageText = document.bookmarks.count == 1 ? LF("Import %@ Bookmark", String(document.bookmarks.count)) : LF("Import %@ Bookmarks", String(document.bookmarks.count))
                confirm.informativeText = L("Passwords from the file will be stored in the macOS Keychain. Merge updates matching bookmark IDs and keeps the rest; Replace All removes your current bookmarks first.")
                confirm.addButton(withTitle: L("Merge"))
                confirm.addButton(withTitle: L("Replace All"))
                confirm.addButton(withTitle: L("Cancel"))
                confirm.beginSheetModal(for: window) { [weak self] response in
                    guard let self else { return }
                    let mode: ServerBookmarkImportMode
                    if response == .alertFirstButtonReturn {
                        mode = .merge
                    } else if response == .alertSecondButtonReturn {
                        mode = .replaceAll
                    } else {
                        return
                    }
                    do {
                        let snapshot = try self.serverBookmarkStore.importDocument(document, mode: mode, keychain: self.serverBookmarkKeychain)
                        self.serverBookmarks = snapshot.bookmarks
                        self.temporaryServerBookmarkIDs.removeAll()
                        self.selectedBookmarkID = snapshot.selectedID
                        let validIDs = Set(snapshot.bookmarks.map(\.id))
                        let removedConnectionIDs = self.bookmarkConnections.keys.filter { !validIDs.contains($0) }
                        var removedActiveConnection = false
                        for id in removedConnectionIDs {
                            if let removed = self.bookmarkConnections.removeValue(forKey: id) {
                                self.stopBackgroundNewsPolling(for: removed)
                                removed.client.disconnect()
                            }
                            if self.activeBookmarkConnectionID == id {
                                self.activeBookmarkConnectionID = nil
                                removedActiveConnection = true
                            }
                        }
                        if removedActiveConnection {
                            self.client = LegacyControlClient()
                            self.configureClientCallbacks()
                            self.connectedBookmarkID = nil
                            self.connectingBookmarkID = nil
                            self.clearPresentationForBookmarkSwitch()
                        }
                        let importedLaunchID = document.bookmarks.first(where: { $0.connectAtLaunch })?.id
                        self.normalizeBookmarkIdentityInheritance()
                        self.normalizeLaunchBookmarks(preferredID: importedLaunchID)
                        if let reconnectID = self.autoReconnectBookmarkID,
                           self.serverBookmarks.first(where: { $0.id == reconnectID })?.autoReconnect != true {
                            self.cancelAutoReconnect()
                            self.connectingBookmarkID = nil
                        }
                        self.saveServerBookmarks()
                        self.reloadBookmarkStack()
                        self.applySelectedBookmarkToFields()
                    } catch {
                        self.showBookmarkError(error)
                    }
                }
            } catch {
                self.showBookmarkError(error)
            }
        }
    }

    func loadServerBookmarks() {
        let snapshot = serverBookmarkStore.load()
        temporaryServerBookmarkIDs.removeAll()
        serverBookmarks = snapshot.bookmarks
        selectedBookmarkID = snapshot.selectedID
        // Pre-vault versions stored one Keychain item per bookmark. Consolidate
        // them in one pass so future app updates require access to one item only.
        try? serverBookmarkKeychain.migrateLegacyPasswords(for: serverBookmarks.map(\.id))
        let identityChanged = normalizeBookmarkIdentityInheritance()
        let launchChanged = normalizeLaunchBookmarks()
        if identityChanged || launchChanged { saveServerBookmarks() }
    }

    /// Older builds copied the then-current global nickname/status into new bookmarks even
    /// though those values were effectively global. Collapse exact matches back to the new
    /// inheritance representation (empty override) once, so future global changes propagate.
    @discardableResult
    func normalizeBookmarkIdentityInheritance() -> Bool {
        guard generalIdentityConfigured else { return false }
        let globalNickname = generalNickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let globalStatus = (generalStatusMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        for index in serverBookmarks.indices {
            let nickname = serverBookmarks[index].nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nickname.isEmpty, nickname == globalNickname {
                serverBookmarks[index].nickname = ""
                changed = true
            }
            let status = serverBookmarks[index].statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !status.isEmpty, status == globalStatus {
                serverBookmarks[index].statusMessage = ""
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    func normalizeLaunchBookmarks(preferredID: UUID? = nil) -> Bool {
        let winner = preferredID.flatMap { preferred in
            serverBookmarks.first(where: { $0.id == preferred && $0.connectAtLaunch })?.id
        } ?? serverBookmarks.first(where: { $0.connectAtLaunch })?.id
        var changed = false
        for index in serverBookmarks.indices {
            let shouldLaunch = serverBookmarks[index].id == winner
            if serverBookmarks[index].connectAtLaunch != shouldLaunch {
                serverBookmarks[index].connectAtLaunch = shouldLaunch
                changed = true
            }
        }
        return changed
    }

    func makeExclusiveLaunchBookmark(_ bookmarkID: UUID) {
        for index in serverBookmarks.indices {
            serverBookmarks[index].connectAtLaunch = serverBookmarks[index].id == bookmarkID
        }
    }

    func saveServerBookmarks() {
        let persistent = serverBookmarks.filter { !temporaryServerBookmarkIDs.contains($0.id) }
        let persistentSelectedID = selectedBookmarkID.flatMap { selected in
            persistent.contains(where: { $0.id == selected }) ? selected : nil
        }
        serverBookmarkStore.save(.init(bookmarks: persistent, selectedID: persistentSelectedID))
    }

    func applySelectedBookmarkToFields() {
        guard let id = selectedBookmarkID, let bookmark = serverBookmarks.first(where: { $0.id == id }) else { return }
        apply(bookmark: bookmark)
    }

    func apply(bookmark: ServerBookmark) {
        hostField.stringValue = bookmark.host
        portField.stringValue = String(bookmark.port)
        loginField.stringValue = bookmark.login
        nicknameField.stringValue = effectiveNickname(for: bookmark)
        do {
            passwordField.stringValue = try serverBookmarkKeychain.password(for: bookmark.id) ?? ""
        } catch {
            passwordField.stringValue = ""
            appendLine("\n" + LF("Bookmark Keychain: %@", Self.displayMessage(for: error)))
        }
        refreshShellChrome()
    }

    func bookmarkConnectionState(for bookmarkID: UUID) -> String {
        if let context = bookmarkConnections[bookmarkID] {
            if context.client.isConnected { return "connected" }
            switch context.client.state {
            case .connecting, .handshaking, .authenticating: return "connecting"
            case .idle: return "disconnected"
            default: return "disconnected"
            }
        }
        if activeBookmarkConnectionID == bookmarkID {
            if client.isConnected { return "connected" }
            if connectingBookmarkID == bookmarkID { return "connecting" }
            return "disconnected"
        }
        return "unknown"
    }

    func bookmarkStatusDot(for bookmarkID: UUID) -> NSView {
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        let color: NSColor
        switch bookmarkConnectionState(for: bookmarkID) {
        case "connected":
            color = CarrachoTheme.success
            dot.toolTip = L("Connected")
        case "connecting":
            color = CarrachoTheme.warning
            dot.toolTip = L("Connecting…")
        case "disconnected":
            color = CarrachoTheme.secondaryText.withAlphaComponent(0.38)
            dot.toolTip = L("Not connected")
        default:
            color = CarrachoTheme.secondaryText.withAlphaComponent(0.26)
            dot.toolTip = L("Connection status unknown")
        }
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3.5
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        return dot
    }

    func bookmarkNotificationBadge(_ count: Int) -> NSTextField {
        let display = count > 99 ? "99+" : String(count)
        let badge = NSTextField(labelWithString: display)
        badge.identifier = NSUserInterfaceItemIdentifier("bookmarkNotificationBadge")
        badge.font = .systemFont(ofSize: 9.5, weight: .bold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 8
        badge.toolTip = count == 1 ? LF("%@ new notification on this server", String(count)) : LF("%@ new notifications on this server", String(count))
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 16),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: count > 99 ? 28 : 18),
        ])
        return badge
    }

    @objc func saveTemporaryBookmarkPressed(_ sender: NSButton) {
        guard serverBookmarks.indices.contains(sender.tag) else { return }
        let bookmark = serverBookmarks[sender.tag]
        guard temporaryServerBookmarkIDs.contains(bookmark.id), let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = L("Save Server Bookmark")
        alert.informativeText = L("Choose the permanent bookmark name.")
        alert.addButton(withTitle: L("Save Bookmark"))
        alert.addButton(withTitle: L("Cancel"))
        let name = NSTextField(string: bookmark.name)
        name.placeholderString = L("Server name")
        name.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        alert.accessoryView = name
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let index = self.serverBookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
            let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                self.showBookmarkError(ServerBookmarkStoreError.invalidBookmark(L("name must not be empty")))
                return
            }
            self.serverBookmarks[index].name = value
            self.temporaryServerBookmarkIDs.remove(bookmark.id)
            self.selectedBookmarkID = bookmark.id
            self.saveServerBookmarks()
            self.reloadBookmarkStack()
        }
    }

    func reloadBookmarkStack() {
        for view in bookmarkStack.arrangedSubviews {
            bookmarkStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !serverBookmarks.isEmpty else {
            let empty = infoLabel(L("No saved servers"))
            empty.font = .systemFont(ofSize: 10.5)
            empty.heightAnchor.constraint(equalToConstant: 20).isActive = true
            bookmarkStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: bookmarkStack.widthAnchor).isActive = true
            return
        }

        for (index, bookmark) in serverBookmarks.enumerated() {
            let row = CarrachoBackgroundView()
            row.fillColor = bookmark.id == selectedBookmarkID ? CarrachoTheme.selectionSoft : .clear
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 34).isActive = true

            // Keep saved-server cards deliberately compact: icon, server name, status and edit.
            // Endpoint/login details belong in the bookmark editor, not in a second card line.
            let open = BookmarkActionButton(title: "", target: self, action: #selector(bookmarkPressed(_:)))
            open.tag = index
            open.isBordered = false
            open.toolTip = LF("Click to activate; double-click to connect to %@:%@", bookmark.host, String(bookmark.port))
            open.translatesAutoresizingMaskIntoConstraints = false

            let icon = NSImageView()
            icon.image = Bundle.main.image(forResource: NSImage.Name("Tracker"))
                ?? NSImage(named: NSImage.Name("Tracker"))
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 17),
                icon.heightAnchor.constraint(equalToConstant: 17),
            ])
            let name = NSTextField(labelWithString: bookmark.name)
            name.font = .systemFont(ofSize: 11.5, weight: .medium)
            name.lineBreakMode = .byTruncatingTail
            name.toolTip = bookmark.name
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let statusDot = bookmarkStatusDot(for: bookmark.id)
            var bookmarkViews: [NSView] = [icon, statusDot, name]
            let notificationCount = bookmarkConnections[bookmark.id]?.notificationCount ?? 0
            if notificationCount > 0 { bookmarkViews.append(bookmarkNotificationBadge(notificationCount)) }
            let openStack = horizontalStack(bookmarkViews, spacing: 8)
            openStack.translatesAutoresizingMaskIntoConstraints = false
            let openContent = BookmarkButtonContentView()
            openContent.translatesAutoresizingMaskIntoConstraints = false
            openContent.addSubview(openStack)

            let isTemporary = temporaryServerBookmarkIDs.contains(bookmark.id)
            let edit = NSButton(title: isTemporary ? "💾" : "", target: self,
                                action: isTemporary ? #selector(saveTemporaryBookmarkPressed(_:)) : #selector(editBookmarkPressed(_:)))
            edit.tag = index
            edit.isBordered = false
            edit.toolTip = isTemporary ? L("Save this temporary server bookmark") : L("Edit bookmark")
            if isTemporary {
                edit.font = .systemFont(ofSize: 16)
            } else {
                edit.image = symbolImage("pencil", fallback: NSImage.actionTemplateName)
                edit.contentTintColor = CarrachoTheme.secondaryText
            }
            edit.translatesAutoresizingMaskIntoConstraints = false
            edit.widthAnchor.constraint(equalToConstant: 22).isActive = true
            edit.heightAnchor.constraint(equalToConstant: 26).isActive = true

            // The activation button covers the full card. Visual content is mouse-pass-through;
            // the edit button is added later and therefore remains an independent hit target.
            row.addSubview(open)
            row.addSubview(openContent)
            row.addSubview(edit)
            NSLayoutConstraint.activate([
                open.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                open.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                open.topAnchor.constraint(equalTo: row.topAnchor),
                open.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                edit.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
                edit.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                openContent.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
                openContent.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -4),
                openContent.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
                openContent.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -3),
                openStack.leadingAnchor.constraint(equalTo: openContent.leadingAnchor),
                openStack.trailingAnchor.constraint(equalTo: openContent.trailingAnchor),
                openStack.centerYAnchor.constraint(equalTo: openContent.centerYAnchor),
            ])
            bookmarkStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: bookmarkStack.widthAnchor).isActive = true
        }
    }

    func presentBookmarkPasswordChange(for bookmark: ServerBookmark) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L("Change Account Password")
        alert.informativeText = LF("Change the password for %@ on %@. The bookmark Keychain entry is updated only after the server confirms the change.", bookmark.login, bookmark.host)
        alert.addButton(withTitle: L("Change Password"))
        alert.addButton(withTitle: L("Cancel"))

        let newPassword = NSSecureTextField(string: "")
        let confirmation = NSSecureTextField(string: "")
        newPassword.placeholderString = L("New password (empty is allowed)")
        confirmation.placeholderString = L("Repeat new password")
        let grid = NSGridView(views: [
            [makeLabel(L("New Password")), newPassword],
            [makeLabel(L("Confirm")), confirmation],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 60)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = newPassword

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let value = newPassword.stringValue
            guard value == confirmation.stringValue else {
                self.presentBookmarkPasswordError(L("The two new passwords do not match."), bookmark: bookmark)
                return
            }
            guard let encoded = value.data(using: .macOSRoman), encoded.count <= 64 else {
                self.presentBookmarkPasswordError(L("The password must be representable in MacRoman and no longer than 64 bytes."), bookmark: bookmark)
                return
            }
            self.performBookmarkPasswordChange(bookmark: bookmark, newPassword: value)
        }
    }

    func presentBookmarkPasswordError(_ message: String, bookmark: ServerBookmark) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Change Account Password")
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.presentBookmarkPasswordChange(for: bookmark)
        }
    }

    func performBookmarkPasswordChange(bookmark: ServerBookmark, newPassword: String) {
        let finish: (LegacyControlClient, Bool, Result<Void, Error>) -> Void = { [weak self] passwordClient, temporary, result in
            guard let self else { return }
            if temporary {
                passwordClient.disconnect()
                if self.bookmarkPasswordChangeClient === passwordClient { self.bookmarkPasswordChangeClient = nil }
            }
            switch result {
            case .failure(let error):
                self.showBookmarkError(error)
            case .success:
                do {
                    try self.serverBookmarkKeychain.setPassword(newPassword, for: bookmark.id)
                    if self.selectedBookmarkID == bookmark.id { self.passwordField.stringValue = newPassword }
                    let confirmation = NSAlert()
                    confirmation.messageText = L("Password Changed")
                    confirmation.informativeText = L("The account password was changed on the server and the bookmark Keychain password was updated.")
                    confirmation.addButton(withTitle: L("OK"))
                    if let window = self.view.window { confirmation.beginSheetModal(for: window) }
                } catch {
                    if self.selectedBookmarkID == bookmark.id { self.passwordField.stringValue = newPassword }
                    let warning = NSAlert()
                    warning.alertStyle = .warning
                    warning.messageText = L("Server Password Changed, Keychain Update Failed")
                    warning.informativeText = LF("The server accepted the new password, but macOS Keychain could not store it: %@. Save the new password in the bookmark before reconnecting.", Self.displayMessage(for: error))
                    warning.addButton(withTitle: L("OK"))
                    if let window = self.view.window { warning.beginSheetModal(for: window) }
                }
            }
        }

        if let liveClient = bookmarkConnections[bookmark.id]?.client, liveClient.isConnected {
            liveClient.changeOwnPassword(to: newPassword) { result in finish(liveClient, false, result) }
            return
        }

        guard bookmarkPasswordChangeClient == nil else {
            showBookmarkError(LegacyControlClientError.invalidInput(L("A bookmark password change is already in progress.")))
            return
        }
        let oldPassword: String
        do {
            oldPassword = try serverBookmarkKeychain.password(for: bookmark.id) ?? ""
        } catch {
            showBookmarkError(error)
            return
        }
        guard let profileNickname = generalNickname else {
            menuSettings(nil)
            clientSettingsWindow?.makeKeyAndOrderFront(nil)
            clientSettingsWindow?.makeFirstResponder(clientSettingsNicknameField)
            return
        }
        let passwordClient = LegacyControlClient()
        bookmarkPasswordChangeClient = passwordClient
        passwordClient.connect(host: bookmark.host, port: bookmark.port, login: bookmark.login,
                               password: oldPassword, nickname: profileNickname) { [weak self, weak passwordClient] result in
            guard let self, let passwordClient else { return }
            switch result {
            case .failure(let error):
                passwordClient.disconnect()
                if self.bookmarkPasswordChangeClient === passwordClient { self.bookmarkPasswordChangeClient = nil }
                self.showBookmarkError(error)
            case .success:
                passwordClient.changeOwnPassword(to: newPassword) { changeResult in
                    finish(passwordClient, true, changeResult)
                }
            }
        }
    }

    func presentBookmarkEditor(bookmark: ServerBookmark?, draft suppliedDraft: ServerBookmarkDraft? = nil) {
        guard let window = view.window else { return }
        let draft: ServerBookmarkDraft
        if let suppliedDraft {
            draft = suppliedDraft
        } else if let bookmark {
            do {
                draft = ServerBookmarkDraft(bookmark: bookmark, password: try serverBookmarkKeychain.password(for: bookmark.id) ?? "")
            } catch {
                showBookmarkError(error)
                return
            }
        } else {
            draft = ServerBookmarkDraft(bookmark: nil)
        }

        if let existing = serverBookmarkEditorWindowController?.window {
            if let parent = existing.sheetParent { parent.endSheet(existing) }
            else { existing.orderOut(nil) }
        }

        let globalNicknameHint = generalNickname ?? L("Carracho Settings")
        let globalStatusHint = (generalStatusMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let controller = ServerBookmarkEditorWindowController(
            draft: draft,
            isNew: bookmark == nil,
            globalNicknameHint: globalNicknameHint,
            globalStatusHint: globalStatusHint,
            canChangeAccountPassword: bookmark != nil
        )
        serverBookmarkEditorWindowController = controller

        controller.onChangePassword = { [weak self] in
            guard let self, let bookmark else { return }
            self.presentBookmarkPasswordChange(for: bookmark)
        }
        controller.onDelete = { [weak self] in
            guard let self, let bookmark else { return }
            do {
                try self.serverBookmarkKeychain.removePassword(for: bookmark.id)
                self.serverBookmarks.removeAll { $0.id == bookmark.id }
                if let context = self.bookmarkConnections.removeValue(forKey: bookmark.id) {
                    self.stopBackgroundNewsPolling(for: context)
                    context.client.disconnect()
                }
                let removedActive = self.activeBookmarkConnectionID == bookmark.id
                if self.selectedBookmarkID == bookmark.id { self.selectedBookmarkID = nil }
                if self.connectedBookmarkID == bookmark.id { self.connectedBookmarkID = nil }
                if self.connectingBookmarkID == bookmark.id { self.connectingBookmarkID = nil }
                if self.autoReconnectBookmarkID == bookmark.id { self.cancelAutoReconnect() }
                if removedActive {
                    self.activeBookmarkConnectionID = nil
                    self.client = LegacyControlClient()
                    self.configureClientCallbacks()
                    self.clearPresentationForBookmarkSwitch()
                    self.refreshShellChrome()
                }
                self.saveServerBookmarks()
                self.reloadBookmarkStack()
                if self.selectedBookmarkID == nil { self.passwordField.stringValue = "" }
            } catch {
                self.showBookmarkError(error)
            }
        }
        controller.onSave = { [weak self] current in
            self?.commitBookmarkEditorDraft(current, bookmark: bookmark)
        }
        controller.onFinish = { [weak self, weak controller] in
            guard let self else { return }
            if self.serverBookmarkEditorWindowController === controller {
                self.serverBookmarkEditorWindowController = nil
            }
        }
        controller.beginSheet(for: window)
    }

    private func commitBookmarkEditorDraft(_ current: ServerBookmarkDraft, bookmark: ServerBookmark?) {
        let trimmedName = current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = current.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            presentBookmarkValidationError(L("Bookmark name must not be empty."), bookmark: bookmark, draft: current)
            return
        }
        guard !trimmedHost.isEmpty else {
            presentBookmarkValidationError(L("Server address must not be empty."), bookmark: bookmark, draft: current)
            return
        }
        guard let parsedPort = UInt16(current.port), parsedPort > 0, parsedPort < UInt16.max else {
            presentBookmarkValidationError(L("Port must be between 1 and 65534."), bookmark: bookmark, draft: current)
            return
        }
        guard current.password.utf8.count <= 4096 else {
            presentBookmarkValidationError(L("Password must not exceed 4096 UTF-8 bytes."), bookmark: bookmark, draft: current)
            return
        }
        guard let statusData = current.statusMessage.data(using: .macOSRoman), statusData.count <= 255 else {
            presentBookmarkValidationError(L("Status must be MacRoman-compatible and at most 255 bytes."), bookmark: bookmark, draft: current)
            return
        }
        let trimmedLogin = current.login.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNickname = current.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isReservedAnonymousNickname(trimmedNickname) {
            presentBookmarkValidationError(L("‘anonymous’ is reserved for the guest login and cannot be used as a nickname."), bookmark: bookmark, draft: current)
            return
        }
        if !trimmedNickname.isEmpty {
            guard let nicknameData = trimmedNickname.data(using: .macOSRoman), nicknameData.count <= 64 else {
                presentBookmarkValidationError(L("Nickname override must be MacRoman-compatible and at most 64 bytes."), bookmark: bookmark, draft: current)
                return
            }
        }

        let updated = ServerBookmark(
            id: bookmark?.id ?? UUID(),
            name: trimmedName,
            host: trimmedHost,
            port: parsedPort,
            login: trimmedLogin,
            nickname: trimmedNickname,
            statusMessage: current.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines),
            autoReconnect: current.autoReconnect,
            connectAtLaunch: current.connectAtLaunch,
            acceptsOfflineMessages: current.acceptsOfflineMessages
        )
        do {
            try serverBookmarkKeychain.setPassword(current.password, for: updated.id)
        } catch {
            showBookmarkError(error)
            return
        }
        if let bookmark, let index = serverBookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            serverBookmarks[index] = updated
        } else {
            serverBookmarks.append(updated)
        }
        if updated.connectAtLaunch { makeExclusiveLaunchBookmark(updated.id) }
        if !updated.autoReconnect, autoReconnectBookmarkID == updated.id { cancelAutoReconnect() }
        selectedBookmarkID = updated.id
        saveServerBookmarks()
        apply(bookmark: updated)
        reloadBookmarkStack()
        publishNickname(for: updated, logErrors: true)
        if connectedBookmarkID == updated.id, client.isConnected {
            publishStatusMessage(for: updated, logErrors: true)
            client.setOfflineMessagePreference(enabled: updated.acceptsOfflineMessages) { [weak self] result in
                if case let .failure(error) = result {
                    self?.appendLine("\n" + LF("Offline-message preference could not be updated: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    func presentBookmarkValidationError(_ message: String, bookmark: ServerBookmark?, draft: ServerBookmarkDraft) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Invalid Bookmark")
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.presentBookmarkEditor(bookmark: bookmark, draft: draft)
        }
    }

    func showBookmarkError(_ error: Error) {
        guard let window = view.window else {
            appendLine("\n" + LF("Bookmark error: %@", Self.displayMessage(for: error)))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Bookmarks")
        alert.informativeText = Self.displayMessage(for: error)
        alert.addButton(withTitle: L("OK"))
        alert.beginSheetModal(for: window)
    }

    @objc func connectionButtonPressed(_ sender: Any?) {
        if currentWorkspace == .serverInfo, serverInfoHasUnsavedChanges,
           !confirmServerInfoChangesCanBeAbandoned() { return }
        if currentWorkspace == .trackers, trackerHasUnsavedChanges,
           !confirmTrackerChangesCanBeAbandoned() { return }
        if client.isConnected || autoReconnectWorkItem != nil {
            disconnectByUser()
            reloadBookmarkStack()
            refreshShellChrome()
        } else if let id = selectedBookmarkID,
                  let bookmark = serverBookmarks.first(where: { $0.id == id }) {
            connect(to: bookmark)
        } else {
            presentConnectionSheet()
        }
    }

    func presentConnectionSheet() {
        guard let window = view.window else { return }

        // Never reuse the live connection fields here. They are deliberately disabled while a
        // server is connected and also contain that server's credentials, which made Server >
        // Connect to Server… effectively unusable for opening a second, unbookmarked server.
        let server = NSTextField(string: "")
        let port = NSTextField(string: String(LegacyWire.defaultControlPort))
        let login = NSTextField(string: "")
        let password = NSSecureTextField(string: "")
        let nickname = NSTextField(string: "")
        server.placeholderString = "server.example.com"
        login.placeholderString = L("Login")
        password.placeholderString = L("Password")
        nickname.placeholderString = generalNickname.map { LF("General: %@", $0) } ?? L("Nickname")
        for field in [server, port, login, password, nickname] {
            field.isEnabled = true
            field.isEditable = true
            field.font = .systemFont(ofSize: 13)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        let alert = NSAlert()
        alert.messageText = L("Connect to Carracho Server")
        alert.informativeText = L("Enter the server and your Carracho account.")
        alert.addButton(withTitle: L("Connect"))
        alert.addButton(withTitle: L("Cancel"))
        let grid = NSGridView(views: [
            [makeLabel(L("Server")), server],
            [makeLabel(L("Port")), port],
            [makeLabel(L("Login")), login],
            [makeLabel(L("Password")), password],
            [makeLabel(L("Nickname")), nickname],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.frame = NSRect(x: 0, y: 0, width: 430, height: 172)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = server
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            server.window?.endEditing(for: nil)
            self.connectTemporaryServer(
                host: server.stringValue,
                portText: port.stringValue,
                login: login.stringValue,
                password: password.stringValue,
                nickname: nickname.stringValue
            )
        }
    }

    private func connectTemporaryServer(host rawHost: String,
                                        portText: String,
                                        login rawLogin: String,
                                        password: String,
                                        nickname rawNickname: String) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = rawLogin.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = rawNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { showError(L("Enter a server name or IP address.")); return }
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), port != 0 else {
            showError(L("Port must be between 1 and 65535.")); return
        }
        guard !login.isEmpty,
              let loginData = login.data(using: .macOSRoman), loginData.count <= 30 else {
            showError(L("Login must be MacRoman-compatible and at most 30 bytes.")); return
        }
        guard let passwordData = password.data(using: .macOSRoman), passwordData.count <= 64 else {
            showError(L("Password must be MacRoman-compatible and at most 64 bytes.")); return
        }
        if !nickname.isEmpty {
            guard let nicknameData = nickname.data(using: .macOSRoman), nicknameData.count <= 64 else {
                showError(L("Nickname must be MacRoman-compatible and at most 64 bytes.")); return
            }
        }

        let displayName = port == LegacyWire.defaultControlPort ? host : "\(host):\(port)"
        let bookmark = ServerBookmark(
            name: displayName,
            host: host,
            port: port,
            login: login,
            nickname: nickname,
            statusMessage: "",
            autoReconnect: false,
            connectAtLaunch: false,
            acceptsOfflineMessages: true
        )
        do {
            // Temporary bookmarks are intentionally excluded from UserDefaults, but their
            // password still needs a safe home while the connection is alive. If the user clicks
            // the disk button this same Keychain entry simply becomes the permanent bookmark's.
            try serverBookmarkKeychain.setPassword(password, for: bookmark.id)
        } catch {
            showBookmarkError(error)
            return
        }
        serverBookmarks.insert(bookmark, at: 0)
        temporaryServerBookmarkIDs.insert(bookmark.id)
        selectedBookmarkID = bookmark.id
        reloadBookmarkStack()
        connect(to: bookmark)
    }
    enum FileNavigationCommit {
        case push
        case history(Int)
        case initialize
        case none
    }

    var selectedVisibleFileRows: [VisibleFileRow] {
        let rows = visibleFileRows
        return fileTable.selectedRowIndexes.compactMap { index in
            guard index >= 0, index < rows.count else { return nil }
            return rows[index]
        }
    }

    nonisolated static func isSimpleIPv4Ban(_ rule: ServerIPRestriction) -> Bool {
        rule.deny && rule.mask == Data([255, 255, 255, 255]) && rule.reserved == 0 && rule.network.count == 4
    }

    func configureClientCallbacks() {
        configureClientCallbacks(for: client, bookmarkID: activeBookmarkConnectionID)
    }

    func configureClientCallbacks(for target: LegacyControlClient, bookmarkID: UUID?) {
        target.onStateChange = { [weak self, weak target] state in
            guard let self, let target else { return }
            if target === self.client && self.activeBookmarkConnectionID == bookmarkID {
                if let bookmarkID, let context = self.bookmarkConnections[bookmarkID] {
                    switch state {
                    case .idle, .failed:
                        self.stopBackgroundNewsPolling(for: context)
                        self.clearBookmarkNotifications(for: context)
                        context.snapshot = nil
                        context.pendingEvents.removeAll()
                    default:
                        break
                    }
                }
                self.apply(state: state)
                return
            }
            // Background bookmark connections keep running, but must never repaint the
            // currently selected server's UI. Their lamp alone is updated here.
            if let bookmarkID, let context = self.bookmarkConnections[bookmarkID] {
                switch state {
                case .idle, .failed:
                    self.stopBackgroundNewsPolling(for: context)
                    self.clearBookmarkNotifications(for: context)
                    context.snapshot = nil
                    context.pendingEvents.removeAll()
                default:
                    break
                }
            }
            self.reloadBookmarkStack()
        }
        target.onEvent = { [weak self, weak target] event in
            guard let self, let target else { return }
            if target === self.client && self.activeBookmarkConnectionID == bookmarkID {
                self.handle(event)
                return
            }
            guard let bookmarkID, let context = self.bookmarkConnections[bookmarkID] else { return }
            let increment = self.backgroundNotificationIncrement(for: event, context: context)
            if increment > 0 {
                context.eventNotificationCount = min(999, context.eventNotificationCount + increment)
                self.reloadBookmarkStack()
            }
            if context.pendingEvents.count >= 500 { context.pendingEvents.removeFirst(context.pendingEvents.count - 499) }
            context.pendingEvents.append(event)
        }
    }

    func clearBookmarkConnectingIndicatorAfterRejectedAttempt() {
        guard let bookmarkID = connectingBookmarkID else { return }
        connectingBookmarkID = nil
        if autoReconnectBookmarkID == bookmarkID { cancelAutoReconnect() }
        reloadBookmarkStack()
    }

    @objc func connectPressed(_ sender: Any?) {
        if client.isConnected {
            disconnectByUser()
            return
        }

        guard let generalNickname else {
            resumeConnectionBookmarkID = connectingBookmarkID ?? activeBookmarkConnectionID
            clearBookmarkConnectingIndicatorAfterRejectedAttempt()
            resumeConnectionAfterIdentitySetup = true
            menuSettings(nil)
            clientSettingsWindow?.makeKeyAndOrderFront(nil)
            clientSettingsWindow?.makeFirstResponder(clientSettingsNicknameField)
            return
        }
        let identityBookmarkID = connectingBookmarkID ?? activeBookmarkConnectionID ?? selectedBookmarkID
        if let identityBookmarkID, let bookmark = serverBookmarks.first(where: { $0.id == identityBookmarkID }) {
            nicknameField.stringValue = effectiveNickname(for: bookmark)
        } else {
            nicknameField.stringValue = generalNickname
        }

        guard let port = UInt16(portField.stringValue), port != 0 else {
            clearBookmarkConnectingIndicatorAfterRejectedAttempt()
            showError(L("Port must be between 1 and 65535."))
            return
        }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            clearBookmarkConnectingIndicatorAfterRejectedAttempt()
            showError(L("Enter a server name or IP address."))
            return
        }

        if connectingBookmarkID == nil,
           let selectedBookmarkID,
           let bookmark = serverBookmarks.first(where: { $0.id == selectedBookmarkID }),
           bookmark.host.caseInsensitiveCompare(host) == .orderedSame,
           bookmark.port == port,
           bookmark.login == loginField.stringValue,
           effectiveNickname(for: bookmark) == nicknameField.stringValue {
            connectingBookmarkID = bookmark.id
            autoReconnectBookmarkID = bookmark.autoReconnect ? bookmark.id : nil
            autoReconnectAttempt = 0
            reloadBookmarkStack()
        } else if connectingBookmarkID == nil {
            cancelAutoReconnect()
        }

        resetSessionViews()
        detailsTextView.string = LF("Connecting to %@:%@…\n", host, String(port))

        let connectingLogin = loginField.stringValue
        let setupBookmarkID = activeBookmarkConnectionID
        connectionSetupBookmarkID = setupBookmarkID
        client.connect(host: host,
                       port: port,
                       login: connectingLogin,
                       password: passwordField.stringValue,
                       nickname: nicknameField.stringValue) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                if self.connectionSetupBookmarkID == setupBookmarkID { self.connectionSetupBookmarkID = nil }
                if case .failed = self.client.state { return }
                self.clearBookmarkConnectingIndicatorAfterRejectedAttempt()
                self.showError(Self.displayMessage(for: error))
            case let .success(login):
                self.lastLoginResult = login
                self.liveUsers = Dictionary(uniqueKeysWithValues: login.users.map { ($0.userID, $0) })
                self.sleepingUsers = Set(login.users.lazy.filter { ($0.flags & 0x0100) != 0 }.map(\.userID))
                self.configureMessageCenterPersistence(host: host, port: port, login: connectingLogin)
                self.userStatusMessages = [:]
                self.userGroupColors = [:]
                self.renderSession()
                self.presentLoginAgreementIfNeeded(login.agreement, serverName: login.serverName) { [weak self] accepted in
                    guard let self else { return }
                    guard accepted else {
                        if self.connectionSetupBookmarkID == setupBookmarkID { self.connectionSetupBookmarkID = nil }
                        self.deferredInteractiveEvents.removeAll()
                        self.disconnectByUser()
                        return
                    }
                    guard self.client.isConnected, self.lastLoginResult?.session.userID == login.session.userID else { return }
                    self.completeConnectedSessionSetup(login: login, host: host, port: port, loginName: connectingLogin)
                }
            }
        }
    }

    func presentLoginAgreementIfNeeded(_ agreement: LegacyAgreementContent?, serverName: String,
                                               completion: @escaping (Bool) -> Void) {
        guard let agreement else {
            isAwaitingAgreementAcceptance = false
            completion(true)
            return
        }

        isAwaitingAgreementAcceptance = true
        guard let window = view.window else {
            appendLine("\n" + L("The server requires an Agreement, but no window is available to present it."))
            isAwaitingAgreementAcceptance = false
            completion(false)
            return
        }

        let text = Self.macRomanString(agreement.text)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 250))
        textView.string = text.isEmpty ? L("This server requires you to accept its Agreement before continuing.") : text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 250))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.documentView = textView

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Server Agreement")
        alert.informativeText = LF("%@ requires you to accept this Agreement before entering the server.", serverName)
        alert.accessoryView = scroll
        alert.addButton(withTitle: L("Accept"))
        alert.addButton(withTitle: L("Disconnect"))
        let smokePath = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--agreement-smoke-dump=") })
            .map { String($0.dropFirst("--agreement-smoke-dump=".count)) }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let accepted = response == .alertFirstButtonReturn
            self.isAwaitingAgreementAcceptance = false
            if let smokePath, !smokePath.isEmpty {
                let object: [String: Any] = [
                    "presented": true,
                    "accepted": accepted,
                    "server": serverName,
                    "text": text,
                    "buttons": ["Accept", "Disconnect"],
                ]
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: smokePath), options: .atomic)
                }
            }
            completion(accepted)
        }
        if let smokePath, !smokePath.isEmpty {
            let decline = ProcessInfo.processInfo.arguments.contains("--agreement-smoke-decline")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak alert] in
                guard let alert else { return }
                (decline ? alert.buttons.dropFirst().first : alert.buttons.first)?.performClick(nil)
            }
        }
    }

    func completeConnectedSessionSetup(login: LegacyLoginResult, host: String, port: UInt16, loginName: String) {
        // Every freshly established server session starts on Overview. Bootstrap tasks such as
        // auto-joining the public lobby must not steal the user's initial workspace.
        selectWorkspace(.overview)
        activeAvatarIdentity = LocalAvatarIdentity(host: host, port: port, login: loginName)
        if offlineMessageCenterUnreadCount > 0 {
            presentOfflineMessageLoginAlertIfNeeded(count: offlineMessageCenterUnreadCount)
        }
        configureNewsReadScope(host: host, port: port, login: loginName)
        refreshUserStatuses()
        if let connectedBookmarkID, let bookmark = serverBookmarks.first(where: { $0.id == connectedBookmarkID }) {
            publishStatusMessage(for: bookmark, logErrors: false)
            client.setOfflineMessagePreference(enabled: bookmark.acceptsOfflineMessages) { [weak self] result in
                if case let .failure(error) = result {
                    self?.appendLine("\n" + LF("Offline-message preference could not be synchronized: %@", Self.displayMessage(for: error)))
                }
            }
        } else if let status = generalStatusMessage,
                  let data = status.data(using: .macOSRoman), data.count <= 255 {
            userStatusMessages[login.session.userID] = data
            client.updateStatusMessage(data) { [weak self] result in
                if case let .failure(error) = result {
                    self?.appendLine("\n" + LF("General status could not be synchronized: %@", Self.displayMessage(for: error)))
                }
            }
        } else {
            userStatusMessages[login.session.userID] = Data()
        }
        synchronizeLocalAvatarAfterLogin(login)
        if generalIdentityConfigured,
           let emailData = generalEmail.data(using: .macOSRoman), emailData.count <= 64,
           let aboutMeData = generalAboutMe.data(using: .macOSRoman), aboutMeData.count <= 128 {
            synchronizeGeneralProfileFields(email: emailData, aboutMe: aboutMeData, to: client,
                                            ownUserID: login.session.userID, logErrors: false)
        }
        if let transferSession = client.transferSession {
            do {
                newsClient = try LegacyNewsClient(host: host, controlPort: port, session: transferSession)
            } catch {
                newsClient = nil
                appendLine("\n" + LF("News transfer is unavailable for this connection: %@", Self.displayMessage(for: error)))
            }
            if login.supportsMediaAttachments {
                do {
                    let media = try LegacyMediaClient(host: host, controlPort: port, session: transferSession)
                    mediaClient = media
                    mediaCache = CarrachoMediaCache(namespace: media.cacheNamespace)
                } catch {
                    mediaClient = nil
                    mediaCache = nil
                    appendLine("\n" + LF("Media attachments are unavailable: %@", Self.displayMessage(for: error)))
                }
            } else {
                mediaClient = nil
                mediaCache = nil
            }
            do {
                fileSearchClient = try LegacyFileSearchClient(host: host, controlPort: port, session: transferSession)
            } catch {
                fileSearchClient = nil
                appendLine("\n" + LF("File search is unavailable for this connection: %@", Self.displayMessage(for: error)))
            }
            do {
                bannerClient = try LegacyBannerClient(host: host, controlPort: port, session: transferSession)
                refreshRemoteBanner(logErrors: false)
            } catch {
                bannerClient = nil
                currentBanner = nil
                rightBannerImageView.image = nil
                    }
            do {
                fileTransferClient = try LegacyFileTransferClient(host: host, controlPort: port, session: transferSession)
            } catch {
                fileTransferClient = nil
                appendLine("\n" + LF("File transfer is unavailable for this connection: %@", Self.displayMessage(for: error)))
            }
            refreshTransferMonitorUI()
        }
        renderSession()
        if currentWorkspace == .accounts { reloadRemoteAccounts() }
        if currentWorkspace == .advanced { reloadBanManagement() }
        client.requestServerInfo { [weak self] infoResult in
            guard let self else { return }
            switch infoResult {
            case let .success(info):
                self.lastServerInfo = info
                if let ticks = info.uptimeTicks {
                    self.applyRemoteServerUptimeTicks(ticks)
                } else {
                    self.refreshRemoteServerUptime()
                }
                self.renderSession()
                self.scheduleClientTransferQueue(refreshCapacity: false)
            case let .failure(error):
                self.appendLine("\n" + LF("Server Info could not be loaded: %@", Self.displayMessage(for: error)))
            }
            self.loadInitialCatalogs { [weak self] in
                guard let self else { return }
                self.connectionSetupBookmarkID = nil
                self.startChannelCatalogPolling()
                self.replayDeferredInteractiveEvents()
                self.activatePendingBookmarkIfPossible()
            }
        }
    }

    func replayDeferredInteractiveEvents() {
        guard !isAwaitingAgreementAcceptance, client.isConnected, !deferredInteractiveEvents.isEmpty else { return }
        let events = deferredInteractiveEvents
        deferredInteractiveEvents.removeAll()
        for event in events { handle(event) }
    }

    func resetSessionViews() {
        cleanupQuickView(closePanel: true)
        flatNewsWindowController?.close()
        flatNewsWindowController = nil
        transferQueueRetryWorkItem?.cancel()
        transferQueueRetryWorkItem = nil
        transferCapacityRequestInFlight = false
        activeAvatarIdentity = nil
        lastLoginResult = nil
        lastServerInfo = nil
        remoteServerUptimeSeconds = nil
        remoteServerUptimeObservedAt = nil
        serverUptimeDisplayTimer?.invalidate()
        serverUptimeDisplayTimer = nil
        lastDirectory = nil
        for id in transferMonitorOrder {
            guard var item = transferMonitorItems[id], item.active else { continue }
            item.attemptGeneration &+= 1
            if item.attemptGeneration == 0 { item.attemptGeneration = 1 }
            item.active = false
            item.queued = false
            item.paused = false
            item.resumable = true
            item.resumeOnStart = true
            item.rateBytesPerSecond = nil
            item.errorMessage = L("The connection ended before this transfer completed.")
            item.state = L("Interrupted · reconnect to resume")
            transferMonitorItems[id] = item
            clientTransferTasks.removeValue(forKey: id)?.cancel()
        }
        fileTransferClient = nil
        refreshTransferMonitorUI()
        fileSearchClient = nil
        bannerClient = nil
        currentBanner = nil
        rightBannerImageView.image = nil
        fileSearchResults = nil
        fileSearchGeneration += 1
        isFileSearchBusy = false
        fileDirectoryLoadGeneration &+= 1
        fileDirectoryLoading = false
        filePendingDirectoryPath = nil
        fileDirectoryError = nil
        fileSearchError = nil
        fileNavigationHistory = []
        fileNavigationIndex = -1
        selectedFilePaths.removeAll()
        pendingFileScrollRestoreY = nil
        fileShouldResetScrollOnNextReload = true
        fileNeedsInitialWorkspaceTopAlignment = false
        resetInlineFileExpansion()
        fileSearchField.stringValue = ""
        fileTransferLabel.stringValue = ""
        clearRemoteTransferMonitorState()
        lastChannels = []
        lastNewsgroups = []
        newsClient = nil
        currentNewsIndex = nil
        currentArticle = nil
        currentNewsCategory = nil
        currentNewsThreads = []
        currentNewsThreadID = nil
        currentNewsThreadPosts = []
        currentNewsThreadArticles = []
        currentNewsReactions = [:]
        currentNewsPostCapabilities = [:]
        newsReactionsSupported = true
        newsThreadsByCategory = [:]
        newsThreadPreviewsByCategory = [:]
        newsThreadPreviewLoading = [:]
        newsLoadErrorMessage = nil
        newsReplyContextKey = nil
        newsReplyTargetArticleID = nil
        newsReplySending = false
        newsReplyMediaBusy = false
        newsReplyTextView.string = ""
        newsReplyAttachments.clear()
        newsReadScope = nil
        newsReadState = NewsReadState()
        newsBadgesSupported = true
        isAwaitingAgreementAcceptance = false
        deferredInteractiveEvents.removeAll()
        stopNewsBadgePolling()
        stopChannelCatalogPolling()
        clearChatSessions()
        privateMessageConversations = [:]
        selectedPrivateConversationID = nil
        offlineMessageCenterMessages = []
        offlineMessageCenterUnreadIDs = []
        offlineMessageCenterUnreadCount = 0
        messageCenterPersistenceScope = nil
        offlineMessageLoginNoticePresented = false
        selectedOfflineMessages = false
        offlineMessageFetchInFlight = false
        privateMessageSearchQuery = ""
        privateMessageSearchField.stringValue = ""
        privateMessageComposer.string = ""
        refreshPrivateMessageCenter(scrollToBottom: false)
        liveUsers = [:]
        selectedUserID = nil
        sleepingUsers = []
        userStatusMessages = [:]
        userGroupColors = [:]
        remoteServerLogLoading = false
        remoteEventLogLoading = false
        advancedTrashOperationInProgress = false
        advancedSearchIndexRebuildInProgress = false
        serverLogTextView.string = ""
        eventLogRawText = ""
        eventLogTextView.string = ""
        eventLogFilterStatusLabel.stringValue = ""
        if statisticsSourceKey?.hasPrefix("remote:") == true {
            statisticsRefreshGeneration &+= 1
            statisticsLoading = false
            statisticsStale = statisticsSnapshot != nil
            statisticsStatusOverride = statisticsSnapshot == nil
                ? L("Connection lost before statistics were loaded.")
                : L("Connection lost · showing the last successfully loaded statistics.")
            statisticsStatusColor = statisticsSnapshot == nil ? .systemRed : CarrachoTheme.warning
            updateStatisticsPresentation()
        }
        if trackerSourceKey?.hasPrefix("remote:") == true {
            trackerLoadGeneration &+= 1
            remoteTrackerSettingsLoading = false
            trackerSaveInProgress = false
            if trackerHasUnsavedChanges {
                trackerStatusOverride = L("Connection lost. Unsaved Tracker changes were kept and can be retried after reconnecting.")
                trackerStatusColor = CarrachoTheme.warning
            } else if trackerLoadedSnapshot != nil {
                trackerStatusOverride = L("Connection lost · showing the last loaded Tracker configuration.")
                trackerStatusColor = CarrachoTheme.warning
            }
            updateTrackerEditorState()
        }
        remoteAccountSummaries = []
        remoteAccountGroups = []
        remoteAccountGroupByLogin = [:]
        remoteAccountListLoading = false
        remoteNewsgroupAdministrationGeneration &+= 1
        remoteNewsgroupAdministrationLoading = false
        remoteAdminNewsgroups = []
        adminNewsgroupTable.reloadData()
        adminAccountStatusLabel.stringValue = ""
        adminAccountTable.reloadData()
        if currentWorkspace == .serverInfo { reloadServerInfoAdministration() }
        if currentWorkspace == .trackers {
            if trackerSourceKey?.hasPrefix("remote:") == true { updateTrackerEditorState() }
            else { reloadTrackerAdministration() }
        }
        reloadCatalogViews()
    }

    func loadInitialCatalogs(completion: (() -> Void)? = nil) {
        fileDirectoryLoadGeneration &+= 1
        let directoryGeneration = fileDirectoryLoadGeneration
        let target = client
        let sourceKey = currentFilesSourceKey()
        fileDirectoryLoading = true
        filePendingDirectoryPath = Data()
        fileDirectoryError = nil
        fileSearchError = nil
        fileNavigationHistory = []
        fileNavigationIndex = -1
        fileShouldResetScrollOnNextReload = true
        fileNeedsInitialWorkspaceTopAlignment = true
        updateFileBrowserPresentation()
        target.requestDirectory { [weak self, weak target] directoryResult in
            guard let self, let target, self.client === target,
                  directoryGeneration == self.fileDirectoryLoadGeneration,
                  sourceKey == self.currentFilesSourceKey() else { return }
            self.fileDirectoryLoading = false
            self.filePendingDirectoryPath = nil
            switch directoryResult {
            case let .success(listing):
                self.resetInlineFileExpansion()
                self.fileDirectoryError = nil
                self.lastDirectory = listing
                self.commitFileNavigation(listing.currentPath, mode: .initialize)
                self.renderSession()
                if self.currentWorkspace == .files { self.alignInitialFilesWorkspaceToTopIfNeeded() }
            case let .failure(error):
                self.fileNeedsInitialWorkspaceTopAlignment = false
                self.fileDirectoryError = LF("Could not load the file root: %@", Self.displayMessage(for: error))
                self.fileTransferLabel.stringValue = self.fileDirectoryError ?? L("File root load failed")
                self.fileTransferLabel.toolTip = self.fileTransferLabel.stringValue
                self.reloadCatalogViews()
                self.appendLine("\n" + LF("Root file list could not be loaded: %@", Self.displayMessage(for: error)))
            }

            target.requestChannels { [weak self, weak target] channelResult in
                guard let self, let target, self.client === target,
                      sourceKey == self.currentFilesSourceKey() else { return }
                let continueAfterLobby: () -> Void = { [weak self] in
                    guard let self else { return }
                    self.loadInitialNewsgroups(completion: completion)
                }
                switch channelResult {
                case let .success(channels):
                    self.lastChannels = channels
                    self.renderSession()
                    self.autoJoinLobbyIfAvailable(channels: channels, completion: continueAfterLobby)
                case let .failure(error):
                    self.appendLine("\n" + LF("Channel list could not be loaded: %@", Self.displayMessage(for: error)))
                    continueAfterLobby()
                }
            }
        }
    }

    func autoJoinLobbyIfAvailable(channels: [LegacyChannelSummary], completion: @escaping () -> Void) {
        guard client.isConnected, remotePermissionEnabled(LegacyAccountPermissionBit.joinChatRooms) else {
            completion()
            return
        }
        if let active = activeChannel {
            activateJoinedChannel(active.channelID)
            completion()
            return
        }
        let lobby = channels.first(where: { $0.channelID == LegacyServerRuntime.publicChannelID })
            ?? channels.first(where: {
                let name = Self.macRomanString($0.name).lowercased()
                return name == "public" || name == "lobby"
            })
        guard let lobby else {
            appendLine("\n" + L("No public Lobby chat is available on this server."))
            completion()
            return
        }

        client.joinChannel(channelID: lobby.channelID, name: lobby.name) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(state):
                self.installJoinedChannel(state)
                self.refreshChannelCatalog()
            case let .failure(error):
                self.appendLine("\n" + LF("Lobby chat could not be joined automatically: %@", Self.displayMessage(for: error)))
            }
            completion()
        }
    }

    func runChatSmokeIfRequested() {
        guard !didRunChatSmoke,
              let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--chat-smoke-dump=") }),
              client.isConnected,
              let publicRoom = lastChannels.first(where: { $0.channelID == 1 }) ?? lastChannels.first else { return }
        let path = String(argument.dropFirst("--chat-smoke-dump=".count))
        guard !path.isEmpty else { return }
        didRunChatSmoke = true
        chatSmokeDumpPath = path
        selectWorkspace(.conferences)

        if let existing = joinedChannels[publicRoom.channelID] {
            continueChatSmoke(publicState: existing.state)
            return
        }
        client.joinChannel(channelID: publicRoom.channelID, name: publicRoom.name) { [weak self] result in
            guard let self else { return }
            guard case let .success(publicState) = result else {
                self.writeChatSmokeFailure("public join failed: \(result)")
                return
            }
            self.installJoinedChannel(publicState)
            self.continueChatSmoke(publicState: publicState)
        }
    }

    func continueChatSmoke(publicState: LegacyChannelState) {
        client.sendChannelMessage(channelID: publicState.channelID, message: Data("GUI public smoke".utf8)) { [weak self] sendResult in
            guard let self else { return }
            if case let .failure(error) = sendResult {
                self.writeChatSmokeFailure("public send failed: \(Self.displayMessage(for: error))")
                return
            }
            let roomName = Data("GUI Smoke Room".utf8)
            self.client.joinChannel(channelID: 0, name: roomName) { [weak self] createResult in
                guard let self else { return }
                guard case let .success(privateState) = createResult else {
                    self.writeChatSmokeFailure("room create failed: \(createResult)")
                    return
                }
                self.installJoinedChannel(privateState)
                self.refreshChannelCatalog()
                self.client.sendChannelMessage(channelID: privateState.channelID, message: Data("GUI smoke".utf8)) { [weak self] privateSend in
                    guard let self else { return }
                    if case let .failure(error) = privateSend {
                        self.writeChatSmokeFailure("send failed: \(Self.displayMessage(for: error))")
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.writeChatSmokeSnapshotIfReady()
                    }
                }
            }
        }
    }

    func writeChatSmokeFailure(_ message: String) {
        guard let path = chatSmokeDumpPath else { return }
        let object: [String: Any] = ["ok": false, "error": message]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        chatSmokeDumpPath = nil
    }

    func writeChatSmokeSnapshotIfReady() {
        guard let path = chatSmokeDumpPath else { return }
        let sessions = joinedChannels.values
        guard sessions.count >= 2 else { return }
        let publicMessageSeen = sessions.contains { session in
            session.transcript.contains { entry in
                guard case let .message(_, message, _) = entry.kind else { return false }
                return Self.macRomanString(message) == "GUI public smoke"
            }
        }
        let privateMessageSeen = sessions.contains { session in
            session.transcript.contains { entry in
                guard case let .message(_, message, _) = entry.kind else { return false }
                return Self.macRomanString(message) == "GUI smoke"
            }
        }
        let remotePublicMessageSeen = sessions.contains { session in
            session.state.channelID == 1 && session.transcript.contains { entry in
                guard case let .message(senderUserID, message, _) = entry.kind else { return false }
                return senderUserID != lastLoginResult?.session.userID && Self.macRomanString(message) == "GUI remote public"
            }
        }
        let backgroundUnread = joinedChannels[1]?.unreadCount ?? 0
        guard publicMessageSeen, privateMessageSeen, remotePublicMessageSeen, backgroundUnread > 0 else { return }
        activateJoinedChannel(1)
        let unreadAfterOpen = joinedChannels[1]?.unreadCount ?? -1
        let switchedToPublic = activeChannel?.channelID == 1
        guard unreadAfterOpen == 0, switchedToPublic else { return }

        let rooms = joinedChannels.values.sorted { $0.state.channelID < $1.state.channelID }.map { session -> [String: Any] in
            let messages = session.transcript.compactMap { entry -> String? in
                guard case let .message(_, message, _) = entry.kind else { return nil }
                return Self.macRomanString(message)
            }
            return [
                "id": session.state.channelID,
                "name": Self.macRomanString(session.state.name),
                "memberCount": session.members.count,
                "messageCount": messages.count,
                "messages": messages,
                "unread": session.unreadCount,
            ]
        }
        let object: [String: Any] = [
            "ok": true,
            "joinedCount": joinedChannels.count,
            "activeRoom": activeChannel.map { Self.macRomanString($0.name) } ?? "",
            "activeTopic": activeChannel.map { Self.macRomanString($0.topic) } ?? "",
            "activeTopicLabel": chatTopicLabel.stringValue,
            "activeMemberCount": channelMembers.count,
            "canSend": canSendToActiveChannel,
            "isOperator": isActiveChannelOperator,
            "publicMessageSeen": publicMessageSeen,
            "privateMessageSeen": privateMessageSeen,
            "remotePublicMessageSeen": remotePublicMessageSeen,
            "backgroundUnread": backgroundUnread,
            "unreadAfterOpen": unreadAfterOpen,
            "switchedToPublic": switchedToPublic,
            "rooms": rooms,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        chatSmokeDumpPath = nil
    }

    func runUserInfoSmokeIfRequested() {
        guard !didRunUserInfoSmoke,
              let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--user-info-smoke-dump=") }),
              let ownID = lastLoginResult?.session.userID,
              let user = liveUsers[ownID] else { return }
        let path = String(argument.dropFirst("--user-info-smoke-dump=".count))
        guard !path.isEmpty else { return }
        didRunUserInfoSmoke = true
        if let row = visibleUsers.firstIndex(where: { $0.userID == ownID }) {
            userTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        client.requestUserInfo(userID: ownID) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                let object: [String: Any] = ["presented": false, "error": Self.displayMessage(for: error)]
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            case let .success(info):
                let tasks = info.taskList.flatMap { try? LegacyPackedRecords.decodeCompactTaskList($0) } ?? []
                let object: [String: Any] = [
                    "presented": true,
                    "userID": info.userID,
                    "nickname": Self.macRomanString(info.nickname),
                    "name": Self.macRomanString(info.name),
                    "email": Self.macRomanString(info.email),
                    "about": Self.macRomanString(info.aboutMe),
                    "login": info.loginName.map { Self.macRomanString($0) } ?? "",
                    "ip": info.ipAddress.map { Self.ipv4String($0) } ?? "",
                    "hasLoginTime": info.loginTime != nil,
                    "hasIdleTime": info.idleTime != nil,
                    "hasTaskList": info.taskList != nil,
                    "operatingSystem": info.operatingSystem ?? "",
                    "cpuArchitecture": info.cpuArchitecture ?? "",
                    "clientVersion": info.clientVersion ?? "",
                    "clientBuild": info.clientBuild ?? "",
                    "taskCount": tasks.count,
                    "sections": ["Profile", "About me", "Connection", "Tasks"],
                ]
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
                self.presentUserInfo(info, listEntry: user)
            }
        }
    }

    func writeUISmokeSnapshotIfRequested() {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-smoke-dump=") }) else { return }
        let path = String(argument.dropFirst("--ui-smoke-dump=".count))
        guard !path.isEmpty else { return }
        let directoryEntries = lastDirectory?.entries ?? []
        let object: [String: Any] = [
            "connected": client.isConnected,
            "server": lastServerInfo?.serverName ?? lastLoginResult?.serverName ?? "",
            "users": sortedUsers.map { Self.macRomanString($0.nickname) },
            "files": directoryEntries.map { Self.macRomanString($0.name) },
            "newsgroups": lastNewsgroups.map { Self.macRomanString($0) },
            "fileCount": directoryEntries.count,
            "userCount": liveUsers.count,
            "newsgroupCount": lastNewsgroups.count,
            "accounts": remoteAccountSummaries.map { Self.macRomanString($0.login) },
            "accountCount": remoteAccountSummaries.count,
            "canManageAccounts": canManageRemoteAccounts,
            "isAdministrator": isRemoteAdministrator,
            "adminNavigation": administrativeWorkspacePermissions.compactMap { workspace, _ in
                sidebarButtons[workspace]?.isHidden == false ? workspace.title : nil
            },
            "administrationVisible": administrationSidebarHeader?.isHidden == false,
            "canManageRemoteTransfers": canManageRemoteTransfers,
            "transferWorkspaceVisible": sidebarButtons[.transfers]?.isHidden == false,
            "bookmarks": serverBookmarks.map { bookmark in
                ["name": bookmark.name, "host": bookmark.host, "port": String(bookmark.port),
                 "status": bookmarkConnectionState(for: bookmark.id),
                 "autoReconnect": bookmark.autoReconnect ? "true" : "false",
                 "connectAtLaunch": bookmark.connectAtLaunch ? "true" : "false"]
            },
            "serversMenuItems": NSApp.mainMenu?.item(withTitle: L("Servers"))?.submenu?.items.map(\.title) ?? [],
            "workspace": currentWorkspace.title,
            "joinedChannels": joinedChannels.values.sorted { $0.state.channelID < $1.state.channelID }.map { Self.macRomanString($0.state.name) },
            "activeChannel": activeChannel.map { Self.macRomanString($0.name) } ?? "",
            "agreementAwaiting": isAwaitingAgreementAcceptance,
            "filesFontSize": filesFontSize,
            "newsFontSize": newsFontSize,
            "serverLogFontSize": serverLogFontSize,
            "dark": CarrachoTheme.isDark(view.effectiveAppearance),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            appendLine("\n" + LF("UI smoke snapshot failed: %@", Self.displayMessage(for: error)))
        }
    }

    var configuredDownloadFolderURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.downloadFolderDefaultsKey), !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    var generalIdentityConfigured: Bool {
        UserDefaults.standard.bool(forKey: Self.generalIdentityConfiguredDefaultsKey)
    }

    var generalNickname: String? {
        guard generalIdentityConfigured else { return nil }
        let value = UserDefaults.standard.string(forKey: Self.generalNicknameDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, !Self.isReservedAnonymousNickname(value) else { return nil }
        return value
    }

    var generalStatusMessage: String? {
        guard generalIdentityConfigured else { return nil }
        return UserDefaults.standard.string(forKey: Self.generalStatusDefaultsKey) ?? ""
    }

    var generalEmail: String {
        UserDefaults.standard.string(forKey: Self.generalEmailDefaultsKey) ?? ""
    }

    var generalAboutMe: String {
        UserDefaults.standard.string(forKey: Self.generalAboutMeDefaultsKey) ?? ""
    }

    var queuedClientTransferIDs: [UUID] {
        transferMonitorOrder.reversed().filter { id in
            guard let item = transferMonitorItems[id] else { return false }
            return item.queued && clientTransferOperations[id] != nil
        }
    }

    var orderedTransferMonitorItems: [ClientTransferMonitorItem] {
        transferMonitorOrder.compactMap { transferMonitorItems[$0] }
    }

    /// A restored transfer still carries the user ID from the previous control session.
    /// The server assigns a fresh session user ID after reconnect, so matching only the persisted
    /// ID makes one resumed transfer appear twice: once as the live server task and once as the
    /// local resumable row. Every ClientTransferMonitorItem is one of our own transfers, so the
    /// current login's user ID is also a valid owner match after reconnect.
    /// While a local transfer is active, administrators see the server-managed row instead of
    /// the duplicate local row. If that server row disappears after Abort, hand selection back
    /// to the same local/resumable transfer instead of leaving NSTableView visually selected but
    /// the controller with no selected transfer ID.
    var transferScopeRows: [TransferMonitorRow] {
        switch transferMonitorScope {
        case .mine:
            return orderedTransferMonitorItems.map(TransferMonitorRow.local)
        case .serverWide:
            if !remoteManagedTransferSnapshot.isEmpty {
                return remoteManagedTransferSnapshot.reversed().map(TransferMonitorRow.managed)
            }
            return remoteTransferSnapshot.reversed().map(TransferMonitorRow.legacyServer)
        }
    }

    var currentTransferServerName: String {
        if let serverName = lastServerInfo?.serverName {
            let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if let name = lastLoginResult?.serverName.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let bookmarkID = activeBookmarkConnectionID ?? connectedBookmarkID,
           let bookmark = serverBookmarks.first(where: { $0.id == bookmarkID }) {
            let name = bookmark.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "\(bookmark.host):\(bookmark.port)" : name
        }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "Carracho Server" : host
    }

    var transferRowsMatchingSearch: [TransferMonitorRow] {
        transferScopeRows.filter(transferRowMatchesSearch)
    }

    var transferMonitorRows: [TransferMonitorRow] {
        let rows = transferRowsMatchingSearch.filter(transferRowMatchesFilter)
        return sortedForTable(rows, table: transferTable) { lhs, rhs, key in
            switch key {
            case "name": return Self.compareText(self.transferRowName(lhs), self.transferRowName(rhs))
            case "progress": return Self.compareNumber(self.transferRowProgress(lhs), self.transferRowProgress(rhs))
            case "status": return Self.compareText(self.transferRowStatus(lhs), self.transferRowStatus(rhs))
            default: return .orderedSame
            }
        }
    }

    var selectedTransferItem: ClientTransferMonitorItem? {
        selectedTransferID.flatMap { transferMonitorItems[$0] }
    }

    var selectedManagedTransfer: LegacyManagedTransferRecord? {
        guard let selectedRemoteTransferID else { return nil }
        return remoteManagedTransferSnapshot.first { $0.transferID == selectedRemoteTransferID }
    }

    var transferPersistenceBookmarkID: UUID? {
        activeBookmarkConnectionID ?? connectedBookmarkID ?? connectingBookmarkID ?? selectedBookmarkID
    }

    var selectedDownloadEntry: LegacyDirectoryEntry? {
        let row = fileTable.selectedRow
        guard row >= 0, row < visibleFileRows.count else { return nil }
        return visibleFileRows[row].entry
    }

    var selectedFileSearchResult: LegacyFileSearchResult? {
        guard let results = sortedFileSearchResults else { return nil }
        let row = fileTable.selectedRow
        guard row >= 0, row < results.count else { return nil }
        return results[row]
    }

    var selectedServerItemPath: Data? {
        let row = fileTable.selectedRow
        guard row >= 0, row < visibleFileRows.count else { return nil }
        return visibleFileRows[row].path
    }

    /// New servers report directory roots directly in the managed-transfer flags. Older servers
    /// do not, so resolve active download roots once through File Info instead of guessing from
    /// the filename. This keeps the admin monitor correct across mixed client/server versions.
    @MainActor func uploadInlineNewsReplyImages(urls: [URL]) {
        guard let mediaClient, currentNewsThreadID != nil else { return }
        let remaining = max(0, LegacyMediaTransfer.maximumImagesPerNewsPost - newsReplyAttachments.imageCount)
        let selected = Array(urls.prefix(remaining))
        guard !selected.isEmpty else { return }
        do {
            let prepared = try selected.map { try CarrachoMediaImageProcessor.prepare(url: $0) }
            let expectedClient = mediaClient
            let expectedContext = newsReplyContextKey
            newsReplyMediaBusy = true
            updateInlineNewsReplyState()
            uploadPreparedMedia(prepared, client: expectedClient) { [weak self] result in
                guard let self else { return }
                self.newsReplyMediaBusy = false
                guard self.mediaClient === expectedClient, self.newsReplyContextKey == expectedContext else {
                    self.updateInlineNewsReplyState()
                    return
                }
                switch result {
                case let .success(ids):
                    self.addUploadedImages(ids: ids, prepared: prepared, to: self.newsReplyAttachments)
                    self.saveInlineNewsReplyDraft()
                case let .failure(error):
                    self.newsReplyValidationLabel.stringValue = LF("Image upload failed: %@", Self.displayMessage(for: error))
                    self.newsReplyValidationLabel.isHidden = false
                }
                self.updateInlineNewsReplyState()
            }
        } catch {
            newsReplyValidationLabel.stringValue = LF("Image could not be prepared: %@", Self.displayMessage(for: error))
            newsReplyValidationLabel.isHidden = false
        }
    }

    @MainActor func uploadInlineNewsReplyImage(data: Data) {
        guard currentNewsThreadID != nil else { return }
        attachImageData(data, to: newsReplyTextView, strip: newsReplyAttachments,
                        maximum: LegacyMediaTransfer.maximumImagesPerNewsPost) { [weak self] busy in
            guard let self else { return }
            self.newsReplyMediaBusy = busy
            self.updateInlineNewsReplyState()
            if !busy { self.saveInlineNewsReplyDraft() }
        }
    }

    var selectedRemoteNewsgroup: Data? {
        let row = newsTable.selectedRow
        if row >= 0, row < displayedNewsgroups.count { return displayedNewsgroups[row] }
        if let currentNewsCategory, lastNewsgroups.contains(currentNewsCategory) { return currentNewsCategory }
        return displayedNewsgroups.count == 1 ? displayedNewsgroups[0] : nil
    }

    var selectedNewsThreadForPosting: LegacyNewsThreadSummary? {
        let row = newsArticleTable.selectedRow
        if row >= 0, row < displayedNewsThreads.count { return displayedNewsThreads[row] }
        if let threadID = currentNewsThreadID { return currentNewsThreads.first(where: { $0.threadID == threadID }) }
        return nil
    }

    var selectedChannelMember: LegacyChannelMember? {
        let row = channelMemberTable.selectedRow
        guard row >= 0, row < sortedChannelMembers.count else { return nil }
        return sortedChannelMembers[row]
    }

    var selectedChannelMemberUser: LegacyUserListEntry? {
        guard let member = selectedChannelMember else { return nil }
        return liveUsers[member.userID]
    }

    var ownActiveChannelMode: UInt8 {
        guard let ownID = lastLoginResult?.session.userID else { return 0 }
        return channelMembers[ownID] ?? 0
    }

    var isActiveChannelOperator: Bool {
        ownActiveChannelMode & Self.channelOperatorMode != 0
    }

    var canSendToActiveChannel: Bool {
        guard let active = activeChannel else { return false }
        if active.flags & Self.channelRestrictedChatFlag == 0 { return true }
        return ownActiveChannelMode & (Self.channelOperatorMode | Self.channelSpeechMode) != 0
    }

    var canEditActiveChannelTopic: Bool {
        guard let active = activeChannel else { return false }
        return active.flags & Self.channelRestrictedTopicFlag == 0 || isActiveChannelOperator
    }

    var canJoinChatRooms: Bool {
        client.isConnected && remotePermissionEnabled(LegacyAccountPermissionBit.joinChatRooms)
    }

    /// Classic servers may emit only the global user-disconnected event when a socket dies,
    /// without following it with channel-user-left events for every joined conference. Prune the
    /// user from every local room snapshot here so the Conferences participant list cannot retain
    /// a ghost row after the user has already vanished from the global user list.
    @MainActor func uploadChannelImages(urls: [URL]) {
        guard let mediaClient, let activeChannel else { return }
        let remaining = max(0, LegacyMediaTransfer.maximumImagesPerChatMessage - channelAttachmentStrip.imageCount)
        let selected = Array(urls.prefix(remaining))
        guard !selected.isEmpty else { return }
        do {
            let prepared = try selected.map { try CarrachoMediaImageProcessor.prepare(url: $0) }
            let expectedClient = mediaClient
            let expectedChannelID = activeChannel.channelID
            channelAttachButton.isEnabled = false
            uploadPreparedMedia(prepared, client: expectedClient) { [weak self] result in
                guard let self else { return }
                defer { self.reloadChannelView() }
                guard self.mediaClient === expectedClient,
                      self.activeChannel?.channelID == expectedChannelID else { return }
                switch result {
                case let .success(ids): self.addUploadedImages(ids: ids, prepared: prepared, to: self.channelAttachmentStrip)
                case let .failure(error): self.showError(LF("Image upload failed: %@", Self.displayMessage(for: error)))
                }
            }
        } catch {
            showError(LF("Image could not be prepared: %@", Self.displayMessage(for: error)))
        }
    }

    @MainActor func uploadChannelImage(data: Data) {
        guard let mediaClient, let activeChannel else { return }
        guard channelAttachmentStrip.imageCount < LegacyMediaTransfer.maximumImagesPerChatMessage else {
            showError(LF("A chat message can contain at most %@ images.", String(LegacyMediaTransfer.maximumImagesPerChatMessage)))
            return
        }
        do {
            let prepared = try CarrachoMediaImageProcessor.prepare(data: data)
            let expectedClient = mediaClient
            let expectedChannelID = activeChannel.channelID
            channelAttachButton.isEnabled = false
            uploadPreparedMedia([prepared], client: expectedClient) { [weak self] result in
                guard let self else { return }
                defer { self.reloadChannelView() }
                guard self.mediaClient === expectedClient,
                      self.activeChannel?.channelID == expectedChannelID else { return }
                switch result {
                case let .success(ids): self.addUploadedImages(ids: ids, prepared: [prepared], to: self.channelAttachmentStrip)
                case let .failure(error): self.showError(LF("Image upload failed: %@", Self.displayMessage(for: error)))
                }
            }
        } catch {
            showError(LF("Clipboard image could not be prepared: %@", Self.displayMessage(for: error)))
        }
    }

    @MainActor func attachImages(to textView: CarrachoMediaComposerTextView,
                              strip: CarrachoComposerAttachmentStrip, maximum: Int,
                              attachButton: NSButton? = nil, busyChanged: ((Bool) -> Void)? = nil) {
        guard let mediaClient else { return }
        let remaining = max(0, maximum - strip.imageCount)
        guard remaining > 0 else {
            showError(LF("This post can contain at most %@ images.", String(maximum)))
            return
        }
        chooseMediaImages(maximum: remaining) { [weak self, weak textView, weak attachButton] urls in
            guard let self, let textView else { return }
            do {
                let prepared = try urls.map { try CarrachoMediaImageProcessor.prepare(url: $0) }
                attachButton?.isEnabled = false
                busyChanged?(true)
                self.uploadPreparedMedia(prepared, client: mediaClient) { [weak self, weak textView, weak attachButton] result in
                    attachButton?.isEnabled = true
                    busyChanged?(false)
                    guard let self, textView != nil else { return }
                    switch result {
                    case let .success(ids): self.addUploadedImages(ids: ids, prepared: prepared, to: strip)
                    case let .failure(error): self.showError(LF("Image upload failed: %@", Self.displayMessage(for: error)))
                    }
                }
            } catch {
                busyChanged?(false)
                self.showError(LF("Image could not be prepared: %@", Self.displayMessage(for: error)))
            }
        }
    }

    @MainActor func attachImageData(_ data: Data, to textView: CarrachoMediaComposerTextView,
                                 strip: CarrachoComposerAttachmentStrip, maximum: Int,
                                 busyChanged: ((Bool) -> Void)? = nil) {
        guard let mediaClient else { return }
        guard strip.imageCount < maximum else {
            showError(LF("This post can contain at most %@ images.", String(maximum)))
            return
        }
        do {
            let prepared = try CarrachoMediaImageProcessor.prepare(data: data)
            busyChanged?(true)
            uploadPreparedMedia([prepared], client: mediaClient) { [weak self, weak textView] result in
                busyChanged?(false)
                guard let self, textView != nil else { return }
                switch result {
                case let .success(ids): self.addUploadedImages(ids: ids, prepared: [prepared], to: strip)
                case let .failure(error): self.showError(LF("Image upload failed: %@", Self.displayMessage(for: error)))
                }
            }
        } catch {
            busyChanged?(false)
            showError(LF("Clipboard image could not be prepared: %@", Self.displayMessage(for: error)))
        }
    }

    func setInputsEnabled(_ enabled: Bool) {
        hostField.isEnabled = enabled
        portField.isEnabled = enabled
        loginField.isEnabled = enabled
        passwordField.isEnabled = enabled
        nicknameField.isEnabled = enabled
    }

    func renderWelcome() {
        detailsTextView.string = L("Ready.\n\nConnect to a Carracho server to load files, users, chat rooms and newsgroups.")
        reloadCatalogViews()
        refreshShellChrome()
    }

    func renderSession() {
        guard let login = lastLoginResult else {
            reloadCatalogViews()
            return
        }
        var lines: [String] = []
        lines.append(LF("Server: %@", login.serverName))
        lines.append(String(format: L("Permissions: %08x %08x"), login.session.permissionWord0, login.session.permissionWord1))
        if let transferVersion = login.transferProtocolVersion { lines.append(LF("Transfer protocol: %@", String(transferVersion))) }
        if let maxTransfers = login.maxFileTransfersPerUser { lines.append(LF("Max. file transfers/user: %@", String(maxTransfers))) }
        if let agreement = login.agreement {
            lines.append(LF("Server Agreement: %@ text bytes, %@ style bytes", String(agreement.text.count), String(agreement.styleData.count)))
        } else {
            lines.append(L("Server Agreement: not sent"))
        }

        if let info = lastServerInfo {
            lines.append("")
            lines.append(L("Server Information"))
            if let value = info.serverName { lines.append(LF("  Name: %@", value)) }
            if let value = info.location { lines.append(LF("  Location: %@", value)) }
            if let value = info.systemOperator { lines.append(LF("  Operator: %@", value)) }
            if let value = info.description { lines.append(LF("  Description: %@", value)) }
        }
        if let banner = currentBanner {
            lines.append(LF("  Banner: %@ byte(s)%@", String(banner.imageData.count), banner.urlString.isEmpty ? "" : " — \(banner.urlString)"))
        }

        lines.append("")
        lines.append(LF("Users online: %@", String(liveUsers.count)))
        if let directory = lastDirectory {
            lines.append(LF("Files in %@: %@", filesDisplayPath(directory.currentPath), String(directory.entries.count)))
        }
        lines.append(LF("Channels: %@", String(lastChannels.count)))
        if let active = activeChannel {
            lines.append(LF("Active channel: %@ (%@ members)", Self.macRomanString(active.name), String(channelMembers.count)))
        }
        lines.append(LF("News categories: %@", String(lastNewsgroups.count)))
        detailsTextView.string = lines.joined(separator: "\n")
        reloadCatalogViews()
        refreshShellChrome()
    }

    func reloadCatalogViews() {
        if let results = fileSearchResults {
            filePathLabel.stringValue = LF("Server-wide search (%@)", String(results.count))
        } else if fileDirectoryLoading, let pending = filePendingDirectoryPath {
            filePathLabel.stringValue = filesDisplayPath(pending) + L("  (loading…)")
        } else if let directory = lastDirectory {
            filePathLabel.stringValue = filesDisplayPath(directory.currentPath)
        } else {
            filePathLabel.stringValue = lastLoginResult?.filesRootName ?? LegacyFilesRootCapability.defaultDisplayName
        }
        reloadFileTablePreservingState()
        updateFileTransferButtons()
        updateFileBrowserPresentation()
        reloadUserTablePreservingSelection()
        channelTable.reloadData()
        reloadChannelView()
        reloadNewsView()
    }

    var selectedUserEntry: LegacyUserListEntry? {
        if let selectedUserID, let user = liveUsers[selectedUserID],
           visibleUsers.contains(where: { $0.userID == selectedUserID }) {
            return user
        }
        let row = userTable.selectedRow
        guard row >= 0, row < visibleUsers.count else { return nil }
        return visibleUsers[row]
    }

    var displayedPrivateMessageConversations: [PrivateMessageConversation] {
        let query = privateMessageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = privateMessageConversations.values.filter { conversation in
            guard !query.isEmpty else { return true }
            if conversation.nickname.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            guard let last = conversation.entries.last else { return false }
            let preview = CarrachoHTMLText.plainText(fromWire: last.message)
            return preview.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return filtered.sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            return lhs.nickname.localizedCaseInsensitiveCompare(rhs.nickname) == .orderedAscending
        }
    }

    var displayedMessageCenterRows: [MessageCenterListRow] {
        let query = privateMessageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [MessageCenterListRow] = []
        if offlineMessageCategoryMatchesSearch(query) { rows.append(.offlineMessages) }
        rows.append(contentsOf: displayedPrivateMessageConversations.map(MessageCenterListRow.conversation))
        return rows
    }

    var privateMessageUnreadCount: Int {
        let conversations = privateMessageConversations.values.reduce(0) { min(999, $0 + $1.unreadCount) }
        return min(999, conversations + offlineMessageCenterUnreadCount)
    }

    func refreshRemoteBanner(logErrors: Bool) {
        guard let bannerClient else { return }
        bannerClient.download { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(banner):
                self.currentBanner = banner
                self.rightBannerImageView.image = banner.imageData.isEmpty ? nil : NSImage(data: banner.imageData)
                if self.client.isConnected, self.currentWorkspace == .serverInfo { self.applyRemoteBannerToAdmin(banner) }
                self.renderSession()
            case let .failure(error):
                if logErrors { self.appendLine("\n" + LF("Banner could not be updated: %@", Self.displayMessage(for: error))) }
            }
        }
    }

    func handle(_ event: LegacyControlEvent) {
        if isAwaitingAgreementAcceptance {
            switch event {
            case .offlineMessagesAvailable, .privateMessage, .channelInvitation, .broadcastMessage:
                if deferredInteractiveEvents.count < 100 { deferredInteractiveEvents.append(event) }
                return
            default:
                break
            }
        }
        switch event {
        case let .userArrived(user):
            liveUsers[user.userID] = user
            let arrivedName = Self.macRomanString(user.nickname)
            emitClientEvent(.userSignedIn,
                            notificationTitle: L("User signed in"),
                            notificationBody: LF("%@ is now online.", arrivedName))
            setSleepingState((user.flags & 0x0100) != 0, for: user.userID)
            if userStatusMessages[user.userID] == nil { userStatusMessages[user.userID] = Data() }
            refreshUserStatus(userID: user.userID)
            updatePrivateConversationMetadata(user.userID)
            renderSession()
            refreshPrivateMessageCenter(scrollToBottom: false)
            updateUserActionButtons()
        case let .userDisconnected(userID):
            let departedName = liveUsers[userID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
            emitClientEvent(.userSignedOut,
                            notificationTitle: L("User signed out"),
                            notificationBody: LF("%@ went offline.", departedName))
            removeDisconnectedUserFromChannels(userID)
            liveUsers.removeValue(forKey: userID)
            sleepingUsers.remove(userID)
            userStatusMessages.removeValue(forKey: userID)
            userGroupColors.removeValue(forKey: userID)
            renderSession()
            refreshPrivateMessageCenter(scrollToBottom: false)
            updateUserActionButtons()
        case let .presence(userID, sleeping):
            setSleepingState(sleeping, for: userID)
            renderSession()
            updateUserActionButtons()
        case let .offlineMessagesAvailable(count):
            presentOfflineMessageNotice(count: count)
        case let .privateMessage(message):
            let sender = liveUsers[message.senderUserID].map { Self.macRomanString($0.nickname) }
                ?? L("Unknown User")
            let privateText = CarrachoHTMLText.plainText(fromWire: message.message, expandLegacyEmoticons: true)
            emitClientEvent(.message,
                            notificationTitle: LF("New message from %@", sender),
                            notificationBody: clientNotificationSnippet(privateText, fallback: L("New private message")))
            appendLine("\n[" + L("Private") + "] <\(sender)> \(privateText)")
            appendPrivateMessage(userID: message.senderUserID, message: message.message, outgoing: false)
        case let .userUpdated(userID, nickname, picture, statusMessage):
            if var user = liveUsers[userID] {
                user.nickname = nickname
                user.picture = picture
                liveUsers[userID] = user
            }
            if let statusMessage { userStatusMessages[userID] = statusMessage }
            updatePrivateConversationMetadata(userID)
            renderSession()
            refreshPrivateMessageCenter(scrollToBottom: false)
        case let .userStatus(userID, statusMessage):
            userStatusMessages[userID] = statusMessage
            reloadUserTablePreservingSelection()
            if channelMembers[userID] != nil { channelMemberTable.reloadData() }
        case let .userGroupColor(userID, colorRGB):
            if let colorRGB { userGroupColors[userID] = colorRGB }
            else { userGroupColors.removeValue(forKey: userID) }
            reloadUserTablePreservingSelection()
            if channelMembers[userID] != nil { channelMemberTable.reloadData() }
        case let .ownPermissionsChanged(permissionWord0, permissionWord1):
            guard var login = lastLoginResult else { break }
            let changed = login.session.permissionWord0 != permissionWord0 ||
                login.session.permissionWord1 != permissionWord1
            login.session.permissionWord0 = permissionWord0
            login.session.permissionWord1 = permissionWord1
            lastLoginResult = login
            guard changed else { break }

            // Permission changes can alter both what a directory contains (notably Dropboxes)
            // and which file actions are legal. Inline-expanded folders are cached deliberately,
            // so keeping them across an access-policy change would preserve the old hidden/visible
            // contents until an unrelated navigation happened to flush the tree.
            resetInlineFileExpansion()
            refreshAdministrativeNavigationVisibility()
            renderSession()
            refreshCurrentServerDirectory()
        case let .channelUserJoined(channelID, userID, mode):
            if var session = joinedChannels[channelID] {
                session.members[userID] = mode
                session.state.members = session.members.map { LegacyChannelMember(userID: $0.key, mode: $0.value) }
                joinedChannels[channelID] = session
                if activeChannel?.channelID == channelID { channelMembers = session.members }
                let name = liveUsers[userID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
                appendChannelSystem(LF("%@ joined the room.", name), channelID: channelID)
                syncChannelMemberCount(channelID)
            }
        case let .channelUserLeft(channelID, userID):
            if var session = joinedChannels[channelID],
               session.members.removeValue(forKey: userID) != nil {
                session.state.members = session.members.map { LegacyChannelMember(userID: $0.key, mode: $0.value) }
                joinedChannels[channelID] = session
                if activeChannel?.channelID == channelID {
                    activeChannel = session.state
                    channelMembers = session.members
                }
                let name = liveUsers[userID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
                appendChannelSystem(LF("%@ left the room.", name), channelID: channelID)
                syncChannelMemberCount(channelID)
            }
        case let .channelUserMode(channelID, userID, mode):
            if var session = joinedChannels[channelID] {
                session.members[userID] = mode
                session.state.members = session.members.map { LegacyChannelMember(userID: $0.key, mode: $0.value) }
                joinedChannels[channelID] = session
                if activeChannel?.channelID == channelID { channelMembers = session.members }
                let name = liveUsers[userID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
                let role: String
                if mode & Self.channelOperatorMode != 0 { role = L("Operator") }
                else if mode & Self.channelSpeechMode != 0 { role = L("Speaker") }
                else { role = L("Member") }
                appendChannelSystem(LF("%@ is now %@.", name, role), channelID: channelID)
            }
        case let .channelInvitation(invitation):
            let inviter = liveUsers[invitation.inviterUserID].map { Self.macRomanString($0.nickname) }
                ?? L("Unknown User")
            let roomName = Self.macRomanString(invitation.name)
            emitClientEvent(.invitation,
                            notificationTitle: LF("Invitation to #%@", roomName),
                            notificationBody: LF("%@ invited you.", inviter))
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = L("Chat Room Invitation")
            alert.informativeText = LF("%@ invited you to #%@.", inviter, roomName)
            let alreadyJoined = joinedChannels[invitation.channelID] != nil
            alert.addButton(withTitle: alreadyJoined ? L("Open") : L("Join"))
            alert.addButton(withTitle: L("Decline"))
            let canAccept = alreadyJoined || (canJoinChatRooms && joinedChannels.count < Self.maximumJoinedChannels)
            alert.buttons.first?.isEnabled = canAccept
            if !canAccept {
                alert.informativeText += " " + (canJoinChatRooms
                    ? L("You are already in the maximum number of rooms.")
                    : L("This account is not allowed to join chat rooms."))
            }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                if response == .alertFirstButtonReturn {
                    if self.joinedChannels[invitation.channelID] != nil {
                        self.activateJoinedChannel(invitation.channelID)
                        self.selectWorkspace(.conferences)
                        return
                    }
                    guard self.joinedChannels.count < Self.maximumJoinedChannels else {
                        self.showError(LF("You are already in the maximum of %@ chat rooms. Leave one before accepting this invitation.", String(Self.maximumJoinedChannels)))
                        return
                    }
                    self.client.joinChannel(channelID: invitation.channelID, name: invitation.name) { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case let .success(state):
                            self.installJoinedChannel(state)
                            self.refreshChannelCatalog()
                            self.selectWorkspace(.conferences)
                        case let .failure(error):
                            self.showError(LF("Invitation could not be accepted: %@", Self.displayMessage(for: error)))
                        }
                    }
                } else {
                    self.client.declineChannelInvitation(channelID: invitation.channelID, inviterUserID: invitation.inviterUserID) { [weak self] result in
                        if case let .failure(error) = result {
                            self?.showError(LF("Invitation could not be declined: %@", Self.displayMessage(for: error)))
                        }
                    }
                }
            }
        case let .channelInvitationDeclined(channelID, userID):
            let name = liveUsers[userID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
            appendChannelSystem(LF("%@ declined the invitation.", name), channelID: channelID)
        case let .channelMessage(message):
            if message.senderUserID != lastLoginResult?.session.userID {
                let sender = liveUsers[message.senderUserID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
                let room = joinedChannels[message.channelID].map { Self.macRomanString($0.state.name) } ?? L("Chat")
                let text = CarrachoHTMLText.plainText(fromWire: message.message, expandLegacyEmoticons: true)
                emitClientEvent(.chat,
                                notificationTitle: LF("New chat message in #%@", room),
                                notificationBody: LF("%@: %@", sender, clientNotificationSnippet(text)))
            }
            appendChannelMessage(message)
        case let .channelSettings(channelID, topic, flags):
            if var session = joinedChannels[channelID] {
                let oldTopic = session.state.topic
                let oldFlags = session.state.flags
                session.state.topic = topic
                session.state.flags = flags
                joinedChannels[channelID] = session
                if activeChannel?.channelID == channelID {
                    activeChannel?.topic = topic
                    activeChannel?.flags = flags
                }
                if oldTopic != topic {
                    let value = Self.macRomanString(topic)
                    appendChannelSystem(value.isEmpty ? L("Room topic was cleared.") : LF("Room topic changed to: %@", value), channelID: channelID)
                } else if oldFlags != flags {
                    appendChannelSystem(L("Room permissions were changed."), channelID: channelID)
                } else if activeChannel?.channelID == channelID {
                    reloadChannelView()
                }
            }
        case let .flatNewsPosted(article):
            let newsText = CarrachoHTMLText.plainText(fromWire: article)
            emitClientEvent(.newsPost,
                            notificationTitle: L("New News Post"),
                            notificationBody: clientNotificationSnippet(newsText, fallback: L("A new News post is available.")))
            appendLine("\n" + LF("Flat News: %@", newsText))
        case let .flatNewsDeleted(index):
            appendLine("\n" + LF("Flat News entry %@ was deleted.", String(index)))
        case .flatNewsCleared:
            appendLine("\n" + L("Flat News was cleared."))
        case let .newsReactionChanged(group, articleID):
            guard newsReactionsSupported,
                  currentNewsCategory == group,
                  currentNewsThreadPosts.contains(where: { $0.articleID == articleID }) else { break }
            client.requestNewsReactions(group: group, articleID: articleID) { [weak self] result in
                guard let self,
                      self.currentNewsCategory == group,
                      self.currentNewsThreadPosts.contains(where: { $0.articleID == articleID }) else { return }
                if case let .success(summary) = result {
                    self.currentNewsReactions[articleID] = summary
                    self.reloadNewsViewPreservingArticleScrollPosition()
                }
            }
        case .bannerChanged:
            refreshRemoteBanner(logErrors: true)
        case let .mediaDeleted(id):
            applyDeletedMedia(id)
        case let .fileLabelChanged(path, label):
            applyRemoteFileLabelChange(path: path, label: label)
        case let .broadcastMessage(broadcast):
            let sender = liveUsers[broadcast.senderUserID].map { Self.macRomanString($0.nickname) } ?? L("Unknown User")
            let message = CarrachoHTMLText.plainText(fromWire: broadcast.message, expandLegacyEmoticons: true)
            appendLine("\n" + LF("Broadcast from %@: %@", sender, message))
            presentRichMessage(title: L("Server Broadcast"), senderLine: LF("From %@", sender), message: broadcast.message)
        case .forcedDisconnect:
            cancelAutoReconnect()
            appendLine("\n" + L("Server requested disconnection."))
        case let .unhandled(packet):
            if packet.command == LegacyCommand.accountUpdate {
                if currentWorkspace == .accounts { reloadRemoteAccounts() }
                refreshUserStatuses()
            } else if packet.command == LegacyCommand.newsgroupUpdate {
                if currentWorkspace == .newsgroups { reloadNewsgroupAdministration() }
                loadInitialNewsgroups(completion: nil)
            } else {
                appendLine(String(format: "\nAsync command 0x%08x (%d TLV)", packet.command, packet.fields.count))
            }
        }
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                         writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        // operationQueue(for:) pins this delegate callback to the main operation queue. Tell Swift's
        // actor checker the same thing explicitly so AppKit objects never cross into a Sendable closure.
        MainActor.assumeIsolated {
            self.fulfillRemoteFilePromise(filePromiseProvider, destinationURL: url, completionHandler: completionHandler)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === fileTable { return visibleFileRows.count }
        if tableView === transferTable { return transferMonitorRows.count }
        if tableView === trackerBrowserTable { return displayedTrackerServers.count }
        if tableView === privateMessageConversationTable { return displayedMessageCenterRows.count }
        if tableView === userTable { return visibleUsers.count }
        if tableView === channelTable { return displayedChannels.count }
        if tableView === channelMemberTable { return sortedChannelMembers.count }
        if tableView === newsTable { return displayedNewsgroups.count }
        if tableView === newsArticleTable { return displayedNewsThreads.count }
        if tableView === adminAccountTable { return usesRemoteAccountAdministration ? displayedRemoteAccounts.count : displayedLocalAccounts.count }
        if tableView === adminNewsgroupTable { return displayedAdminNewsgroups.count }
        if tableView === adminTrackerTable { return displayedTrackers.count }
        if tableView === adminBotCommandTable { return remoteBotCommandRuleDraft.count }
        if tableView === adminBotRSSTable { return remoteBotRSSFeedDraft.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue else { return nil }
        if tableView === adminBotCommandTable {
            return botCommandRuleCell(identifier: identifier, row: row)
        }
        if tableView === adminBotRSSTable {
            return botRSSFeedCell(identifier: identifier, row: row)
        }
        if tableView === privateMessageConversationTable, identifier == "conversation", row < displayedMessageCenterRows.count {
            let content: NSView
            switch displayedMessageCenterRows[row] {
            case .offlineMessages:
                content = offlineMessageCategoryCell()
            case let .conversation(conversation):
                content = privateMessageConversationCell(conversation)
            }
            return verticallyCenteredTableContent(content, fillWidth: true, leadingInset: 8, trailingInset: 8)
        }
        if tableView === channelMemberTable, identifier == "member", row < sortedChannelMembers.count {
            return verticallyCenteredTableContent(channelMemberCell(for: sortedChannelMembers[row]), fillWidth: true)
        }
        if tableView === transferTable, row < transferMonitorRows.count {
            let transferRow = transferMonitorRows[row]
            switch identifier {
            case "name": return transferNameCell(for: transferRow)
            case "progress": return transferProgressCell(for: transferRow)
            case "status": return transferStatusCell(for: transferRow)
            default: return nil
            }
        }
        if tableView === adminTrackerTable, identifier == "enabled", row < displayedTrackers.count {
            return trackerEnabledCell(for: displayedTrackers[row], row: row)
        }
        if tableView === adminTrackerTable, identifier == "actions", row < displayedTrackers.count {
            return verticallyCenteredTableContent(trackerActionsCell(row: row))
        }
        if tableView === adminTrackerTable, identifier == "name", row < displayedTrackers.count {
            let tracker = displayedTrackers[row]
            let label = tracker.name.isEmpty ? L("Unnamed Tracker") : tracker.name
            let image = symbolImage("globe", fallback: NSImage.networkName)
            let cell = tableCell(text: label, image: image, fontSize: 12.5)
            cell.toolTip = tracker.name.isEmpty ? tracker.address : tracker.name
            return cell
        }
        let value: String
        if tableView === fileTable, row < visibleFileRows.count {
            let item = visibleFileRows[row]
            let entry = item.entry
            switch identifier {
            case "kind": value = Self.fileKindTitle(entry)
            case "name":
                if let results = sortedFileSearchResults, row < results.count { value = LegacyPath.displayString(results[row].path) }
                else { value = Self.macRomanString(entry.name) }
            case "size":
                if entry.isFolder {
                    if fileSearchResults != nil {
                        value = "—"
                    } else {
                        value = entry.size == 1 ? L("1 item") : LF("%@ items", String(entry.size))
                    }
                } else {
                    value = Self.fileByteCountFormatter.string(fromByteCount: Int64(entry.size))
                }
            case "modified": value = entry.timestamp == 0 ? "—" : Self.macDateString(entry.timestamp)
            case "flags": value = String(format: "%04x", entry.flags)
            default: value = ""
            }
        } else if tableView === transferTable, row < transferMonitorRows.count {
            let transferRow = transferMonitorRows[row]
            switch transferRow {
            case let .local(item):
                if identifier == "user" {
                    return verticallyCenteredTableContent(transferUserCell(userID: item.userID, nickname: item.userNickname, picture: item.userPicture))
                }
                switch identifier {
                case "direction": value = item.kind == LegacyTransferKind.download ? L("Download") : L("Upload")
                case "name": value = item.name
                case "progress": value = item.queued ? L("Queued") : transferProgressText(completed: item.completedBytes, total: item.totalBytes)
                case "status": value = transferRowStatus(transferRow)
                case "server": value = item.serverName
                case "started": value = Self.dateString(item.startedAt)
                default: value = ""
                }
            case let .managed(item):
                if identifier == "user" {
                    return verticallyCenteredTableContent(transferUserCell(userID: item.userID))
                }
                switch identifier {
                case "direction": value = item.kind == LegacyTransferKind.download ? L("Download") : L("Upload")
                case "name": value = LegacyPath.displayName(item.path)
                case "progress": value = transferProgressText(completed: item.bytesTransferred, total: item.totalBytes)
                case "status": value = item.isAborting ? L("Aborting") : (item.isPaused ? L("Paused") : L("Transferring"))
                case "server": value = transferRowServerName(transferRow)
                case "started": value = LF("Task #%@", String(item.transferID))
                default: value = ""
                }
            case let .legacyServer(item):
                if identifier == "user" {
                    return verticallyCenteredTableContent(transferUserCell(userID: item.userID))
                }
                switch identifier {
                case "direction": value = item.kind == LegacyTransferKind.download ? L("Download") : L("Upload")
                case "name": value = LegacyPath.displayName(item.path)
                case "progress": value = transferProgressText(completed: item.bytesTransferred, total: item.totalBytes)
                case "status": value = L("Transferring")
                case "server": value = transferRowServerName(transferRow)
                case "started": value = L("Server")
                default: value = ""
                }
            }
        } else if tableView === trackerBrowserTable, row < displayedTrackerServers.count {
            let entry = displayedTrackerServers[row]
            switch identifier {
            case "name": value = Self.macRomanString(entry.serverName)
            case "users": value = String(entry.users)
            case "address": value = Self.trackerServerEndpoint(entry)
            case "description": value = Self.macRomanString(entry.description)
            case "bandwidth": value = LegacyTrackerProtocol.bandwidthTitle(for: entry.bandwidthCode) ?? (entry.bandwidthCode == 0 ? "—" : LF("Code %@", String(entry.bandwidthCode)))
            case "visibility": value = entry.isPrivate ? L("Private") : L("Public")
            default: value = ""
            }
        } else if tableView === userTable, row < visibleUsers.count {
            let user = visibleUsers[row]
            switch identifier {
            case "nickname": value = Self.macRomanString(user.nickname)
            case "state": value = (sleepingUsers.contains(user.userID) || (user.flags & 0x0100) != 0) ? L("Sleeping") : L("Online")
            case "id": value = String(user.userID)
            case "flags": value = String(format: "%04x", user.flags)
            default: value = ""
            }
        } else if tableView === channelTable, row < displayedChannels.count {
            let channel = displayedChannels[row]
            switch identifier {
            case "name": value = Self.macRomanString(channel.name)
            case "members": value = String(channel.memberCount)
            case "id": value = String(channel.channelID)
            case "flags": value = String(format: "%04x", channel.flags)
            default: value = ""
            }
        } else if tableView === channelMemberTable, row < sortedChannelMembers.count {
            let member = sortedChannelMembers[row]
            switch identifier {
            case "nickname": value = liveUsers[member.userID].map { Self.macRomanString($0.nickname) }
                ?? L("Unknown User")
            case "mode":
                if member.mode & Self.channelOperatorMode != 0 { value = "Operator" }
                else if member.mode & Self.channelSpeechMode != 0 { value = "Speaker" }
                else { value = "Member" }
            case "id": value = String(member.userID)
            default: value = ""
            }
        } else if tableView === newsTable, row < displayedNewsgroups.count {
            let group = displayedNewsgroups[row]
            switch identifier {
            case "name": value = Self.macRomanString(group)
            case "articles":
                if let threads = newsThreadsByCategory[group] {
                    let total = threads.reduce(UInt64(0)) { $0 + UInt64($1.replyCount) + 1 }
                    value = String(total)
                } else { value = "—" }
            case "expire": value = "—"
            default: value = ""
            }
        } else if tableView === newsArticleTable, row < displayedNewsThreads.count {
            let thread = displayedNewsThreads[row]
            switch identifier {
            case "subject": value = Self.macRomanString(thread.subject)
            case "sender": value = Self.macRomanString(thread.sender)
            case "replies": value = String(thread.replyCount)
            case "date": value = Self.dateString(Date.fromLegacyMacTimestamp(thread.date))
            case "activity": value = Self.dateString(Date.fromLegacyMacTimestamp(thread.latestDate))
            default: value = ""
            }
        } else if tableView === adminAccountTable, usesRemoteAccountAdministration, row < displayedRemoteAccounts.count {
            let account = displayedRemoteAccounts[row]
            switch identifier {
            case "name": value = Self.macRomanString(account.name)
            case "login": value = Self.macRomanString(account.login)
            case "status":
                if usesClassicRemoteAccountAdministration {
                    switch LegacyCompactAccountSummary.UserMode(rawValue: account.userMode) {
                    case .administrator: value = L("Administrator")
                    case .accountHolder: value = L("Account Holder")
                    default: value = L("Guest")
                    }
                } else {
                    let login = Self.macRomanString(account.login).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    if let groupID = remoteAccountGroupByLogin[login], let group = remoteAccountGroups.first(where: { $0.id == groupID }) {
                        value = group.name
                    } else { value = L("Unassigned") }
                }
            case "last": value = Self.dateString(Date.fromLegacyMacTimestamp(account.lastLogin))
            case "downloads": value = account.transferStatistics.map { String($0.downloadCount) } ?? "—"
            case "downloadBytes": value = account.transferStatistics.map { Self.accountTransferByteString($0.downloadBytes) } ?? "—"
            case "uploads": value = account.transferStatistics.map { String($0.uploadCount) } ?? "—"
            case "uploadBytes": value = account.transferStatistics.map { Self.accountTransferByteString($0.uploadBytes) } ?? "—"
            default: value = ""
            }
        } else if tableView === adminAccountTable, row < displayedLocalAccounts.count {
            let account = displayedLocalAccounts[row]
            switch identifier {
            case "name": value = account.name
            case "login": value = account.login
            case "status": value = localServerState.accountGroup(for: account)?.name ?? L("Unassigned")
            case "last": value = Self.dateString(account.lastLoginAt)
            case "downloads": value = localAccountTransferStatistics[account.id].map { String($0.downloadCount) } ?? "—"
            case "downloadBytes": value = localAccountTransferStatistics[account.id].map { Self.accountTransferByteString($0.downloadBytes) } ?? "—"
            case "uploads": value = localAccountTransferStatistics[account.id].map { String($0.uploadCount) } ?? "—"
            case "uploadBytes": value = localAccountTransferStatistics[account.id].map { Self.accountTransferByteString($0.uploadBytes) } ?? "—"
            default: value = ""
            }
        } else if tableView === adminNewsgroupTable, row < displayedAdminNewsgroups.count {
            let group = displayedAdminNewsgroups[row]
            switch identifier {
            case "name": value = group.name
            case "articles": value = String(group.articleCount)
            case "expire": value = Self.expirationDisplay(group.expireAfterSeconds)
            default: value = ""
            }
        } else if tableView === adminTrackerTable, row < displayedTrackers.count {
            let tracker = displayedTrackers[row]
            switch identifier {
            case "name": value = tracker.name
            case "address": value = tracker.address
            default: value = ""
            }
        } else {
            value = ""
        }

        let icon: NSImage?
        if tableView === transferTable && identifier == "direction", row < transferMonitorRows.count {
            let kind: UInt8
            switch transferMonitorRows[row] {
            case let .local(item): kind = item.kind
            case let .managed(item): kind = item.kind
            case let .legacyServer(item): kind = item.kind
            }
            icon = symbolImage(kind == LegacyTransferKind.download ? "arrow.down.circle.fill" : "arrow.up.circle.fill", fallback: NSImage.infoName)
        } else if tableView === fileTable && identifier == "name", row < visibleFileRows.count {
            return fileNameCell(for: visibleFileRows[row], row: row)
        } else if tableView === userTable && identifier == "nickname", row < visibleUsers.count {
            return verticallyCenteredTableContent(userListCell(for: visibleUsers[row]), fillWidth: true)
        } else if tableView === newsTable && identifier == "name", row < displayedNewsgroups.count {
            // Match the topic rows: keep category content fully inside the rounded selection
            // background with an extra 5 pt of breathing room. The category selection has no
            // accent stripe, so 4 pt row inset + 5 pt padding = 9 pt.
            return verticallyCenteredTableContent(
                newsCategoryCell(for: displayedNewsgroups[row]),
                fillWidth: true,
                leadingInset: 9,
                trailingInset: 9
            )
        } else if tableView === newsArticleTable && identifier == "subject", row < displayedNewsThreads.count {
            return verticallyCenteredTableContent(
                newsThreadSubjectCell(for: displayedNewsThreads[row]),
                fillWidth: true,
                leadingInset: 12,
                trailingInset: 6
            )
        } else if tableView === channelTable && identifier == "name", row < displayedChannels.count {
            return verticallyCenteredTableContent(channelRoomCell(for: displayedChannels[row]))
        } else {
            icon = nil
        }
        let cellFontSize: CGFloat
        if tableView === fileTable { cellFontSize = filesFontSize }
        else if tableView === newsTable || tableView === newsArticleTable { cellFontSize = newsFontSize }
        else { cellFontSize = 12.5 }
        let numericAccountColumn = tableView === adminAccountTable
            && ["downloads", "downloadBytes", "uploads", "uploadBytes"].contains(identifier)
        return tableCell(text: value, image: icon,
                         secondary: tableView === userTable && identifier == "state",
                         fontSize: cellFontSize,
                         alignment: numericAccountColumn ? .right : .left)
    }

    func symbolImage(_ name: String, fallback: String) -> NSImage? {
        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            return image
        }
        return NSImage(named: fallback)
    }

    func tableCell(text: String, image: NSImage?, secondary: Bool = false, fontSize: CGFloat = 12.5,
                   alignment: NSTextAlignment = .left) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        field.textColor = secondary ? CarrachoTheme.secondaryText : .labelColor
        guard let image else { return verticallyCenteredTableContent(field) }
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = secondary ? CarrachoTheme.secondaryText : CarrachoTheme.selection
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let stack = NSStackView(views: [imageView, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        return verticallyCenteredTableContent(stack)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if tableView === fileTable || tableView === transferTable || tableView === newsArticleTable {
            let rowView = CarrachoStripedTableRowView()
            rowView.alternate = row % 2 != 0
            if tableView === fileTable { rowView.rowTintColor = fileRowLabelTint(at: row) }
            return rowView
        }
        if tableView === privateMessageConversationTable || tableView === newsTable || tableView === adminTrackerTable {
            return CarrachoNewsTableRowView()
        }
        guard tableView === userTable else { return nil }
        let rowView = CarrachoUserTableRowView()
        rowView.alternate = false
        return rowView
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if tableView === transferTable {
            refreshTransferMonitorUI()
            return
        }
        if tableView === fileTable {
            reloadFileTablePreservingState()
            updateFileTransferButtons()
            return
        }
        // Sorting changes row identity. Clear the old numeric selection before reloading so
        // actions never accidentally target a different object that moved into the same row.
        tableView.deselectAll(nil)
        tableView.reloadData()
        if tableView === fileTable { updateFileTransferButtons() }
        if tableView === userTable {
            selectedUserID = nil
            updateUserActionButtons()
        }
        if tableView === channelTable || tableView === channelMemberTable { reloadChannelView() }
        if tableView === newsTable || tableView === newsArticleTable { reloadNewsView() }
        if tableView === adminAccountTable || tableView === adminNewsgroupTable || tableView === adminTrackerTable {
            updateAdminSelectionButtons()
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === adminBotCommandTable {
            updateBotCommandRuleButtons()
            return
        }
        if table === adminBotRSSTable {
            updateBotRSSButtons()
            return
        }
        if table === fileTable {
            let rows = visibleFileRows
            selectedFilePaths = Set(fileTable.selectedRowIndexes.compactMap { index in
                guard index >= 0, index < rows.count else { return nil }
                return rows[index].path
            })
            updateFileTransferButtons()
        }
        if table === transferTable {
            if !isReloadingTransferTable {
                let rows = transferMonitorRows
                selectedTransferKeys = Set(transferTable.selectedRowIndexes.compactMap { index in
                    guard index >= 0, index < rows.count else { return nil }
                    return transferRowKey(rows[index])
                })
                updatePrimaryTransferSelectionFromTable()
            }
            updateTransferActionButtons()
            updateTransferDetailsUI()
        }
        if table === privateMessageConversationTable {
            guard !isReloadingPrivateMessageTable else { return }
            let row = privateMessageConversationTable.selectedRow
            let rows = displayedMessageCenterRows
            if row >= 0, row < rows.count {
                switch rows[row] {
                case .offlineMessages:
                    selectOfflineMessageCategory()
                case let .conversation(conversation):
                    selectPrivateConversation(conversation.userID, focusComposer: false)
                }
            } else {
                if let previousID = selectedPrivateConversationID, var previous = privateMessageConversations[previousID] {
                    previous.draftText = privateMessageComposer.string
                    privateMessageConversations[previousID] = previous
                }
                selectedPrivateConversationID = nil
                selectedOfflineMessages = false
                privateMessageComposer.string = ""
                refreshPrivateMessageCenter(scrollToBottom: false)
            }
        }
        if table === userTable {
            if !isReloadingUserTable {
                let row = userTable.selectedRow
                selectedUserID = row >= 0 && row < visibleUsers.count ? visibleUsers[row].userID : nil
            }
            updateUserActionButtons()
        }
        if table === channelTable {
            guard !isReloadingChannelTable else { return }
            updateChannelDiscoverySelection()
        }
        if table === channelMemberTable {
            updateInspectorContext()
        }
        if table === newsTable {
            guard !isReloadingNewsTable else { return }
            let row = newsTable.selectedRow
            if row >= 0, row < displayedNewsgroups.count {
                let group = displayedNewsgroups[row]
                if currentNewsCategory != group { loadNewsIndex(group: group) }
                else { reloadNewsView() }
            } else {
                reloadNewsView()
            }
        }
        if table === newsArticleTable {
            if isReloadingNewsTable { return }
            let row = newsArticleTable.selectedRow
            guard row >= 0, row < displayedNewsThreads.count else {
                reloadNewsView()
                return
            }
            let threadID = displayedNewsThreads[row].threadID
            if let group = currentNewsCategory, currentNewsThreadID != threadID {
                loadNewsThread(group: group, threadID: threadID)
            } else {
                reloadNewsView()
            }
        }
        if table === adminAccountTable || table === adminNewsgroupTable || table === adminTrackerTable { updateAdminSelectionButtons() }
    }

    var displayedTrackerServers: [LegacyTrackerServerEntry] {
        guard let selectedTrackerID else { return [] }
        let values = trackerResults[selectedTrackerID] ?? []
        return sortedForTable(values, table: trackerBrowserTable, defaultCompare: { lhs, rhs in
            let comparison = Self.compareText(Self.macRomanString(lhs.serverName), Self.macRomanString(rhs.serverName))
            return comparison == .orderedSame
                ? Self.compareText(Self.trackerServerEndpoint(lhs), Self.trackerServerEndpoint(rhs))
                : comparison
        }) { lhs, rhs, key in
            switch key {
            case "name": return Self.compareText(Self.macRomanString(lhs.serverName), Self.macRomanString(rhs.serverName))
            case "users": return Self.compareNumber(lhs.users, rhs.users)
            case "address": return Self.compareText(Self.trackerServerEndpoint(lhs), Self.trackerServerEndpoint(rhs))
            case "description": return Self.compareText(Self.macRomanString(lhs.description), Self.macRomanString(rhs.description))
            case "bandwidth": return Self.compareNumber(lhs.bandwidthCode, rhs.bandwidthCode)
            case "visibility": return Self.compareText(lhs.isPrivate ? L("Private") : L("Public"), rhs.isPrivate ? L("Private") : L("Public"))
            default: return .orderedSame
            }
        }
    }

    var displayedChannels: [LegacyChannelSummary] {
        sortedForTable(lastChannels, table: channelTable) { lhs, rhs, key in
            switch key {
            case "members": return Self.compareNumber(lhs.memberCount, rhs.memberCount)
            case "name": return Self.compareText(Self.macRomanString(lhs.name), Self.macRomanString(rhs.name))
            default: return .orderedSame
            }
        }
    }

    var sortedChannelMembers: [LegacyChannelMember] {
        let members = channelMembers.map { LegacyChannelMember(userID: $0.key, mode: $0.value) }
        return sortedForTable(members, table: channelMemberTable, defaultCompare: { lhs, rhs in
            let left = self.liveUsers[lhs.userID].map { Self.macRomanString($0.nickname) } ?? String(lhs.userID)
            let right = self.liveUsers[rhs.userID].map { Self.macRomanString($0.nickname) } ?? String(rhs.userID)
            let comparison = Self.compareText(left, right)
            return comparison == .orderedSame ? Self.compareNumber(lhs.userID, rhs.userID) : comparison
        }) { lhs, rhs, key in
            switch key {
            case "nickname":
                let left = self.liveUsers[lhs.userID].map { Self.macRomanString($0.nickname) } ?? String(lhs.userID)
                let right = self.liveUsers[rhs.userID].map { Self.macRomanString($0.nickname) } ?? String(rhs.userID)
                let comparison = Self.compareText(left, right)
                return comparison == .orderedSame ? Self.compareNumber(lhs.userID, rhs.userID) : comparison
            case "mode":
                func rank(_ member: LegacyChannelMember) -> Int {
                    if member.mode & Self.channelOperatorMode != 0 { return 2 }
                    if member.mode & Self.channelSpeechMode != 0 { return 1 }
                    return 0
                }
                return Self.compareNumber(rank(lhs), rank(rhs))
            default: return .orderedSame
            }
        }
    }

    var sortedFileSearchResults: [LegacyFileSearchResult]? {
        guard let results = fileSearchResults else { return nil }
        return sortedForTable(results, table: fileTable) { lhs, rhs, key in
            switch key {
            case "name": return Self.compareText(LegacyPath.displayString(lhs.path), LegacyPath.displayString(rhs.path))
            case "size": return Self.compareNumber(lhs.size, rhs.size)
            case "kind": return Self.compareText(lhs.isFolder ? L("Folder") : L("File"), rhs.isFolder ? L("Folder") : L("File"))
            case "modified": return Self.compareNumber(lhs.timestamp, rhs.timestamp)
            default: return .orderedSame
            }
        }
    }

    var visibleFileRows: [VisibleFileRow] {
        visibleFileRowSnapshot
    }

    func rebuildVisibleFileRowSnapshot() {
        if let results = sortedFileSearchResults {
            visibleFileRowSnapshot = results.map {
                VisibleFileRow(entry: $0.directoryEntry, path: $0.path, depth: 0)
            }
            return
        }
        guard let root = lastDirectory else {
            visibleFileRowSnapshot = []
            return
        }

        var rows: [VisibleFileRow] = []
        rows.reserveCapacity(root.entries.count)

        func append(_ listing: LegacyDirectoryListing, depth: Int) {
            for entry in sortedDirectoryEntries(listing.entries) {
                guard let path = try? LegacyPath.child(parent: listing.currentPath, name: entry.name) else { continue }
                rows.append(VisibleFileRow(entry: entry, path: path, depth: depth))
                guard entry.isFolder,
                      expandedFilePaths.contains(path),
                      let child = expandedDirectoryListings[path] else { continue }
                append(child, depth: depth + 1)
            }
        }

        append(root, depth: 0)
        visibleFileRowSnapshot = rows
    }

    var visibleUsers: [LegacyUserListEntry] {
        sortedUsers
    }

    var sortedUsers: [LegacyUserListEntry] {
        let users = Array(liveUsers.values)
        return sortedForTable(users, table: userTable, defaultCompare: { lhs, rhs in
            // User IDs are allocated monotonically when a session logs in. Sorting ascending
            // therefore keeps the longest-connected users at the top of the default user list.
            let comparison = Self.compareNumber(lhs.userID, rhs.userID)
            return comparison == .orderedSame
                ? Self.compareText(Self.macRomanString(lhs.nickname), Self.macRomanString(rhs.nickname))
                : comparison
        }) { lhs, rhs, key in
            switch key {
            case "nickname":
                let comparison = Self.compareText(Self.macRomanString(lhs.nickname), Self.macRomanString(rhs.nickname))
                return comparison == .orderedSame ? Self.compareNumber(lhs.userID, rhs.userID) : comparison
            case "id": return Self.compareNumber(lhs.userID, rhs.userID)
            default: return .orderedSame
            }
        }
    }

    var displayedNewsgroups: [Data] {
        sortedForTable(lastNewsgroups, table: newsTable) { lhs, rhs, key in
            switch key {
            case "name": return Self.compareText(Self.macRomanString(lhs), Self.macRomanString(rhs))
            case "articles":
                let left = self.newsThreadsByCategory[lhs]?.reduce(UInt64(0)) { $0 + UInt64($1.replyCount) + 1 } ?? 0
                let right = self.newsThreadsByCategory[rhs]?.reduce(UInt64(0)) { $0 + UInt64($1.replyCount) + 1 } ?? 0
                return Self.compareNumber(left, right)
            case "expire": return .orderedSame
            default: return .orderedSame
            }
        }
    }

    var displayedNewsThreads: [LegacyNewsThreadSummary] {
        sortedForTable(currentNewsThreads, table: newsArticleTable,
                       defaultCompare: { lhs, rhs in Self.compareNumber(rhs.latestDate, lhs.latestDate) }) { lhs, rhs, key in
            switch key {
            case "subject": return Self.compareText(Self.macRomanString(lhs.subject), Self.macRomanString(rhs.subject))
            case "sender": return Self.compareText(Self.macRomanString(lhs.sender), Self.macRomanString(rhs.sender))
            case "replies": return Self.compareNumber(lhs.replyCount, rhs.replyCount)
            case "date": return Self.compareNumber(lhs.date, rhs.date)
            case "activity": return Self.compareNumber(lhs.latestDate, rhs.latestDate)
            default: return .orderedSame
            }
        }
    }

    var displayedRemoteAccounts: [LegacyCompactAccountSummary] {
        sortedForTable(remoteAccountSummaries, table: adminAccountTable) { lhs, rhs, key in
            func groupName(_ account: LegacyCompactAccountSummary) -> String {
                let login = Self.macRomanString(account.login).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard let groupID = self.remoteAccountGroupByLogin[login],
                      let group = self.remoteAccountGroups.first(where: { $0.id == groupID }) else { return L("Unassigned") }
                return group.name
            }
            switch key {
            case "name": return Self.compareText(Self.macRomanString(lhs.name), Self.macRomanString(rhs.name))
            case "login": return Self.compareText(Self.macRomanString(lhs.login), Self.macRomanString(rhs.login))
            case "status": return Self.compareText(groupName(lhs), groupName(rhs))
            case "last": return Self.compareNumber(lhs.lastLogin, rhs.lastLogin)
            case "downloads": return Self.compareNumber(lhs.transferStatistics?.downloadCount ?? 0, rhs.transferStatistics?.downloadCount ?? 0)
            case "downloadBytes": return Self.compareNumber(lhs.transferStatistics?.downloadBytes ?? 0, rhs.transferStatistics?.downloadBytes ?? 0)
            case "uploads": return Self.compareNumber(lhs.transferStatistics?.uploadCount ?? 0, rhs.transferStatistics?.uploadCount ?? 0)
            case "uploadBytes": return Self.compareNumber(lhs.transferStatistics?.uploadBytes ?? 0, rhs.transferStatistics?.uploadBytes ?? 0)
            default: return .orderedSame
            }
        }
    }

    var displayedLocalAccounts: [ServerAccount] {
        sortedForTable(localServerState.accounts, table: adminAccountTable) { lhs, rhs, key in
            switch key {
            case "name": return Self.compareText(lhs.name, rhs.name)
            case "login": return Self.compareText(lhs.login, rhs.login)
            case "status":
                let left = self.localServerState.accountGroup(for: lhs)?.name ?? L("Unassigned")
                let right = self.localServerState.accountGroup(for: rhs)?.name ?? L("Unassigned")
                return Self.compareText(left, right)
            case "last": return Self.compareOptionalDate(lhs.lastLoginAt, rhs.lastLoginAt)
            case "downloads": return Self.compareNumber(self.localAccountTransferStatistics[lhs.id]?.downloadCount ?? 0,
                                                          self.localAccountTransferStatistics[rhs.id]?.downloadCount ?? 0)
            case "downloadBytes": return Self.compareNumber(self.localAccountTransferStatistics[lhs.id]?.downloadBytes ?? 0,
                                                              self.localAccountTransferStatistics[rhs.id]?.downloadBytes ?? 0)
            case "uploads": return Self.compareNumber(self.localAccountTransferStatistics[lhs.id]?.uploadCount ?? 0,
                                                        self.localAccountTransferStatistics[rhs.id]?.uploadCount ?? 0)
            case "uploadBytes": return Self.compareNumber(self.localAccountTransferStatistics[lhs.id]?.uploadBytes ?? 0,
                                                            self.localAccountTransferStatistics[rhs.id]?.uploadBytes ?? 0)
            default: return .orderedSame
            }
        }
    }

    var displayedAdminNewsgroups: [ServerNewsgroup] {
        let groups = usesRemoteNewsgroupAdministration ? remoteAdminNewsgroups : localServerState.newsgroups
        return sortedForTable(groups, table: adminNewsgroupTable) { lhs, rhs, key in
            switch key {
            case "name": return Self.compareText(lhs.name, rhs.name)
            case "articles": return Self.compareNumber(lhs.articleCount, rhs.articleCount)
            case "expire": return Self.compareNumber(lhs.expireAfterSeconds, rhs.expireAfterSeconds)
            default: return .orderedSame
            }
        }
    }

    var displayedTrackerDraftIndices: [Int] {
        let indexed = Array(trackerDraftTrackers.indices)
        guard let descriptor = sortDescriptor(for: adminTrackerTable) else { return indexed }
        return indexed.sorted { leftIndex, rightIndex in
            let lhs = trackerDraftTrackers[leftIndex]
            let rhs = trackerDraftTrackers[rightIndex]
            let result: ComparisonResult
            switch descriptor.key {
            case "name": result = Self.compareText(lhs.name, rhs.name)
            case "address": result = Self.compareText(lhs.address, rhs.address)
            default: result = .orderedSame
            }
            if result == .orderedSame { return leftIndex < rightIndex }
            return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    var displayedTrackers: [ServerTrackerSetting] {
        displayedTrackerDraftIndices.map { trackerDraftTrackers[$0] }
    }

    func updateServerBannerHeaderWidth() {
        guard let constraint = serverBannerWidthConstraint else { return }
        guard let image = rightBannerImageView.image, image.size.height > 0 else {
            constraint.constant = 280
            return
        }
        // The banner row is 58 pt high. Size its host to the width the image actually occupies at
        // that height instead of reserving a hard 280 pt. This removes the dead strip between a
        // narrower banner/logo and the server title while still capping very wide classic banners.
        let renderedWidth = 58 * (image.size.width / image.size.height)
        constraint.constant = min(280, max(120, renderedWidth))
    }

    func refreshShellChrome() {
        let connected = client.isConnected
        let configuredEndpoint = "\(hostField.stringValue):\(portField.stringValue)"
        let displayServerName = lastServerInfo?.serverName ?? lastLoginResult?.serverName ?? "Carracho Server"

        serverTitleLabel.stringValue = displayServerName
        serverTitleLabel.toolTip = displayServerName
        rightServerNameValue.stringValue = displayServerName
        let description = lastServerInfo?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        rightServerDescriptionValue.stringValue = description
        rightServerDescriptionValue.toolTip = description.isEmpty ? nil : description
        rightServerDescriptionValue.isHidden = description.isEmpty
        serverBannerHost?.isHidden = rightBannerImageView.image == nil
        serverBannerSeparator?.isHidden = rightBannerImageView.image == nil
        updateServerBannerHeaderWidth()
        rightServerUsersValue.stringValue = String(liveUsers.count)
        updateUserActionButtons()

        let transferVersion = lastLoginResult?.transferProtocolVersion
        if let softwareVersion = lastServerInfo?.softwareVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !softwareVersion.isEmpty {
            rightServerVersionValue.stringValue = softwareVersion
        } else {
            rightServerVersionValue.stringValue = "—"
        }
        rightServerProtocolValue.stringValue = connected
            ? (transferVersion.map { "Carracho v\($0)" } ?? "Carracho Classic")
            : "—"
        if connected {
            rightServerCipherValue.stringValue = client.transferSession?.usesModernCrypto == true ? L("AES-256-GCM") : L("Blowfish")
        } else {
            rightServerCipherValue.stringValue = "—"
        }
        rightEndpointValue.stringValue = connected ? configuredEndpoint : "—"
        rightEndpointValue.toolTip = connected ? configuredEndpoint : nil
        rightServerVersionValue.toolTip = rightServerVersionValue.stringValue == "—" ? nil : rightServerVersionValue.stringValue
        rightServerProtocolValue.toolTip = rightServerProtocolValue.stringValue == "—" ? nil : rightServerProtocolValue.stringValue
        rightServerCipherValue.toolTip = rightServerCipherValue.stringValue == "—" ? nil : rightServerCipherValue.stringValue
        updateRightServerUptimeLabel()
        // These legacy labels are no longer mounted in the shell, but keeping them current
        // avoids surprising any existing code that still consults them.
        bottomEndpointLabel.stringValue = connected ? configuredEndpoint : "—"
        bottomEncryptionLabel.stringValue = connected ? L("Encrypted") : ""
        bottomEncryptionLabel.textColor = connected ? CarrachoTheme.success : CarrachoTheme.secondaryText
        headerConnectionButton.title = connected ? L("Disconnect") : (autoReconnectWorkItem != nil ? L("Cancel Reconnect") : L("Connect"))
        headerConnectionButton.image = symbolImage(
            connected ? "rectangle.portrait.and.arrow.right" : "powerplug.fill",
            fallback: connected ? NSImage.stopProgressTemplateName : NSImage.actionTemplateName
        )
        headerConnectionButton.toolTip = connected ? L("Disconnect from the active server") : L("Connect to a server")
        refreshAdministrativeNavigationVisibility()
        updateInspectorToggleButton()

        if connected {
            bottomStatusLabel.stringValue = LF("●  Connected to %@", displayServerName)
            bottomStatusLabel.textColor = CarrachoTheme.success
        } else {
            bottomStatusLabel.stringValue = L("Not connected")
            bottomStatusLabel.textColor = CarrachoTheme.secondaryText
        }

        if let active = activeChannel {
            chatUsersLabel.stringValue = channelMembers.count == 1 ? LF("%@ user", String(channelMembers.count)) : LF("%@ users", String(channelMembers.count))
            let room = Self.macRomanString(active.name)
            if channelTitleLabel.stringValue.isEmpty || channelTitleLabel.stringValue == L("Choose a chat room") {
                channelTitleLabel.stringValue = "#\(room)"
            }
            let topic = Self.macRomanString(active.topic)
            chatTopicLabel.stringValue = topic.isEmpty ? L("No topic") : LF("Topic: %@", topic)
            chatTopicLabel.toolTip = topic.isEmpty ? nil : topic
            chatTopicLabel.isHidden = false
        } else {
            chatUsersLabel.stringValue = lastChannels.isEmpty ? "" : (liveUsers.count == 1 ? LF("%@ user online", String(liveUsers.count)) : LF("%@ users online", String(liveUsers.count)))
        }
    }

    func applyRemoteServerUptimeTicks(_ ticks: UInt32) {
        remoteServerUptimeSeconds = Double(ticks) / 60.0
        remoteServerUptimeObservedAt = Date()
        startServerUptimeDisplayTimer()
        updateRightServerUptimeLabel()
    }

    func refreshRemoteServerUptime() {
        guard client.isConnected else {
            remoteServerUptimeSeconds = nil
            remoteServerUptimeObservedAt = nil
            serverUptimeDisplayTimer?.invalidate()
            serverUptimeDisplayTimer = nil
            updateRightServerUptimeLabel()
            return
        }
        let target = client
        target.requestServerSettings(fields: [LegacyServerSettingField.uptimeTicks]) { [weak self, weak target] result in
            guard let self, let target, self.client === target else { return }
            guard case let .success(values) = result,
                  let data = values[LegacyServerSettingField.uptimeTicks], data.count == 4 else {
                self.updateRightServerUptimeLabel()
                return
            }
            do {
                var cursor = LegacyByteCursor(data)
                let ticks = try cursor.readUInt32BE()
                try cursor.requireEnd()
                self.applyRemoteServerUptimeTicks(ticks)
            } catch {
                self.remoteServerUptimeSeconds = nil
                self.remoteServerUptimeObservedAt = nil
                self.updateRightServerUptimeLabel()
            }
        }
    }

    func startServerUptimeDisplayTimer() {
        serverUptimeDisplayTimer?.invalidate()
        guard client.isConnected, remoteServerUptimeSeconds != nil else { return }
        serverUptimeDisplayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateRightServerUptimeLabel()
        }
    }

    func updateRightServerUptimeLabel() {
        guard client.isConnected,
              let base = remoteServerUptimeSeconds,
              let observedAt = remoteServerUptimeObservedAt else {
            rightServerUptimeValue.stringValue = "—"
            return
        }
        let seconds = max(0, base + Date().timeIntervalSince(observedAt))
        rightServerUptimeValue.stringValue = Self.serverUptimeDisplay(seconds)
    }

    static func serverUptimeDisplay(_ seconds: TimeInterval) -> String {
        let total = UInt64(max(0, seconds.rounded(.down)))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if days > 0 { return String(format: "%llu d %02llu:%02llu:%02llu", days, hours, minutes, secs) }
        return String(format: "%02llu:%02llu:%02llu", hours, minutes, secs)
    }

    func showError(_ message: String) {
        emitClientEvent(.error,
                        notificationTitle: L("Carracho Error"),
                        notificationBody: clientNotificationSnippet(message))
        appendLine("\n" + LF("Error: %@", message))
        statusLabel.stringValue = L("Error")
        statusLabel.textColor = .systemRed
        CarrachoTheme.setPrimaryButtonTitle(connectButton, L("Connect"))
        connectButton.isEnabled = true
        setInputsEnabled(true)
    }

    func appendServerLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        localServerLogLines.append("[\(formatter.string(from: Date()))] \(line)")
        if localServerLogLines.count > 10_000 { localServerLogLines.removeFirst(localServerLogLines.count - 10_000) }
        if !client.isConnected {
            serverLogTextView.string = localServerLogLines.joined(separator: "\n")
            serverLogTextView.scrollToEndOfDocument(nil)
        }
    }

    func appendLine(_ text: String) {
        detailsTextView.string += text
        detailsTextView.scrollToEndOfDocument(nil)
    }

    func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    static func macRomanString(_ data: Data) -> String {
        CarrachoTextWire.string(from: data)
    }

    static func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        return displayDateFormatter.string(from: date)
    }

    static func expirationDisplay(_ seconds: UInt32) -> String {
        if seconds == UInt32.max { return L("Never") }
        let units: [(UInt32, String, String)] = [
            (31536000, "%@ year", "%@ years"),
            (2592000, "%@ month", "%@ months"),
            (604800, "%@ week", "%@ weeks"),
            (86400, "%@ day", "%@ days"),
            (3600, "%@ hour", "%@ hours"),
        ]
        for (factor, singular, plural) in units where seconds >= factor && seconds % factor == 0 {
            let value = seconds / factor
            return LF(value == 1 ? singular : plural, String(value))
        }
        return LF(seconds == 1 ? "%@ second" : "%@ seconds", String(seconds))
    }

    static func ipv4String(_ value: UInt32) -> String {
        String(format: "%u.%u.%u.%u", (value >> 24) & 0xff, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
    }

    static func durationString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let total = max(0, Int(seconds.rounded(.down)))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if days > 0 { return LF("%@d %@h %@m", String(days), String(hours), String(minutes)) }
        if hours > 0 { return LF("%@h %@m", String(hours), String(minutes)) }
        if minutes > 0 { return LF("%@m %@s", String(minutes), String(secs)) }
        return LF("%@s", String(secs))
    }

    static func macDateString(_ timestamp: UInt32) -> String {
        guard timestamp != 0 else { return "—" }
        // Classic Mac epoch starts 1904-01-01; Unix starts 1970-01-01.
        let unix = TimeInterval(Int64(timestamp) - 2_082_844_800)
        guard unix > -2_082_844_800 else { return "—" }
        return displayDateFormatter.string(from: Date(timeIntervalSince1970: unix))
    }

    static func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return String(describing: error)
    }
}
