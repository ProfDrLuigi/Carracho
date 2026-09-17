import Cocoa
import QuickLookUI

// MARK: - AdminShared

extension ViewController {

    func adminPage(title: String, subtitle: String) -> NSView {
        let page = NSView()
        let titleField = NSTextField(labelWithString: L(title))
        titleField.font = NSFont.systemFont(ofSize: 23, weight: .semibold)
        let subtitleField = NSTextField(labelWithString: L(subtitle))
        subtitleField.textColor = CarrachoTheme.secondaryText
        let header = NSStackView(views: [titleField, subtitleField])
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 3
        header.identifier = NSUserInterfaceItemIdentifier("adminHeader")
        header.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -4),
            header.topAnchor.constraint(equalTo: page.topAnchor, constant: 4),
        ])
        return page
    }

    func appendAdminContent(_ views: [NSView], to page: NSView, minimumBodyHeight: CGFloat) {
        guard let header = page.subviews.first(where: { $0.identifier?.rawValue == "adminHeader" }) else { return }

        // Administration pages can be taller than the current workspace. Keep the header
        // fixed and let the body scroll instead of forcing the whole tab to satisfy a
        // large required minimum height (Advanced is intentionally about 1210 pt tall).
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let document = CarrachoFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let card = cardView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(card)
        page.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -4),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            card.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            card.topAnchor.constraint(equalTo: document.topAnchor),
            card.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumBodyHeight),
            card.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
    }

    func remotePermissionEnabled(_ bit: Int) -> Bool {
        guard let session = lastLoginResult?.session, bit >= 0, bit < 64 else { return false }
        let words = [session.permissionWord0, session.permissionWord1]
        let word = words[bit / 32]
        let bitInWord = bit % 32
        return (word & (UInt32(0x8000_0000) >> UInt32(bitInWord))) != 0
    }

    func administrativePermission(for workspace: Workspace) -> Int? {
        administrativeWorkspacePermissions.first(where: { $0.0 == workspace })?.1
    }

    func canAccessAdministrativeWorkspace(_ workspace: Workspace) -> Bool {
        if isConnectedToClassicServer,
           workspace == .advanced || workspace == .events || workspace == .serverLog || workspace == .bot {
            return false
        }
        guard isRemoteAdministrator, let permission = administrativePermission(for: workspace) else { return false }
        return remotePermissionEnabled(permission)
    }

    func refreshAdministrativeNavigationVisibility() {
        var anyAdministrativeWorkspaceVisible = false
        for (workspace, _) in administrativeWorkspacePermissions {
            let visible = canAccessAdministrativeWorkspace(workspace)
            sidebarButtons[workspace]?.isHidden = !visible
            anyAdministrativeWorkspaceVisible = anyAdministrativeWorkspaceVisible || visible
        }
        let broadcastVisible = canBroadcastMessages
        broadcastButton.isHidden = !broadcastVisible
        let anyAdministrationItemVisible = anyAdministrativeWorkspaceVisible || broadcastVisible
        administrationSidebarBlock?.isHidden = !anyAdministrationItemVisible
        administrationSidebarHeader?.isHidden = !anyAdministrationItemVisible
        let administrationCollapsed = UserDefaults.standard.bool(forKey: Self.administrationSidebarCollapsedDefaultsKey)
        administrationSidebarContent?.isHidden = !anyAdministrationItemVisible || administrationCollapsed
        updateSidebarSectionButton(administrationSidebarHeader, title: "ADMINISTRATION", collapsed: administrationCollapsed)
        sidebarButtons[.transfers]?.isHidden = !canAccessTransferWorkspace
        advancedToolbarButton?.isHidden = !canAccessAdministrativeWorkspace(.advanced)
        refreshTransferBandwidthControls()

        if let serversMenu = NSApp.mainMenu?.item(withTitle: L("Servers"))?.submenu {
            serversMenu.item(withTitle: L("Administration"))?.isHidden = !anyAdministrativeWorkspaceVisible
            serversMenu.item(withTitle: L("Server Info"))?.isHidden = !canAccessAdministrativeWorkspace(.serverInfo)
        }

        if administrativePermission(for: currentWorkspace) != nil,
           !canAccessAdministrativeWorkspace(currentWorkspace) {
            selectWorkspace(.overview)
        } else if currentWorkspace == .transfers, !canAccessTransferWorkspace {
            selectWorkspace(.overview)
        }
    }

    func permissionCheckboxBox(title: String,
                                       items: [(String, ServerPermission)],
                                       selected: Set<ServerPermission>,
                                       controls: inout [ServerPermission: NSButton],
                                       columns: Int) -> NSView {
        let box = cardView()
        let titleField = sectionCaption(title)
        let columnCount = max(columns, 1)
        let rowsPerColumn = Int(ceil(Double(items.count) / Double(columnCount)))
        var columnViews: [NSStackView] = []
        for column in 0..<columnCount {
            let start = column * rowsPerColumn
            let end = min(items.count, start + rowsPerColumn)
            var buttons: [NSView] = []
            if start < end {
                for (label, permission) in items[start..<end] {
                    let button = NSButton(checkboxWithTitle: L(label), target: nil, action: nil)
                    button.state = selected.contains(permission) ? .on : .off
                    controls[permission] = button
                    buttons.append(button)
                }
            }
            let stack = NSStackView(views: buttons)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            columnViews.append(stack)
        }
        let columnsStack = NSStackView(views: columnViews)
        columnsStack.orientation = .horizontal
        columnsStack.alignment = .top
        columnsStack.distribution = .fillEqually
        columnsStack.spacing = 12
        let stack = NSStackView(views: [titleField, columnsStack])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9),
        ])
        return box
    }

    func sectionCaption(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: L(title))
        field.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    func checkboxGrid(title: String, labels: [String], columns: Int) -> NSView {
        let box = cardView()
        let titleField = sectionCaption(title)
        var columnViews: [NSStackView] = []
        let rowsPerColumn = Int(ceil(Double(labels.count) / Double(max(columns, 1))))
        for column in 0..<max(columns, 1) {
            let start = column * rowsPerColumn
            let end = min(labels.count, start + rowsPerColumn)
            let controls: [NSView] = start < end ? labels[start..<end].map { NSButton(checkboxWithTitle: L($0), target: nil, action: nil) } : []
            let stack = NSStackView(views: controls); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
            columnViews.append(stack)
        }
        let columnsStack = NSStackView(views: columnViews); columnsStack.orientation = .horizontal; columnsStack.alignment = .top; columnsStack.distribution = .fillEqually; columnsStack.spacing = 12
        let stack = NSStackView(views: [titleField, columnsStack]); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)])
        return box
    }

    static func modernServerDirectoryURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        return base.appendingPathComponent("Carracho", isDirectory: true)
            .appendingPathComponent("Server", isDirectory: true)
    }

    static func modernServerDatabaseDirectoryURL() -> URL {
        modernServerDirectoryURL().appendingPathComponent("db", isDirectory: true)
    }

    static func modernServerStateURL() -> URL {
        modernServerDatabaseDirectoryURL().appendingPathComponent("server.db", isDirectory: false)
    }

    static func migrateModernServerDatabaseLayout() throws {
        let manager = FileManager.default
        let root = modernServerDirectoryURL()
        let databaseRoot = modernServerDatabaseDirectoryURL()
        try manager.createDirectory(at: databaseRoot, withIntermediateDirectories: true)
        for name in ["server.db", "server.db-wal", "server.db-shm",
                     "news.db", "news.db-wal", "news.db-shm",
                     "file-index.db", "file-index.db-wal", "file-index.db-shm"] {
            let oldURL = root.appendingPathComponent(name, isDirectory: false)
            let newURL = databaseRoot.appendingPathComponent(name, isDirectory: false)
            guard manager.fileExists(atPath: oldURL.path), !manager.fileExists(atPath: newURL.path) else { continue }
            try manager.moveItem(at: oldURL, to: newURL)
        }
    }

    static func modernServerStorageURL() -> URL {
        modernServerDirectoryURL().appendingPathComponent("Files", isDirectory: true)
    }

    func loadModernServerState() {
        let url = Self.modernServerStateURL()
        let shouldRestartRuntime = localServerRuntime?.status.isRunning == true || startServerWhenBackendLoads
        let defaultBannerPNG = CarrachoDefaultServerBanner.pngData()
        appendLine("\n" + L("Loading local server state…"))
        serverStateLoadQueue.async { [weak self] in
            let result = Result {
                try Self.migrateModernServerDatabaseLayout()
                let databaseExisted = FileManager.default.fileExists(atPath: url.path)
                let backend = try ModernServerBackend(store: ServerStateStore(url: url))
                if !databaseExisted, let defaultBannerPNG, !defaultBannerPNG.isEmpty {
                    try backend.updateServerState { state in
                        if state.identity.bannerData == nil { state.identity.bannerData = defaultBannerPNG }
                    }
                }
                return backend
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(backend):
                    self.localServerRuntime?.stop()
                    self.serverBackend = backend
                    self.localServerState = backend.snapshot()
                    self.installLocalServerRuntime(backend: backend)
                    self.refreshAdminControls()
                    self.appendLine("\n" + LF("Local server state: %@", url.path))
                    if shouldRestartRuntime || self.startServerWhenBackendLoads {
                        self.startLocalServer()
                        self.startServerWhenBackendLoads = false
                    }
                case let .failure(error):
                    self.localServerRuntime?.stop()
                    self.localServerRuntime = nil
                    self.serverBackend = nil
                    self.localServerState = .initial
                    self.refreshAdminControls()
                    self.appendLine("\n" + LF("Local server state could not be loaded: %@", Self.displayMessage(for: error)))
                }
            }
        }
    }

    func installLocalServerRuntime(backend: ModernServerBackend) {
        let runtime = LegacyServerRuntime(backend: backend, storageRoot: Self.modernServerStorageURL(),
                                          supportRoot: Self.modernServerDirectoryURL(),
                                          databaseRoot: Self.modernServerDatabaseDirectoryURL())
        runtime.onStatus = { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshStatisticsFromBackend()
            }
        }
        runtime.onLog = { [weak self] line in
            DispatchQueue.main.async {
                self?.appendServerLog(line)
                self?.appendLine("\n[Server] \(line)")
            }
        }
        runtime.onStateChanged = { [weak self] in
            DispatchQueue.main.async { self?.reloadLocalStateFromBackend() }
        }
        runtime.onNewsChanged = { [weak self] in
            DispatchQueue.main.async { self?.reloadNewsView() }
        }
        localServerRuntime = runtime
    }

    func startLocalServer() {
        guard let runtime = localServerRuntime else { return }
        do {
            let port = try runtime.start()
            appendLine("\n" + LF("[Server] Runtime started on port %@.", String(port)))
        } catch {
            showAdminError(error)
        }
    }

    func refreshAdminControls() {
        if !client.isConnected, currentWorkspace == .serverInfo {
            if serverInfoHasUnsavedChanges, serverInfoDraftSourceKey?.hasPrefix("remote:") == true {
                serverInfoStatusOverride = "Connection lost. Unsaved remote-server changes are retained; reconnect or discard them before editing local settings."
                serverInfoStatusColor = CarrachoTheme.warning
                updateServerInfoEditorState()
            } else if !serverInfoHasUnsavedChanges {
                loadLocalServerInfoAdministration()
            }
        }

        let advanced = localServerState.advanced
        if !client.isConnected {
            remoteAdvancedAuthenticationMode = nil
            advancedRemoteCoreLoaded = false
            if !advancedHasUnsavedChanges {
                adminMaxConnectionsField.stringValue = String(advanced.maxConnections)
                adminMaxConnectionsPerIPField.stringValue = String(advanced.maxConnectionsPerIP)
                adminMaxTransfersField.stringValue = String(advanced.maxSimultaneousFileTransfers)
                adminMaxTransfersPerUserField.stringValue = String(advanced.maxFileTransfersPerUser)
                adminMaxFolderDepthField.stringValue = String(advanced.maxFolderDownloadDepth)
                adminAuthenticationModePopup.selectItem(at: localServerState.authentication.mode == .modernOnly ? 1 : 0)
            }
        }
        if !client.isConnected {
            adminNewsExpireTimeField.stringValue = String(format: "%02d:%02d", advanced.newsExpirationHour, advanced.newsExpirationMinute)
            advancedRemoteLegacyRootLoaded = false
            if !advancedHasUnsavedChanges {
                adminLegacyFilesRootField.stringValue = localServerState.runtime.legacyFilesRoot
            }
            adminLegacyFilesRootStatusLabel.stringValue = localServerState.runtime.legacyFilesRoot.isEmpty
                ? L("Classic connections use the normal local File Root.")
                : L("Classic connections use this separate local root.")
            if currentWorkspace == .trackers {
                if trackerHasUnsavedChanges, trackerSourceKey?.hasPrefix("remote:") == true {
                    trackerStatusOverride = "Connection lost. Unsaved Tracker changes were kept; reconnect or discard them before editing local settings."
                    trackerStatusColor = CarrachoTheme.warning
                    updateTrackerEditorState()
                } else if !trackerHasUnsavedChanges {
                    applyTrackerSnapshot(TrackerAdminSnapshot(trackers: advanced.trackers,
                                                              advertisementFlags: advanced.trackerAdvertisementFlags,
                                                              description: advanced.trackerDescription),
                                         sourceKey: "local")
                }
            }
        }
        if !client.isConnected {
            agreementEditor.string = localServerState.agreement.text
            agreementCheckbox.state = localServerState.agreement.enabled ? .on : .off
        }

        if !client.isConnected, statisticsSourceKey == nil || statisticsSourceKey == "local" { refreshStatisticsFromBackend() }

        if !client.isConnected {
            remoteBotStatus = nil
            remoteBotLoading = false
            remoteBotMutationInProgress = false
            remoteBotGreetingMutationInProgress = false
            remoteBotRefreshGeneration &+= 1
            updateBotAdministrationUI()
            adminAccountStatusLabel.stringValue = localServerState.accounts.count == 1 ? LF("%@ local account", String(localServerState.accounts.count)) : LF("%@ local accounts", String(localServerState.accounts.count))
            advancedRemoteExclusionsLoaded = false
            advancedRemoteBansLoaded = false
            if !advancedHasUnsavedChanges {
                adminSearchIndexExclusionsView.string = localServerState.runtime.searchIndexExclusions.joined(separator: "\n")
            }
            adminSearchIndexExclusionsStatusLabel.stringValue = localServerState.runtime.searchIndexExclusions.count == 1 ? LF("%@ local exclusion pattern", String(localServerState.runtime.searchIndexExclusions.count)) : LF("%@ local exclusion patterns", String(localServerState.runtime.searchIndexExclusions.count))
        }
        adminAccountTable.reloadData()
        adminNewsgroupTable.reloadData()
        adminTrackerTable.reloadData()
        updateAdminSelectionButtons()
        updateAdvancedSaveUI()
    }

    func updateAdminSelectionButtons() {
        if let statusColumn = adminAccountTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("status")) {
            statusColumn.headerCell.stringValue = usesClassicRemoteAccountAdministration ? L("Type") : L("Group")
        }
        let accountCount = usesRemoteAccountAdministration ? remoteAccountSummaries.count : localServerState.accounts.count
        let canEditAccounts = usesRemoteAccountAdministration ? canManageRemoteAccounts && !remoteAccountListLoading : serverBackend != nil
        adminAccountNewButton.isEnabled = canEditAccounts
        adminAccountGroupsButton.isEnabled = canEditAccounts && !usesClassicRemoteAccountAdministration
        adminAccountGroupsButton.toolTip = usesClassicRemoteAccountAdministration
            ? L("Classic servers store permissions directly on each account and do not support permission groups.")
            : nil
        adminAccountReloadButton.isEnabled = !remoteAccountListLoading && (!usesRemoteAccountAdministration || canManageRemoteAccounts)
        adminAccountModifyButton.isEnabled = canEditAccounts && adminAccountTable.selectedRow >= 0 && adminAccountTable.selectedRow < accountCount
        let selectedLocalAccountIsBot: Bool = {
            guard !usesRemoteAccountAdministration, adminAccountTable.selectedRow >= 0,
                  adminAccountTable.selectedRow < displayedLocalAccounts.count else { return false }
            return displayedLocalAccounts[adminAccountTable.selectedRow].id == ServerState.localBotAccountID
        }()
        adminAccountDeleteButton.isEnabled = adminAccountModifyButton.isEnabled && !selectedLocalAccountIsBot
        adminAccountDeleteButton.toolTip = selectedLocalAccountIsBot
            ? L("The built-in Bot account cannot be deleted. Disconnect it from the Bot tab instead.") : nil
        let canEditNewsgroups = usesRemoteNewsgroupAdministration
            ? canManageRemoteNewsgroups && !remoteNewsgroupAdministrationLoading
            : serverBackend != nil
        adminNewsgroupModifyButton.isEnabled = canEditNewsgroups && adminNewsgroupTable.selectedRow >= 0 && adminNewsgroupTable.selectedRow < displayedAdminNewsgroups.count
        adminNewsgroupDeleteButton.isEnabled = adminNewsgroupModifyButton.isEnabled
        let canEditTrackers = (usesRemoteTrackerAdministration
            ? remotePermissionEnabled(LegacyAccountPermissionBit.editTrackers)
            : serverBackend != nil) && trackerLoadedSnapshot != nil && !remoteTrackerSettingsLoading && !trackerSaveInProgress
        adminTrackerModifyButton.isEnabled = canEditTrackers && adminTrackerTable.selectedRow >= 0 && adminTrackerTable.selectedRow < displayedTrackers.count
        adminTrackerDeleteButton.isEnabled = adminTrackerModifyButton.isEnabled
        updateAdvancedSaveUI()
    }

    func showAdminError(_ error: Error) {
        appendLine("\n" + LF("Server configuration error: %@", Self.displayMessage(for: error)))
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Server Configuration")
        alert.informativeText = Self.displayMessage(for: error)
        alert.addButton(withTitle: L("OK"))
        alert.beginSheetModal(for: window)
    }

    func showAdminSaved(_ message: String) {
        appendLine("\n\(message)")
    }

    // MARK: - Bot administration

    func makeBotAdminPage() -> NSView {
        let page = adminPage(title: L("Bot"), subtitle: L("Control the local server Bot and its persistent account"))

        let runtimeTitle = sectionCaption(L("Runtime"))
        let statusName = NSTextField(labelWithString: L("Status"))
        statusName.font = .systemFont(ofSize: 12.5, weight: .medium)
        adminBotRuntimeLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        adminBotRuntimeLabel.alignment = .right
        let runtimeRow = horizontalStack([statusName, NSView(), adminBotRuntimeLabel], spacing: 10)
        runtimeRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        let accountName = NSTextField(labelWithString: L("Account"))
        accountName.font = .systemFont(ofSize: 12.5, weight: .medium)
        adminBotAccountLabel.font = .systemFont(ofSize: 12.5)
        adminBotAccountLabel.alignment = .right
        adminBotAccountLabel.lineBreakMode = .byTruncatingMiddle
        adminBotAccountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let accountRow = horizontalStack([accountName, NSView(), adminBotAccountLabel], spacing: 10)
        accountRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        adminBotStatusLabel.font = .systemFont(ofSize: 11.5)
        adminBotStatusLabel.textColor = CarrachoTheme.secondaryText
        adminBotStatusLabel.maximumNumberOfLines = 3
        adminBotStatusLabel.lineBreakMode = .byWordWrapping

        let localhostNote = infoLabel(L("The Bot is an in-process localhost-only user. It cannot be redirected to another server and always joins Public when connected."))
        localhostNote.maximumNumberOfLines = 3
        let profileNote = infoLabel(L("Name, nickname color, group and permissions are stored on the persistent Bot account and can be edited under Accounts."))
        profileNote.maximumNumberOfLines = 3

        let greetingTitle = sectionCaption(L("Automatic greeting"))
        let greetingToggleLabel = NSTextField(labelWithString: L("Greet new users in Public"))
        greetingToggleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        adminBotGreetingSwitch.target = self
        adminBotGreetingSwitch.action = #selector(botGreetingSwitchChanged(_:))
        let greetingToggleRow = horizontalStack([greetingToggleLabel, NSView(), adminBotGreetingSwitch], spacing: 10)
        adminBotGreetingTemplateField.placeholderString = LegacyBotAdminStatus.defaultGreetingTemplate
        adminBotGreetingTemplateField.font = .systemFont(ofSize: 12)
        adminBotGreetingTemplateField.lineBreakMode = .byTruncatingTail
        adminBotGreetingTemplateField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        adminBotGreetingSaveButton.target = self
        adminBotGreetingSaveButton.action = #selector(saveBotGreetingAdministration(_:))
        CarrachoTheme.applyPrimaryButtonStyle(adminBotGreetingSaveButton)
        let greetingTextRow = horizontalStack([adminBotGreetingTemplateField, adminBotGreetingSaveButton], spacing: 8)
        let greetingNote = infoLabel(L("The Bot sends the greeting once when a newly connected user first joins Public. Use {name} for the visible nickname and {login} for the account login."))
        greetingNote.maximumNumberOfLines = 3

        adminBotLoadingIndicator.style = .spinning
        adminBotLoadingIndicator.controlSize = .small
        adminBotLoadingIndicator.isDisplayedWhenStopped = false
        adminBotLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            adminBotLoadingIndicator.widthAnchor.constraint(equalToConstant: 16),
            adminBotLoadingIndicator.heightAnchor.constraint(equalToConstant: 16),
        ])

        adminBotToggleButton.target = self
        adminBotToggleButton.action = #selector(toggleBotAdministration(_:))
        CarrachoTheme.applyPrimaryButtonStyle(adminBotToggleButton)
        adminBotToggleButton.image = symbolImage("power", fallback: "")
        adminBotToggleButton.imagePosition = .imageLeading
        CarrachoTheme.applyPrimaryButtonStyle(adminBotToggleButton)

        adminBotReloadButton.target = self
        adminBotReloadButton.action = #selector(reloadBotAdministrationPressed(_:))
        adminBotReloadButton.bezelStyle = .rounded
        adminBotReloadButton.image = symbolImage("arrow.clockwise", fallback: NSImage.refreshTemplateName)
        adminBotReloadButton.imagePosition = .imageLeading

        adminBotAccountsButton.target = self
        adminBotAccountsButton.action = #selector(openBotAccountAdministration(_:))
        adminBotAccountsButton.bezelStyle = .rounded
        adminBotAccountsButton.image = symbolImage("person.crop.circle", fallback: NSImage.userAccountsName)
        adminBotAccountsButton.imagePosition = .imageLeading

        let actions = horizontalStack([
            adminBotLoadingIndicator, adminBotStatusLabel, NSView(),
            adminBotAccountsButton, adminBotReloadButton, adminBotToggleButton,
        ], spacing: 8)

        appendAdminContent([
            runtimeTitle,
            runtimeRow,
            CarrachoDividerView(),
            accountRow,
            CarrachoDividerView(),
            localhostNote,
            profileNote,
            CarrachoDividerView(),
            greetingTitle,
            greetingToggleRow,
            greetingTextRow,
            greetingNote,
            CarrachoDividerView(),
            actions,
        ], to: page, minimumBodyHeight: 410)
        updateBotAdministrationUI()
        return page
    }

    @objc func reloadBotAdministrationPressed(_ sender: Any?) {
        reloadBotAdministration()
    }

    func reloadBotAdministration() {
        guard client.isConnected, !isConnectedToClassicServer, canManageRemoteAccounts else {
            remoteBotStatus = nil
            remoteBotLoading = false
            updateBotAdministrationUI()
            return
        }
        remoteBotRefreshGeneration &+= 1
        let generation = remoteBotRefreshGeneration
        let source = client
        remoteBotLoading = true
        updateBotAdministrationUI()
        source.requestBotAdministrationStatus { [weak self, weak source] result in
            DispatchQueue.main.async {
                guard let self, let source, self.client === source,
                      generation == self.remoteBotRefreshGeneration else { return }
                self.remoteBotLoading = false
                switch result {
                case let .success(status):
                    self.remoteBotStatus = status
                case let .failure(error):
                    self.remoteBotStatus = nil
                    self.adminBotStatusLabel.stringValue = LF("Bot status could not be loaded: %@", Self.displayMessage(for: error))
                    self.adminBotStatusLabel.textColor = .systemRed
                }
                self.updateBotAdministrationUI(preserveExplicitError: self.remoteBotStatus == nil)
            }
        }
    }

    @objc func toggleBotAdministration(_ sender: Any?) {
        guard client.isConnected, !isConnectedToClassicServer, canManageRemoteAccounts,
              let status = remoteBotStatus, !remoteBotLoading, !remoteBotMutationInProgress else { return }
        let targetEnabled = !status.desiredEnabled
        let source = client
        remoteBotMutationInProgress = true
        updateBotAdministrationUI()
        source.setBotAdministrationEnabled(targetEnabled) { [weak self, weak source] result in
            DispatchQueue.main.async {
                guard let self, let source, self.client === source else { return }
                self.remoteBotMutationInProgress = false
                switch result {
                case .success:
                    self.remoteBotStatus?.desiredEnabled = targetEnabled
                    if !targetEnabled { self.remoteBotStatus?.connected = false }
                    self.showAdminSaved(targetEnabled ? L("Bot connection enabled on the server.") : L("Bot disconnected on the server."))
                    self.updateBotAdministrationUI()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self, weak source] in
                        guard let self, let source, self.client === source, self.currentWorkspace == .bot else { return }
                        self.reloadBotAdministration()
                    }
                case let .failure(error):
                    self.showAdminError(error)
                    self.reloadBotAdministration()
                }
            }
        }
    }

    @objc func botGreetingSwitchChanged(_ sender: Any?) {
        saveBotGreetingAdministration(sender)
    }

    @objc func saveBotGreetingAdministration(_ sender: Any?) {
        guard client.isConnected, !isConnectedToClassicServer, canManageRemoteAccounts,
              let status = remoteBotStatus, status.greetingSupported,
              !remoteBotLoading, !remoteBotMutationInProgress, !remoteBotGreetingMutationInProgress else { return }
        let enabled = adminBotGreetingSwitch.state == .on
        let template = adminBotGreetingTemplateField.stringValue
        let source = client
        remoteBotGreetingMutationInProgress = true
        updateBotAdministrationUI()
        source.setBotAdministrationGreeting(enabled: enabled, template: template) { [weak self, weak source] result in
            DispatchQueue.main.async {
                guard let self, let source, self.client === source else { return }
                self.remoteBotGreetingMutationInProgress = false
                switch result {
                case .success:
                    let normalized = template.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.remoteBotStatus?.greetNewUsers = enabled
                    self.remoteBotStatus?.greetingTemplate = normalized
                    self.adminBotGreetingTemplateField.stringValue = normalized
                    self.showAdminSaved(L("Bot greeting settings saved."))
                    self.updateBotAdministrationUI()
                case let .failure(error):
                    self.showAdminError(error)
                    self.reloadBotAdministration()
                }
            }
        }
    }

    @objc func openBotAccountAdministration(_ sender: Any?) {
        guard canAccessAdministrativeWorkspace(.accounts) else { return }
        selectWorkspace(.accounts)
    }

    func updateBotAdministrationUI(preserveExplicitError: Bool = false) {
        let supported = client.isConnected && !isConnectedToClassicServer && canManageRemoteAccounts
        if remoteBotLoading { adminBotLoadingIndicator.startAnimation(nil) }
        else { adminBotLoadingIndicator.stopAnimation(nil) }

        let busy = remoteBotMutationInProgress || remoteBotGreetingMutationInProgress
        adminBotReloadButton.isEnabled = supported && !remoteBotLoading && !busy
        adminBotAccountsButton.isEnabled = canAccessAdministrativeWorkspace(.accounts) && !busy
        adminBotToggleButton.isEnabled = supported && remoteBotStatus != nil && !remoteBotLoading && !busy
        let greetingSupported = supported && remoteBotStatus?.greetingSupported == true
        adminBotGreetingSwitch.isEnabled = greetingSupported && !remoteBotLoading && !busy
        adminBotGreetingTemplateField.isEnabled = greetingSupported && !remoteBotLoading && !busy
        adminBotGreetingSaveButton.isEnabled = greetingSupported && !remoteBotLoading && !busy

        guard supported else {
            adminBotRuntimeLabel.stringValue = L("Unavailable")
            adminBotAccountLabel.stringValue = "—"
            if !preserveExplicitError {
                adminBotStatusLabel.stringValue = client.isConnected && isConnectedToClassicServer
                    ? L("Bot administration is available only on modern Carracho servers.")
                    : L("Connect with an administrator account that can manage Accounts.")
                adminBotStatusLabel.textColor = CarrachoTheme.secondaryText
            }
            CarrachoTheme.setPrimaryButtonTitle(adminBotToggleButton, L("Connect Bot"))
            adminBotGreetingSwitch.state = .off
            adminBotGreetingTemplateField.stringValue = LegacyBotAdminStatus.defaultGreetingTemplate
            return
        }

        if remoteBotMutationInProgress {
            let enabling = !(remoteBotStatus?.desiredEnabled ?? false)
            CarrachoTheme.setPrimaryButtonTitle(adminBotToggleButton, enabling ? L("Connecting…") : L("Disconnecting…"))
        } else if let status = remoteBotStatus {
            CarrachoTheme.setPrimaryButtonTitle(adminBotToggleButton, status.desiredEnabled ? L("Disconnect Bot") : L("Connect Bot"))
        } else {
            CarrachoTheme.setPrimaryButtonTitle(adminBotToggleButton, L("Connect Bot"))
        }

        guard let status = remoteBotStatus else {
            adminBotRuntimeLabel.stringValue = remoteBotLoading ? L("Loading…") : L("Unknown")
            adminBotAccountLabel.stringValue = "—"
            adminBotGreetingSwitch.state = .off
            adminBotGreetingTemplateField.stringValue = LegacyBotAdminStatus.defaultGreetingTemplate
            if !preserveExplicitError {
                adminBotStatusLabel.stringValue = remoteBotLoading ? L("Loading Bot status…") : L("Bot status has not been loaded yet.")
                adminBotStatusLabel.textColor = CarrachoTheme.secondaryText
            }
            return
        }

        let displayName = status.name.trimmingCharacters(in: .whitespacesAndNewlines)
        adminBotAccountLabel.stringValue = displayName.isEmpty ? status.login : "\(displayName) (\(status.login))"
        if status.greetingSupported {
            if !remoteBotGreetingMutationInProgress {
                adminBotGreetingSwitch.state = status.greetNewUsers ? .on : .off
                adminBotGreetingTemplateField.stringValue = status.greetingTemplate
            }
            adminBotGreetingSaveButton.toolTip = nil
        } else {
            adminBotGreetingSwitch.state = .off
            adminBotGreetingTemplateField.stringValue = LegacyBotAdminStatus.defaultGreetingTemplate
            adminBotGreetingSaveButton.toolTip = L("This server does not support Bot greeting administration.")
        }
        if status.connected {
            adminBotRuntimeLabel.stringValue = L("Connected")
            adminBotRuntimeLabel.textColor = .systemGreen
            adminBotStatusLabel.stringValue = L("The Bot is connected locally and is present in Public.")
            adminBotStatusLabel.textColor = CarrachoTheme.secondaryText
        } else if status.desiredEnabled {
            adminBotRuntimeLabel.stringValue = L("Starting…")
            adminBotRuntimeLabel.textColor = CarrachoTheme.warning
            adminBotStatusLabel.stringValue = status.lastError.map { LF("The Bot is enabled but not connected: %@", $0) }
                ?? L("The Bot is enabled and waiting for the local server runtime to connect it.")
            adminBotStatusLabel.textColor = status.lastError == nil ? CarrachoTheme.secondaryText : .systemRed
        } else {
            adminBotRuntimeLabel.stringValue = L("Disconnected")
            adminBotRuntimeLabel.textColor = CarrachoTheme.secondaryText
            adminBotStatusLabel.stringValue = L("The Bot is disabled on this server.")
            adminBotStatusLabel.textColor = CarrachoTheme.secondaryText
        }
    }

}
